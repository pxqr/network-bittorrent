-- |
--   Copyright   :  (c) Sam T. 2013
--   License     :  MIT
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--   This module implement low-level UDP tracker protocol.
--   For more info see:
--   <http://www.bittorrent.org/beps/bep_0015.html>
--
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Network.BitTorrent.Tracker.UDP
       ( UDPTracker
       , initialTracker
       , putTracker
       , connectUDP
       , freshConnection
       ) where

import Control.Applicative
import Control.Exception
import Control.Monad
import Data.ByteString (ByteString)
import Data.IORef
import Data.List as L
import Data.Maybe
import Data.Monoid
import Data.Serialize
import Data.Text
import Data.Text.Encoding
import Data.Time
import Data.Word
import Text.Read (readMaybe)
import Network.Socket hiding (Connected)
import Network.Socket.ByteString as BS
import Network.URI
import System.Entropy
import Numeric

import Data.Torrent.Metainfo ()
import Network.BitTorrent.Tracker.Protocol

{-----------------------------------------------------------------------
  Tokens
-----------------------------------------------------------------------}

genToken :: IO Word64
genToken = do
    bs <- getEntropy 8
    either err return $ runGet getWord64be bs
  where
    err = error "genToken: impossible happen"

-- TODO rename
-- | Connection Id is used for entire tracker session.
newtype ConnId  = ConnId Word64
                  deriving (Eq, Serialize)

instance Show ConnId where
  showsPrec _ (ConnId cid) = showString "0x" <> showHex cid

genConnectionId :: IO ConnId
genConnectionId = ConnId <$> genToken

initialConnectionId :: ConnId
initialConnectionId = ConnId 0x41727101980

-- TODO rename
-- | Transaction Id is used within a UDP RPC.
newtype TransId = TransId Word32
                  deriving (Eq, Serialize)

instance Show TransId where
  showsPrec _ (TransId tid) = showString "0x" <> showHex tid

genTransactionId :: IO TransId
genTransactionId = (TransId . fromIntegral) <$> genToken

{-----------------------------------------------------------------------
  Transactions
-----------------------------------------------------------------------}

data Request  = Connect
              | Announce  AnnounceQuery
              | Scrape    ScrapeQuery
                deriving Show

data Response = Connected ConnId
              | Announced AnnounceInfo
              | Scraped   [ScrapeInfo]
              | Failed    Text
                deriving Show

-- TODO rename to message?
data Transaction a = Transaction
  { connId  :: !ConnId
  , transId :: !TransId
  , body    :: !a
  } deriving Show

type MessageId = Word32

connectId, announceId, scrapeId, errorId :: MessageId
connectId  = 0
announceId = 1
scrapeId   = 2
errorId    = 3

instance Serialize (Transaction Request) where
  put Transaction {..} = do
    case body of
      Connect        -> do
        put initialConnectionId
        put connectId
        put transId

      Announce query -> do
        put connId
        put announceId
        put transId
        put query

      Scrape   hashes -> do
        put connId
        put scrapeId
        put transId
        forM_ hashes put

  get = do
    cid <- get
    mid <- getWord32be
    tid <- get
    bod <- getBody mid

    return $ Transaction {
        connId  = cid
      , transId = tid
      , body    = bod
      }
    where
      getBody :: MessageId -> Get Request
      getBody msgId
        | msgId == connectId  = pure Connect
        | msgId == announceId = Announce <$> get
        | msgId == scrapeId   = Scrape   <$> many get
        |       otherwise     = fail "unknown message id"

instance Serialize (Transaction Response) where
  put Transaction {..} = do
    case body of
      Connected conn -> do
        put connectId
        put transId
        put conn

      Announced info -> do
        put announceId
        put transId
        put info

      Scraped infos -> do
        put scrapeId
        put transId
        forM_ infos put

      Failed info -> do
        put errorId
        put transId
        put (encodeUtf8 info)


  get = do
--    cid <- get
    mid <- getWord32be
    tid <- get
    bod <- getBody mid

    return $ Transaction {
        connId  = initialConnectionId -- TODO
      , transId = tid
      , body    = bod
      }
    where
      getBody :: MessageId -> Get Response
      getBody msgId
        | msgId == connectId  = Connected <$> get
        | msgId == announceId = Announced <$> get
        | msgId == scrapeId   = Scraped   <$> many get
        | msgId == errorId    = do
          bs <- get
          case decodeUtf8' bs of
            Left ex   -> fail (show ex)
            Right msg -> return $ Failed msg
        |  otherwise  = fail $ "unknown message id: " ++ show msgId

