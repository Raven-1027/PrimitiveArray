
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Index structures for unordered data types. We use this for Hamiltonian
-- path problems, where we need sets with an interface.

module Data.Array.Repa.Index.Set where

import           Data.Aeson
import           Data.Array.Repa.Index
import           Data.Array.Repa.Shape
import           Data.Binary
import           Data.Bits
import           Data.Serialize
import           Data.Vector.Fusion.Stream.Size
import           Data.Vector.Unboxed.Deriving
import           GHC.Generics
import qualified Data.Vector.Fusion.Stream.Monadic as M
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Unboxed as VU

import           Data.Bits.Ordered
import           Data.Array.Repa.ExtShape



-- | a path set denotes a set of visited nodes 'psSet' together with the
-- node that was visited first 'psFirst' and the node visited last
-- 'psLast'.
--
-- NOTE we use 'Int' here, as @Int@s have good optimization and many
-- operations assume @Int@s instead of @Word@s.
--
-- TODO should @psSet@ contain @psFirst@ and @psLast@ or not? Currently:
-- yes! (we want to differentiate having visited nothing (all @PathSet
-- 0 0 0@) to having visited just node 0 @(PathSet 1 0 0)@. Have @psFirst@
-- and @psLast@ in @psSet@ increases the memory requirements to @N*N*2^N@
-- from @N*N*2^(N-2)@ i.e. by a factor of 4.
--
-- TODO newtype PathSet = PathSet { Z:.Int:.Int:.Int }
--
-- TODO rangeStream currently uses explicitly constructed vectors for the
-- sets. It would be better to be able to enumerate these explicitly. This
-- will come with a later version of the OrderedBits library.

data PathSet = PathSet
  { psSet   :: {-# UNPACK #-} !Int
  , psFirst :: {-# UNPACK #-} !Int
  , psLast  :: {-# UNPACK #-} !Int
  }
  deriving (Eq,Ord,Show,Generic)

derivingUnbox "PathSet"
  [t| PathSet -> (Int,Int,Int) |]
  [| \ (PathSet s f l) -> (s,f,l) |]
  [| \ (s,f,l) -> PathSet s f l |]

instance Binary    PathSet
instance Serialize PathSet
instance ToJSON    PathSet
instance FromJSON  PathSet



instance Shape sh => Shape (sh:.PathSet) where
  {-# INLINE [1] rank #-}
  rank (sh:._) = rank sh + 1
  {-# INLINE [1] zeroDim #-}
  zeroDim = zeroDim :. PathSet 0 0 0
  {-# INLINE [1] unitDim #-}
  -- TODO do we need 1/1/1 or 1/0/0 ? pretty sure about 1 1 1 but I am
  -- using popcounts in size/toIndex currently anyway (which I shouldn't!)
  -- but at least the "pointed to element" stays the same as it is shifted
  -- as well (which probably means I should use @rs `shiftR` popCount ls
  -- + ls@
  unitDim = unitDim :. PathSet 1 1 1
  {-# INLINE [1] intersectDim #-}
  intersectDim = error "sh:.PathSet / intersectDim"
  {-# INLINE [1] addDim #-}
  addDim (sh1 :. PathSet ls lf ll) (sh2 :. PathSet rs rf rl)
    = addDim sh1 sh2 :. PathSet (ls `shiftL` popCount rs) (lf+rf) (ll+rl)
  {-# INLINE [1] size #-}
  size (sh1 :. PathSet s _ _)
    = let !p = popCount s in size (sh1:.s:.p:.p)
    -- let p = popCount s + 1 in size sh1 * s * p * p
  {-# INLINE [1] sizeIsValid #-}
  sizeIsValid (sh1 :. PathSet p _ _)
    | size sh1 > 0 = p < maxBound `div` size sh1
    | otherwise    = False
  {-# INLINE [1] toIndex #-}
  -- Recart the calculation in terms known to repa
  -- TODO check this!
  toIndex (shF :. PathSet sS fF lL) (sh :. PathSet s f l)
    = let !p = popCount sS
      in  toIndex (shF:.sS:.p:.p) (sh:.s:.f:.l)
  {-
    = let p = popCount sS + 1
      in  toIndex shF sh * (sS * p * p)
          + s * p * p + f * p + l
  -}
  {-# INLINE [1] fromIndex #-}
  fromIndex = error "sh:.PathSet / fromIndex"
  {-# INLINE [1] inShapeRange #-}
  inShapeRange = error "sh:.PathSet / inShapeRange"
  {-# NOINLINE listOfShape #-}
  listOfShape = error "sh:.PathSet / listOfShape"
  {-# NOINLINE shapeOfList #-}
  shapeOfList = error "sh:.PathSet / shapeOfList"
  {-# INLINE deepSeq #-}
  deepSeq (sh :. n) x = deepSeq sh (n `seq` x)

instance ExtShape sh => ExtShape (sh:.PathSet) where
  {-# INLINE [1] subDim #-}
  subDim (sh1 :. PathSet ls lf ll) (sh2 :. PathSet rs rf rl)
    = subDim sh1 sh2 :. PathSet (ls `shiftR` popCount rs) (lf-rf) (ll-rl)
  {-# INLINE rangeList #-}
  rangeList _ _ = error "rangeList/not implemented"
  {-# INLINE rangeStream #-}
  -- we assume a set starting at "nothing set"
  rangeStream (sh1 :. PathSet _ _ _) (sh2 :. PathSet rs rf rl) = M.flatten mk step Unknown $ rangeStream sh1 sh2
    where mk is = let v = popCntMemoInt (popCount rs)
                  in  return $ Left (is:.v)
          step (Left (is:.v))
            | G.null v  = return $ M.Done
            | pcnt == 0 = return $ M.Yield (is:.PathSet  0 0 0) $ Left  (is:.vt) -- only one case
            | pcnt == 1 = return $ M.Yield (is:.PathSet vh l l) $ Left  (is:.vt) -- only one case
            | otherwise = return $ M.Skip                       $ Right (is:.v:.vh:.vh `clearBit` l)  -- prepare bit pools
            where pcnt = popCount  vh
                  l    = lsbActive vh
                  vh   = G.unsafeHead v
                  vt   = G.unsafeTail v
          step (Right (is:.v:.fp:.lp))
            | fp==0     = return $ M.Skip                         $ Left  (is:.vt)  -- the fp pool is empty, reset everything
            | lp==0     = return $ M.Skip                         $ Right (is:.v:.fn:.vh `clearBit` lsbActive fn) -- new lp pool with cutten fp
            | otherwise = return $ M.Yield (is:.PathSet vh af al) $ Right (is:.v:.fp:.lp `clearBit` al) -- just continue with next lp pool element
            where vh = G.unsafeHead v
                  vt = G.unsafeTail v
                  af = lsbActive fp
                  al = lsbActive lp
                  fn = fp `clearBit` af
          {-# INLINE [1] mk #-}
          {-# INLINE [1] step #-}
  {-# INLINE topmostIndex #-}
  topmostIndex _ _ = error "topmostIndex/not implemented"

{-
test :: IO Int
test = M.length $ rangeStream (Z:.PathSet 0 0 0) (Z:.PathSet (2^14 -1) 0 0)
{-# NOINLINE test #-}
-}

