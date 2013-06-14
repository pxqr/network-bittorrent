-- |
--   Copyright   :  (c) Sam T. 2013
--   License     :  MIT
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--   This module implement opaque broadcast message passing. It
--   provides sessions needed by Network.BitTorrent and
--   Network.BitTorrent.Exchange and modules. To hide some internals
--   of this module we detach it from Exchange.
--
--   Note: expose only static data in data field lists, all dynamic
--   data should be modified through standalone functions.
--
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE ConstraintKinds       #-}
module Network.BitTorrent.Internal
       ( Progress(..), startProgress

         -- * Client
       , ClientSession (clientPeerID, allowedExtensions)

       , ThreadCount
       , defaultThreadCount

       , newClient

       , getCurrentProgress
       , getSwarmCount
       , getPeerCount


         -- * Swarm
       , SwarmSession( SwarmSession, torrentMeta, clientSession )

       , SessionCount
       , getSessionCount

       , newLeecher
       , newSeeder
       , getClientBitfield

       , enterSwarm
       , leaveSwarm
       , waitVacancy

         -- * Peer
       , PeerSession( PeerSession, connectedPeerAddr
                    , swarmSession, enabledExtensions
                    )
       , SessionState
       , withPeerSession

         -- ** Exceptions
       , SessionException(..)
       , isSessionException
       , putSessionException

         -- ** Properties
       , bitfield, status
       , findPieceCount

         -- * Timeouts
       , updateIncoming, updateOutcoming
       ) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.MSem as MSem
import Control.Lens
import Control.Monad.State
import Control.Monad.Reader
import Control.Exception

import Data.IORef
import Data.Default
import Data.Function
import Data.Ord
import Data.Set as S
import Data.Typeable

import Data.Serialize hiding (get)
import Text.PrettyPrint

import Network
import Network.Socket
import Network.Socket.ByteString

import GHC.Event as Ev

import Data.Bitfield as BF
import Data.Torrent
import Network.BitTorrent.Extension
import Network.BitTorrent.Peer
import Network.BitTorrent.Exchange.Protocol as BT
import Network.BitTorrent.Tracker.Protocol as BT

{-----------------------------------------------------------------------
    Progress
-----------------------------------------------------------------------}

-- | 'Progress' contains upload/download/left stats about
--   current client state and used to notify the tracker
--
--   This data is considered as dynamic within one client
--   session. This data also should be shared across client
--   application sessions (e.g. files), otherwise use 'startProgress'
--   to get initial 'Progress'.
--
data Progress = Progress {
    prUploaded   :: !Integer -- ^ Total amount of bytes uploaded.
  , prDownloaded :: !Integer -- ^ Total amount of bytes downloaded.
  , prLeft       :: !Integer -- ^ Total amount of bytes left.
  } deriving (Show, Read, Eq)

-- TODO make lenses

-- | Initial progress is used when there are no session before.
--
--   Please note that tracker might penalize client some way if the do
--   not accumulate progress. If possible and save 'Progress' between
--   client sessions to avoid that.
--
startProgress :: Integer -> Progress
startProgress = Progress 0 0

{-----------------------------------------------------------------------
    Client session
-----------------------------------------------------------------------}

{- NOTE: If we will not restrict number of threads we could end up
with thousands of connected swarm and make no particular progress.

Note also we do not bound number of swarms! This is not optimal
strategy because each swarm might have say 1 thread and we could end
up bounded by the meaningless limit. Bounding global number of p2p
sessions should work better, and simpler.-}

-- | Each client might have a limited number of threads.
type ThreadCount = Int

-- | The number of threads suitable for a typical BT client.
defaultThreadCount :: ThreadCount
defaultThreadCount = 1000

{- NOTE: basically, client session should contain options which user
app store in configuration files. (related to the protocol) Moreover
it should contain the all client identification info. (e.g. DHT)  -}