{-----------------------------------------------------------------------
  Connection
-----------------------------------------------------------------------}

connectionLifetime :: NominalDiffTime
connectionLifetime = 60

connectionLifetimeServer :: NominalDiffTime
connectionLifetimeServer = 120

data Connection = Connection
    { connectionId        :: ConnId
    , connectionTimestamp :: UTCTime
    } deriving Show

initialConnection :: IO Connection
initialConnection = Connection initialConnectionId <$> getCurrentTime

isExpired :: Connection -> IO Bool
isExpired Connection {..} = do
  currentTime <- getCurrentTime
  let timeDiff = diffUTCTime currentTime connectionTimestamp
  return $ timeDiff > connectionLifetime

{-----------------------------------------------------------------------
  RPC
-----------------------------------------------------------------------}

maxPacketSize :: Int
maxPacketSize = 98 -- announce request packet

setPort :: PortNumber -> SockAddr -> SockAddr
setPort p (SockAddrInet  _ h)     = SockAddrInet  p h
setPort p (SockAddrInet6 _ f h s) = SockAddrInet6 p f h s
setPort _  addr = addr

getTrackerAddr :: URI -> IO SockAddr
getTrackerAddr URI { uriAuthority = Just (URIAuth {..}) } = do
  infos <- getAddrInfo Nothing (Just uriRegName) Nothing
  let port = fromMaybe 0 (readMaybe (L.drop 1 uriPort) :: Maybe Int)
  case infos of
    AddrInfo {..} : _ -> return $ setPort (fromIntegral port) addrAddress
    _                 -> fail "getTrackerAddr: unable to lookup host addr"
getTrackerAddr _       = fail "getTrackerAddr: hostname unknown"

call :: SockAddr -> ByteString -> IO ByteString
call addr arg = bracket open close rpc
  where
    open = socket AF_INET Datagram defaultProtocol
    rpc sock = do
      BS.sendAllTo sock arg addr
      (res, addr') <- BS.recvFrom sock maxPacketSize
      unless (addr' == addr) $ do
        throwIO $ userError "address mismatch"
      return res

-- TODO retransmissions
-- TODO blocking
data UDPTracker = UDPTracker
    { trackerURI        :: URI
    , trackerConnection :: IORef Connection
    }

updateConnection :: ConnId -> UDPTracker -> IO ()
updateConnection cid UDPTracker {..} = do
  newConnection <- Connection cid <$> getCurrentTime
  writeIORef trackerConnection newConnection

getConnectionId :: UDPTracker -> IO ConnId
getConnectionId UDPTracker {..}
  = connectionId <$> readIORef trackerConnection

putTracker :: UDPTracker -> IO ()
putTracker UDPTracker {..} = do
  print trackerURI
  print =<< readIORef trackerConnection

transaction :: UDPTracker -> Request -> IO (Transaction Response)
transaction tracker @ UDPTracker {..} request = do
  cid <- getConnectionId tracker
  tid <- genTransactionId
  let trans = Transaction cid tid request

  addr <- getTrackerAddr trackerURI
  res  <- call addr (encode trans)
  case decode res of
    Right (response @ Transaction {..})
      | tid == transId -> return response
      |   otherwise    -> throwIO $ userError "transaction id mismatch"
    Left msg           -> throwIO $ userError msg

connectUDP :: UDPTracker -> IO ConnId
connectUDP tracker = do
  Transaction _ tid resp <- transaction tracker Connect
  case resp of
    Connected cid -> return cid

initialTracker :: URI -> IO UDPTracker
initialTracker uri = do
  tracker <- UDPTracker uri <$> (newIORef =<< initialConnection)
  connId  <- connectUDP tracker
  updateConnection connId tracker
  return tracker

freshConnection :: UDPTracker -> IO ()
freshConnection tracker @ UDPTracker {..} = do
  conn    <- readIORef trackerConnection
  expired <- isExpired conn
  when expired $ do
    connId <- connectUDP tracker
    updateConnection connId tracker

{-

announceUDP :: UDPTracker -> AnnounceQuery -> IO AnnounceInfo
announceUDP t query = do
  Transaction tid cid resp <- call transaction (Announce query)
  case resp of
    Announced info -> return info
    _              -> fail "response type mismatch"

scrapeUDP :: UDPTracker -> ScrapeQuery -> IO Scrape
scrapeUDP UDPTracker {..} query = do
  resp <- call trackerURI $ Scrape query
  case resp of
    Scraped scrape -> return undefined

instance Tracker UDPTracker where
  announce = announceUDP
  scrape_  = scrapeUDP
-}