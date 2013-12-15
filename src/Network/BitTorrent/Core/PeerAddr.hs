-- |
--   Copyright   :  (c) Sam Truzjan 2013
--   License     :  BSD3
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--   'PeerAddr' is used to represent peer address. Currently it's
--   just peer IP and peer port but this might change in future.
--
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE ViewPatterns               #-}
{-# OPTIONS -fno-warn-orphans           #-} -- for PortNumber instances
module Network.BitTorrent.Core.PeerAddr
       ( -- * Peer address
         PeerAddr(..)
       , defaultPorts
       , peerSockAddr

         -- * IP
       , mergeIPLists
       , splitIPList
       , IPAddress ()
       ) where

import Control.Applicative
import Control.Monad
import Data.Aeson (ToJSON, FromJSON)
import Data.BEncode   as BS
import Data.BEncode.BDict (BKey)
import Data.ByteString.Char8 as BS8
import Data.Char
import Data.Default
import Data.Either
import Data.Foldable
import Data.IP
import Data.List      as L
import Data.List.Split
import Data.Serialize as S
import Data.String
import Data.Typeable
import Data.Word
import Network.Socket
import Text.PrettyPrint
import Text.PrettyPrint.Class
import Text.Read (readMaybe)
import qualified Text.ParserCombinators.ReadP as RP

import Network.BitTorrent.Core.PeerId


{-----------------------------------------------------------------------
--  Port number
-----------------------------------------------------------------------}

deriving instance ToJSON PortNumber
deriving instance FromJSON PortNumber

instance BEncode PortNumber where
  toBEncode   = toBEncode    .  fromEnum
  fromBEncode = fromBEncode >=> portNumber
    where
      portNumber :: Integer -> BS.Result PortNumber
      portNumber n
        | 0 <= n && n <= fromIntegral (maxBound :: Word16)
        = pure $ fromIntegral n
        | otherwise = decodingError $ "PortNumber: " ++ show n

instance Serialize PortNumber where
  get = fromIntegral <$> getWord16be
  {-# INLINE get #-}
  put = putWord16be . fromIntegral
  {-# INLINE put #-}

{-----------------------------------------------------------------------
--  IP addr
-----------------------------------------------------------------------}

class IPAddress i where
  toHostAddr :: i -> Either HostAddress HostAddress6

instance IPAddress IPv4 where
  toHostAddr = Left . toHostAddress

instance IPAddress IPv6 where
  toHostAddr = Right . toHostAddress6

instance IPAddress IP where
  toHostAddr (IPv4 ip) = toHostAddr ip
  toHostAddr (IPv6 ip) = toHostAddr ip

deriving instance Typeable IP
deriving instance Typeable IPv4
deriving instance Typeable IPv6

ipToBEncode :: Show i => i -> BValue
ipToBEncode ip = BString $ BS8.pack $ show ip

ipFromBEncode :: Read a => BValue -> BS.Result a
ipFromBEncode (BString (BS8.unpack -> ipStr))
  | Just ip <- readMaybe (ipStr) = pure ip
  |         otherwise            = decodingError $ "IP: " ++ ipStr
ipFromBEncode _    = decodingError $ "IP: addr should be a bstring"

instance BEncode IP where
  toBEncode   = ipToBEncode
  fromBEncode = ipFromBEncode

instance BEncode IPv4 where
  toBEncode   = ipToBEncode
  fromBEncode = ipFromBEncode

instance BEncode IPv6 where
  toBEncode   = ipToBEncode
  fromBEncode = ipFromBEncode

instance Serialize IPv4 where
    put = putWord32host    .  toHostAddress
    get = fromHostAddress <$> getWord32host

instance Serialize IPv6 where
    put ip = put $ toHostAddress6 ip
    get = fromHostAddress6 <$> get

{-----------------------------------------------------------------------
--  Peer addr
-----------------------------------------------------------------------}
-- TODO check semantic of ord and eq instances

-- | Peer address info normally extracted from peer list or peer
-- compact list encoding.
data PeerAddr a = PeerAddr
  { peerId   :: !(Maybe PeerId)
  , peerAddr :: a
  , peerPort :: {-# UNPACK #-} !PortNumber
  } deriving (Show, Eq, Typeable, Functor)

peer_ip_key, peer_id_key, peer_port_key :: BKey
peer_ip_key   = "ip"
peer_id_key   = "peer id"
peer_port_key = "port"

-- | The tracker's 'announce response' compatible encoding.
instance (Typeable a, BEncode a) => BEncode (PeerAddr a) where
  toBEncode PeerAddr {..} = toDict $
       peer_ip_key   .=! peerAddr
    .: peer_id_key   .=? peerId
    .: peer_port_key .=! peerPort
    .: endDict

  fromBEncode = fromDict $ do
    peerAddr <$>? peer_id_key
             <*>! peer_ip_key
             <*>! peer_port_key
    where
      peerAddr ip pid port = PeerAddr ip pid port

mergeIPLists :: [PeerAddr IPv4] -> Maybe [PeerAddr IPv6] -> [PeerAddr IP]
mergeIPLists v4 v6 = (fmap IPv4 `L.map` v4)
                  ++ (fmap IPv6 `L.map` Data.Foldable.concat v6)

splitIPList :: [PeerAddr IP] -> ([PeerAddr IPv4],[PeerAddr IPv6])
splitIPList xs = partitionEithers $ toEither <$> xs
    where
      toEither :: PeerAddr IP -> Either (PeerAddr IPv4) (PeerAddr IPv6)
      toEither pa@(PeerAddr _ (IPv4 _) _) = Left  (ipv4 <$> pa)
      toEither pa@(PeerAddr _ (IPv6 _) _) = Right (ipv6 <$> pa)

-- | The tracker's 'compact peer list' compatible encoding. The
-- 'peerId' is always 'Nothing'.
--
--   For more info see: <http://www.bittorrent.org/beps/bep_0023.html>
--
-- TODO: test byte order
instance (Serialize a) => Serialize (PeerAddr a) where
  put PeerAddr {..} = put peerAddr >> put peerPort
  get = PeerAddr Nothing <$> get <*> get

-- | @127.0.0.1:6881@
instance Default (PeerAddr IPv4) where
  def = "127.0.0.1:6881"

-- | Example:
--
--   @peerPort \"127.0.0.1:6881\" == 6881@
--
instance IsString (PeerAddr IPv4) where
  fromString str
    | [hostAddrStr, portStr] <- splitWhen (== ':') str
    , Just hostAddr <- readMaybe hostAddrStr
    , Just portNum  <- toEnum <$> readMaybe portStr
                = PeerAddr Nothing hostAddr portNum
    | otherwise = error $ "fromString: unable to parse (PeerAddr IPv4): " ++ str

readsIPv6_port :: String -> [((IPv6, PortNumber), String)]
readsIPv6_port = RP.readP_to_S $ do
  ip <- RP.char '[' *> (RP.readS_to_P reads) <* RP.char ']'
  _ <- RP.char ':'
  port <- toEnum <$> read <$> (RP.many1 $ RP.satisfy isDigit) <* RP.eof
  return (ip,port)

instance IsString (PeerAddr IPv6) where
  fromString str
    | [((ip,port),"")] <- readsIPv6_port str =
        PeerAddr Nothing ip port
    | otherwise = error $ "fromString: unable to parse (PeerAddr IPv6): " ++ str

instance IsString (PeerAddr IP) where
  fromString str
    | '[' `L.elem` str = IPv6 <$> fromString str
    |      otherwise   = IPv4 <$> fromString str

-- | fingerprint + "at" + dotted.host.inet.addr:port
-- TODO: instances for IPv6, HostName
instance Pretty (PeerAddr IP) where
  pretty PeerAddr {..}
    | Just pid <- peerId = pretty (fingerprint pid) <+> "at" <+> paddr
    |     otherwise      = paddr
    where
      paddr = text (show peerAddr ++ ":" ++ show peerPort)

-- | Ports typically reserved for bittorrent P2P listener.
defaultPorts :: [PortNumber]
defaultPorts =  [6881..6889]

_resolvePeerAddr :: (IPAddress i) => PeerAddr HostName -> PeerAddr i
_resolvePeerAddr = undefined

-- | Convert peer info from tracker response to socket address.  Used
--   for establish connection between peers.
--
peerSockAddr :: PeerAddr IP -> SockAddr
peerSockAddr PeerAddr {..} =
  case peerAddr of
    IPv4 ipv4 -> SockAddrInet  peerPort   (toHostAddress  ipv4)
    IPv6 ipv6 -> SockAddrInet6 peerPort 0 (toHostAddress6 ipv6) 0
