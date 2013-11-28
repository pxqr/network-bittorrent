{-# OPTIONS -fno-warn-orphans #-}
module Network.BitTorrent.Tracker.MessageSpec (spec) where

import Control.Applicative
import Data.BEncode as BE
import Data.ByteString.Char8 as BC
import Data.ByteString.Lazy as BL
import Data.List as L
import Data.Maybe
import Data.Word
import Data.Text
import Network
import Network.URI
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Gen
import Network.HTTP.Types.URI

import Data.Torrent.InfoHashSpec ()
import Data.Torrent.ProgressSpec ()
import Network.BitTorrent.Core.PeerIdSpec ()

import Network.BitTorrent.Tracker.Message


--prop_bencode :: Eq a => BEncode a => a -> Bool
--prop_bencode a = BE.decode (BL.toStrict (BE.encode a)) == return a

--prop_urlencode :: Eq a => URLDecoded a => URLEncoded a => a -> Bool
--prop_urlencode a = urlDecode (T.pack (urlEncode a)) == a

instance Arbitrary Event where
  arbitrary = elements [minBound..maxBound]

instance Arbitrary PortNumber where
  arbitrary = fromIntegral <$> (arbitrary :: Gen Word16)

instance Arbitrary AnnounceQuery where
  arbitrary = AnnounceQuery
    <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    <*> arbitrary <*> arbitrary <*> arbitrary

spec :: Spec
spec = do
  describe "Announce" $ do
    it "properly url encoded" $ property $ \ q ->
      parseAnnounceQuery (renderAnnounceQuery q)
        `shouldBe` Right q

  describe "Scrape" $ do
    return ()