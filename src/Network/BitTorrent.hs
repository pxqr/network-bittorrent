-- |
--   Copyright   :  (c) Sam T. 2013
--   License     :  MIT
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
{-# LANGUAGE RecordWildCards #-}
module Network.BitTorrent
       (
         module Data.Torrent

         -- * Session
       , ThreadCount
       , defaultThreadCount

         -- ** Client
       , ClientSession( clientPeerID, allowedExtensions )

       , newClient
       , defaultClient

       , getCurrentProgress
       , getPeerCount
       , getSwarmCount

         -- ** Swarm
       , SwarmSession(torrentMeta)

       , newLeecher
       , newSeeder

       , SessionCount
       , getSessionCount

         -- * Discovery
       , discover

         -- * Peer to Peer
       , P2P

         -- ** Session
       , PeerSession( PeerSession, connectedPeerAddr
                    , swarmSession, enabledExtensions
                    )

       , getHaveCount
       , getWantCount
       , getPieceCount


         -- ** Transfer
       , Block(..), ppBlock
       , BlockIx(..), ppBlockIx

         -- ** Control
       , SessionException
       , disconnect
       , protocolError

         -- ** Events
       , Event(..)
       , awaitEvent, yieldEvent

         -- * Extensions
       , Extension, defaultExtensions, ppExtension
       ) where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Control.Monad.Reader

import Network

import Data.Torrent
import Network.BitTorrent.Internal
import Network.BitTorrent.Exchange
import Network.BitTorrent.Exchange.Protocol
import Network.BitTorrent.Tracker
import Network.BitTorrent.Extension
import Network.BitTorrent.Peer


-- | Client session with default parameters. Use it for testing only.
defaultClient :: IO ClientSession
defaultClient = newClient defaultThreadCount defaultExtensions

-- discover should hide tracker and DHT communication under the hood
-- thus we can obtain an unified interface

discover :: SwarmSession -> P2P () -> IO ()
discover swarm action = do
  port <- forkListener (error "discover")

  let conn = TConnection (tAnnounce (torrentMeta swarm))
                         (tInfoHash (torrentMeta swarm))
                         (clientPeerID (clientSession swarm))
                          port

  progress <- getCurrentProgress (clientSession swarm)

  withTracker progress conn $ \tses -> do
    forever $ do
      addr <- getPeerAddr tses
      spawnP2P swarm addr $ do
        action