-- | Client session is the basic unit of bittorrent network, it has:
--
--     * The /peer ID/ used as unique identifier of the client in
--     network. Obviously, this value is not changed during client
--     session.
--
--     * The number of /protocol extensions/ it might use. This value
--     is static as well, but if you want to dynamically reconfigure
--     the client you might kill the end the current session and
--     create a new with the fresh required extensions.
--
--     * The number of /swarms/ to join, each swarm described by the
--     'SwarmSession'.
--
--  Normally, you would have one client session, however, if we need,
--  in one application we could have many clients with different peer
--  ID's and different enabled extensions at the same time.
--
data ClientSession = ClientSession {
    -- | Used in handshakes and discovery mechanism.
    clientPeerID      :: !PeerID

    -- | Extensions we should try to use. Hovewer some particular peer
    -- might not support some extension, so we keep enabledExtension in
    -- 'PeerSession'.
  , allowedExtensions :: [Extension]

    -- | Semaphor used to bound number of active P2P sessions.
  , activeThreads     :: !(MSem ThreadCount)

    -- | Max number of active connections.
  , maxActive         :: !ThreadCount

    -- | Used to traverse the swarm session.
  , swarmSessions     :: !(TVar (Set SwarmSession))

  , eventManager      :: !EventManager

    -- | Used to keep track global client progress.
  , currentProgress   :: !(TVar  Progress)
  }

instance Eq ClientSession where
  (==) = (==) `on` clientPeerID

instance Ord ClientSession where
  compare = comparing clientPeerID

-- | Get current global progress of the client. This value is usually
-- shown to a user.
getCurrentProgress :: MonadIO m => ClientSession -> m Progress
getCurrentProgress = liftIO . readTVarIO . currentProgress

-- | Get number of swarms client aware of.
getSwarmCount :: MonadIO m => ClientSession -> m SessionCount
getSwarmCount ClientSession {..} = liftIO $
  S.size <$> readTVarIO swarmSessions

-- | Get number of peers the client currently connected to.
getPeerCount :: MonadIO m => ClientSession -> m ThreadCount
getPeerCount ClientSession {..} = liftIO $ do
  unused  <- peekAvail activeThreads
  return (maxActive - unused)

-- | Create a new client session. The data passed to this function are
-- usually loaded from configuration file.
newClient :: SessionCount     -- ^ Maximum count of active P2P Sessions.
          -> [Extension]      -- ^ Extensions allowed to use.
          -> IO ClientSession -- ^ Client with unique peer ID.

newClient n exts = do
  mgr <- Ev.new
  -- TODO kill this thread when leave client
  _   <- forkIO $ loop mgr

  ClientSession
    <$> newPeerID
    <*> pure exts
    <*> MSem.new n
    <*> pure n
    <*> newTVarIO S.empty
    <*> pure mgr
    <*> newTVarIO (startProgress 0)

{-----------------------------------------------------------------------
    Swarm session
-----------------------------------------------------------------------}

{- NOTE: If client is a leecher then there is NO particular reason to
set max sessions count more than the_number_of_unchoke_slots * k:

  * thread slot(activeThread semaphore)
  * will take but no

So if client is a leecher then max sessions count depends on the
number of unchoke slots.

However if client is a seeder then the value depends on .
-}

-- | Used to bound the number of simultaneous connections and, which
-- is the same, P2P sessions within the swarm session.
type SessionCount = Int

defSeederConns :: SessionCount
defSeederConns = defaultUnchokeSlots

defLeacherConns :: SessionCount
defLeacherConns = defaultNumWant

-- | Swarm session is
data SwarmSession = SwarmSession {
    torrentMeta       :: !Torrent

    -- |
  , clientSession     :: !ClientSession

    -- | Represent count of peers we _currently_ can connect to in the
    -- swarm. Used to bound number of concurrent threads.
  , vacantPeers       :: !(MSem SessionCount)

    -- | Modify this carefully updating global progress.
  , clientBitfield    :: !(TVar  Bitfield)
  , connectedPeers    :: !(TVar (Set PeerSession))
  }

-- INVARIANT:
--   max_sessions_count - sizeof connectedPeers = value vacantPeers

instance Eq SwarmSession where
  (==) = (==) `on` (tInfoHash . torrentMeta)

