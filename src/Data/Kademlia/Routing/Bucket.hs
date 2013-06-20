-- |
--   Copyright   :  (c) Sam T. 2013
--   License     :  MIT
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--   Bucket is used to
--
--   Bucket is kept sorted by time last seen — least-recently seen
--   node at the head, most-recently seen at the tail. Reason: when we
--   insert a node into the bucket we first filter nodes with smaller
--   lifetime since they more likely leave network and we more likely
--   don't reach list end. This should reduce list traversal, we don't
--   need to reverse list in insertion routines.
--
--   Bucket is also limited in its length — thus it's called k-bucket.
--   When bucket becomes full we should split it in two lists by
--   current span bit. Span bit is defined by depth in the routing
--   table tree. Size of the bucket should be choosen such that it's
--   very unlikely that all nodes in bucket fail within an hour of
--   each other.
--
{-# LANGUAGE RecordWildCards #-}
module Data.Kademlia.Routing.Bucket
       ( Bucket(maxSize, kvs)

         -- * Query
       , size, isFull, member

         -- * Construction
       , empty, singleton

         -- * Modification
       , enlarge, split, insert

         -- * Defaults
       , defaultBucketSize
       ) where

import Control.Applicative hiding (empty)
import Data.Bits
import Data.List as L hiding (insert)


type Size = Int

data Bucket k v = Bucket {
    -- | We usually use equally sized buckets in the all routing table
    -- so keeping max size in each bucket lead to redundancy. Altrough
    -- it allow us to use some interesting schemes in route tree.
    maxSize :: Size

    -- | Key -> value pairs as described above.
    --   Each key in a given bucket should be unique.
  , kvs     :: [(k, v)]
  }

-- | Gives /current/ size of bucket.
--
--   forall bucket. size bucket <= maxSize bucket
--
size :: Bucket k v -> Size
size = L.length . kvs

isFull :: Bucket k v -> Bool
isFull Bucket {..} = L.length kvs == maxSize

member :: Eq k => k -> Bucket k v -> Bool
member k = elem k . map fst . kvs

empty :: Size -> Bucket k v
empty s = Bucket (max 0 s) []

singleton :: Size -> k -> v -> Bucket k v
singleton s k v = Bucket (max 1 s) [(k, v)]


-- | Increase size of a given bucket.
enlarge :: Size -> Bucket k v -> Bucket k v
enlarge additional b = b { maxSize = maxSize b + additional }

split :: Bits k => Int -> Bucket k v -> (Bucket k v, Bucket k v)
split index Bucket {..} =
    let (far, near) = partition spanBit kvs
    in (Bucket maxSize near, Bucket maxSize far)
  where
    spanBit = (`testBit` index) . fst


-- move elem to the end in one traversal
moveToEnd :: Eq k => (k, v) -> Bucket k v -> Bucket k v
moveToEnd kv@(k, _) b = b { kvs = go (kvs b) }
  where
    go [] = []
    go (x : xs)
      | fst x == k = xs ++ [kv]
      | otherwise  = x : go xs

insertToEnd :: (k, v) -> Bucket k v -> Bucket k v
insertToEnd kv b = b { kvs = kvs b ++ [kv] }

-- | * If the info already exists in bucket then move it to the end.
--
--   * If bucket is not full then insert the info to the end.
--
--   * If bucket is full then ping the least recently seen node.
--     Here we have a choice:
--
--         If node respond then move it the end and discard node
--         we  want to insert.
--
--         If not remove it from the bucket and add the
--         (we want to insert) node to the end.
--
insert :: Applicative f => Eq k
       => (v ->  f Bool)  -- ^ Ping RPC
       -> (k, v) -> Bucket k v -> f (Bucket k v)

insert ping new bucket@(Bucket {..})
    | fst new `member` bucket = pure (new `moveToEnd` bucket)
    | size bucket < maxSize   = pure (new `insertToEnd` bucket)
    | least : rest <- kvs     =
      let select alive = if alive then least else new
          mk most = Bucket maxSize (rest ++ [most])
      in mk . select <$> ping (snd least)
      where
--    | otherwise                 = pure bucket
     -- WARN: or maybe error "insertBucket: max size should not be 0" ?

lookup :: k -> Bucket k v -> Maybe v
lookup = undefined

closest :: Int -> k -> Bucket k v -> [(k, v)]
closest = undefined

-- | Most clients use this value for maximum bucket size.
defaultBucketSize :: Int
defaultBucketSize = 20