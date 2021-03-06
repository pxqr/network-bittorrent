module Network.BitTorrent.Client.Handle
       ( -- * Handle
         Handle

         -- * Initialization
       , openTorrent
       , openMagnet
       , closeHandle

         -- * Control
       , start
       , pause
       , stop

         -- * Query
       , getHandle
       , getStatus
       ) where

import Control.Concurrent.Chan.Split
import Control.Concurrent.Lifted as L
import Control.Monad
import Control.Monad.Trans
import Data.Default
import Data.List as L
import Data.HashMap.Strict as HM

import Data.Torrent
import Network.BitTorrent.Client.Types as Types
import Network.BitTorrent.DHT      as DHT
import Network.BitTorrent.Exchange as Exchange
import Network.BitTorrent.Tracker  as Tracker

{-----------------------------------------------------------------------
--  Safe handle set manupulation
-----------------------------------------------------------------------}

allocHandle :: InfoHash -> BitTorrent Handle -> BitTorrent Handle
allocHandle ih m = do
  Client {..} <- getClient

  (h, added) <- modifyMVar clientTorrents $ \ handles -> do
    case HM.lookup ih handles of
      Just h  -> return (handles, (h, False))
      Nothing -> do
        h <- m
        return (HM.insert ih h handles, (h, True))

  when added $ do
    liftIO $ send clientEvents (TorrentAdded ih)

  return h

freeHandle :: InfoHash -> BitTorrent () -> BitTorrent ()
freeHandle ih finalizer = do
  Client {..} <- getClient

  modifyMVar_ clientTorrents $ \ handles -> do
    case HM.lookup ih handles of
      Nothing -> return handles
      Just _  -> do
        finalizer
        return (HM.delete ih handles)

lookupHandle :: InfoHash -> BitTorrent (Maybe Handle)
lookupHandle ih = do
  Client {..} <- getClient
  handles     <- readMVar clientTorrents
  return (HM.lookup ih handles)

{-----------------------------------------------------------------------
--  Initialization
-----------------------------------------------------------------------}

newExchangeSession :: FilePath -> Either InfoHash InfoDict -> BitTorrent Exchange.Session
newExchangeSession rootPath source = do
  c @ Client {..} <- getClient
  liftIO $ Exchange.newSession clientLogger (externalAddr c) rootPath source

-- | Open a torrent in 'stop'ed state. Use 'nullTorrent' to open
-- handle from 'InfoDict'. This operation do not block.
openTorrent :: FilePath -> Torrent -> BitTorrent Handle
openTorrent rootPath t @ Torrent {..} = do
  let ih = idInfoHash tInfoDict
  allocHandle ih $ do
    statusVar <- newMVar Types.Stopped
    tses <- liftIO $ Tracker.newSession ih (trackerList t)
    eses <- newExchangeSession rootPath (Right tInfoDict)
    eventStream <- liftIO newSendPort
    return $ Handle
      { handleTopic    = ih
      , handlePrivate  = idPrivate tInfoDict
      , handleStatus   = statusVar
      , handleTrackers = tses
      , handleExchange = eses
      , handleEvents   = eventStream
      }

-- | Use 'nullMagnet' to open handle from 'InfoHash'.
openMagnet :: FilePath -> Magnet -> BitTorrent Handle
openMagnet rootPath Magnet {..} = do
  allocHandle exactTopic $ do
    statusVar <- newMVar Types.Stopped
    tses <- liftIO $ Tracker.newSession exactTopic def
    eses <- newExchangeSession rootPath (Left exactTopic)
    eventStream <- liftIO newSendPort
    return $ Handle
      { handleTopic    = exactTopic
      , handlePrivate  = False
      , handleStatus   = statusVar
      , handleTrackers = tses
      , handleExchange = eses
      , handleEvents   = eventStream
      }

-- | Stop torrent and destroy all sessions. You don't need to close
-- handles at application exit, all handles will be automatically
-- closed at 'Network.BitTorrent.Client.closeClient'. This operation
-- may block.
closeHandle :: Handle -> BitTorrent ()
closeHandle h @ Handle {..} = do
  freeHandle handleTopic $ do
    Client {..} <- getClient
    stop h
    liftIO $ Exchange.closeSession handleExchange
    liftIO $ Tracker.closeSession trackerManager handleTrackers

{-----------------------------------------------------------------------
--  Control
-----------------------------------------------------------------------}

modifyStatus :: HandleStatus -> Handle -> (HandleStatus -> BitTorrent ()) -> BitTorrent ()
modifyStatus targetStatus Handle {..} targetAction = do
  modifyMVar_ handleStatus $ \ actualStatus -> do
    unless (actualStatus == targetStatus) $ do
      targetAction actualStatus
    return targetStatus
  liftIO $ send handleEvents (StatusChanged targetStatus)

-- | Start downloading, uploading and announcing this torrent.
--
-- This operation is blocking, use
-- 'Control.Concurrent.Async.Lifted.async' if needed.
start :: Handle -> BitTorrent ()
start h @ Handle {..} = do
  modifyStatus Types.Running h $ \ status -> do
    case status of
      Types.Running -> return ()
      Types.Stopped -> do
        Client {..} <- getClient
        liftIO $ Tracker.notify trackerManager handleTrackers Tracker.Started
        unless handlePrivate $ do
          liftDHT $ DHT.insert handleTopic (error "start")
        liftIO $ do
          peers <- askPeers trackerManager handleTrackers
          print $ "got: " ++ show (L.length peers) ++ " peers"
          forM_ peers $ \ peer -> do
            Exchange.connect peer handleExchange

-- | Stop downloading this torrent.
pause :: Handle -> BitTorrent ()
pause _ = return ()

-- | Stop downloading, uploading and announcing this torrent.
stop :: Handle -> BitTorrent ()
stop h @ Handle {..} = do
  modifyStatus Types.Stopped h $ \ status -> do
    case status of
      Types.Stopped -> return ()
      Types.Running -> do
        Client {..} <- getClient
        unless handlePrivate $ do
          liftDHT $ DHT.delete handleTopic (error "stop")
        liftIO  $ Tracker.notify trackerManager handleTrackers Tracker.Stopped

{-----------------------------------------------------------------------
--  Query
-----------------------------------------------------------------------}

getHandle :: InfoHash -> BitTorrent Handle
getHandle ih = do
  mhandle <- lookupHandle ih
  case mhandle of
    Nothing -> error "should we throw some exception?"
    Just h  -> return h

getStatus :: Handle -> IO HandleStatus
getStatus Handle {..} = readMVar handleStatus