instance Ord SwarmSession where
  compare = comparing (tInfoHash . torrentMeta)

newSwarmSession :: Int -> Bitfield -> ClientSession -> Torrent
                -> IO SwarmSession
newSwarmSession n bf cs @ ClientSession {..} t @ Torrent {..}
  = SwarmSession <$> pure t
                 <*> pure cs
                 <*> MSem.new n
                 <*> newTVarIO bf
                 <*> newTVarIO S.empty

-- | New swarm session in which the client allowed to upload only.
newSeeder :: ClientSession -> Torrent -> IO SwarmSession
newSeeder cs t @ Torrent {..}
  = newSwarmSession defSeederConns (haveAll (pieceCount tInfo)) cs t

-- | New swarm in which the client allowed both download and upload.
newLeecher :: ClientSession -> Torrent -> IO SwarmSession
newLeecher cs t @ Torrent {..}
  = newSwarmSession defLeacherConns (haveNone (pieceCount tInfo)) cs t

--isLeacher :: SwarmSession -> IO Bool
--isLeacher = undefined

-- | Get the number of connected peers in the given swarm.
getSessionCount :: SwarmSession -> IO SessionCount
getSessionCount SwarmSession {..} = do
  S.size <$> readTVarIO connectedPeers

getClientBitfield :: SwarmSession -> IO Bitfield
getClientBitfield = readTVarIO . clientBitfield

{-
haveDone :: MonadIO m => PieceIx -> SwarmSession -> m ()
haveDone ix =
  liftIO $ atomically $ do
    bf <- readTVar clientBitfield
    writeTVar (have ix bf)
    currentProgress
-}

-- acquire/release mechanism: for internal use only

enterSwarm :: SwarmSession -> IO ()
enterSwarm SwarmSession {..} = do
  MSem.wait (activeThreads clientSession)
  MSem.wait vacantPeers

leaveSwarm :: SwarmSession -> IO ()
leaveSwarm SwarmSession {..} = do
  MSem.signal vacantPeers
  MSem.signal (activeThreads clientSession)

waitVacancy :: SwarmSession -> IO () -> IO ()
waitVacancy se =
  bracket (enterSwarm se) (const (leaveSwarm se))
                  . const

{-----------------------------------------------------------------------
    Peer session
-----------------------------------------------------------------------}

-- | Peer session contain all data necessary for peer to peer communication.
data PeerSession = PeerSession {
    -- | Used as unique 'PeerSession' identifier within one
    -- 'SwarmSession'.
    connectedPeerAddr :: !PeerAddr

    -- | The swarm to which both end points belong to.
  , swarmSession      :: !SwarmSession

    -- | Extensions such that both peer and client support.
  , enabledExtensions :: [Extension]

    -- | To dissconnect from died peers appropriately we should check
    -- if a peer do not sent the KA message within given interval. If
    -- yes, we should throw an exception in 'TimeoutCallback' and
    -- close session between peers.
    --
    -- We should update timeout if we /receive/ any message within
    -- timeout interval to keep connection up.
  , incomingTimeout     :: !TimeoutKey

    -- | To send KA message appropriately we should know when was last
    -- time we sent a message to a peer. To do that we keep registered
    -- timeout in event manager and if we do not sent any message to
    -- the peer within given interval then we send KA message in
    -- 'TimeoutCallback'.
    --
    -- We should update timeout if we /send/ any message within timeout
    -- to avoid reduntant KA messages.
    --
  , outcomingTimeout   :: !TimeoutKey

    -- TODO use dupChan for broadcasting

    -- | Channel used for replicate messages across all peers in
    -- swarm. For exsample if we get some piece we should sent to all
    -- connected (and interested in) peers HAVE message.
    --
  , broadcastMessages :: !(Chan   [Message])

    -- | Dymanic P2P data.
  , sessionState      :: !(IORef  SessionState)
  }

data SessionState = SessionState {
    _bitfield :: !Bitfield        -- ^ Other peer Have bitfield.
  , _status   :: !SessionStatus   -- ^ Status of both peers.
  } deriving (Show, Eq)

$(makeLenses ''SessionState)

instance Eq PeerSession where
  (==) = (==) `on` connectedPeerAddr

instance Ord PeerSession where
  compare = comparing connectedPeerAddr

instance (MonadIO m, MonadReader PeerSession m)
      => MonadState SessionState m where
  get    = do
    ref <- asks sessionState
    st <- liftIO (readIORef ref)
    liftIO $ print (completeness (_bitfield st))
    return st

  put !s = asks sessionState >>= \ref -> liftIO $ writeIORef ref s


-- | Exceptions used to interrupt the current P2P session. This
-- exceptions will NOT affect other P2P sessions, DHT, peer <->
-- tracker, or any other session.
--
data SessionException = PeerDisconnected
                      | ProtocolError Doc
                        deriving (Show, Typeable)

instance Exception SessionException


-- | Do nothing with exception, used with 'handle' or 'try'.
isSessionException :: Monad m => SessionException -> m ()
isSessionException _ = return ()

-- | The same as 'isSessionException' but output to stdout the catched
-- exception, for debugging purposes only.
putSessionException :: SessionException -> IO ()
putSessionException = print

-- TODO modify such that we can use this in listener loop
-- TODO check if it connected yet peer
withPeerSession :: SwarmSession -> PeerAddr
                -> ((Socket, PeerSession) -> IO ())
                -> IO ()

withPeerSession ss @ SwarmSession {..} addr
    = handle isSessionException . bracket openSession closeSession
  where
    openSession = do
      let caps  = encodeExts $ allowedExtensions $ clientSession
      let ihash = tInfoHash torrentMeta
      let pid   = clientPeerID $ clientSession
      let chs   = Handshake defaultBTProtocol caps ihash pid

      sock <- connectToPeer addr
      phs  <- handshake sock chs `onException` close sock

      cbf <- readTVarIO clientBitfield
      sendAll sock (encode (Bitfield cbf))

      let enabled = decodeExts (enabledCaps caps (handshakeCaps phs))
      ps <- PeerSession addr ss enabled
         <$> registerTimeout (eventManager clientSession)
                maxIncomingTime (return ())
         <*> registerTimeout (eventManager clientSession)
                maxOutcomingTime (sendKA sock)
         <*> newChan
         <*> do {
           ; tc <- totalCount <$> readTVarIO clientBitfield
           ; newIORef (SessionState (haveNone tc) def)
           }

      atomically $ modifyTVar' connectedPeers (S.insert ps)

      return (sock, ps)

    closeSession (sock, ps) = do
      atomically $ modifyTVar' connectedPeers (S.delete ps)
      close sock

findPieceCount :: PeerSession -> PieceCount
findPieceCount = pieceCount . tInfo . torrentMeta . swarmSession

-- TODO use this type for broadcast messages instead of 'Message'
--data Signal =
--nextBroadcast :: P2P (Maybe Signal)
--nextBroadcast =

{-----------------------------------------------------------------------
    Timeouts
-----------------------------------------------------------------------}

-- for internal use only

sec :: Int
sec = 1000 * 1000

maxIncomingTime :: Int
maxIncomingTime = 120 * sec

maxOutcomingTime :: Int
maxOutcomingTime = 1 * sec

-- | Should be called after we have received any message from a peer.
updateIncoming :: PeerSession -> IO ()
updateIncoming PeerSession {..} = do
  updateTimeout (eventManager (clientSession swarmSession))
    incomingTimeout maxIncomingTime

-- | Should be called before we have send any message to a peer.
updateOutcoming :: PeerSession -> IO ()
updateOutcoming PeerSession {..}  =
  updateTimeout (eventManager (clientSession swarmSession))
    outcomingTimeout maxOutcomingTime

sendKA :: Socket -> IO ()
sendKA sock {- SwarmSession {..} -} = do
  return ()
--  print "I'm sending keep alive."
--  sendAll sock (encode BT.KeepAlive)
--  let mgr = eventManager clientSession
--  updateTimeout mgr
--  print "Done.."
