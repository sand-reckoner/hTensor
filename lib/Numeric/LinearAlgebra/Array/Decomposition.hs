{-# LANGUAGE FlexibleContexts #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Packed.Array.Decomposition
-- Copyright   :  (c) Alberto Ruiz 2009
-- License     :  BSD3
-- Maintainer  :  Alberto Ruiz
-- Stability   :  experimental
--
-- Common multidimensional array decompositions. See the paper by Kolda & Balder.
--
-----------------------------------------------------------------------------

module Numeric.LinearAlgebra.Array.Decomposition (
    -- * HOSVD
    hosvd, hosvd', truncateFactors,
    -- * CP
    cpAuto, cpRun, cpInitRandom, cpInitSvd,
    -- * Utilities
    ALSParam(..), defaultParameters
) where

import Numeric.LinearAlgebra.Array
import Numeric.LinearAlgebra.Array.Internal(seqIdx,namesR,sizesR,renameRaw)
import Numeric.LinearAlgebra.Array.Util
import Numeric.LinearAlgebra.Array.Solve
import Numeric.LinearAlgebra.HMatrix hiding (scalar)
import Data.List
import System.Random
--import Control.Parallel.Strategies

{- | Full version of 'hosvd'.

    The first element in the result pair is a list with the core (head) and rotations so that
    t == product (fst (hsvd' t)).

    The second element is a list of rank and singular values along each mode,
    to give some idea about core structure.
-}
hosvd' :: Array Double -> ([Array Double],[(Int,Vector Double)])
hosvd' t = (factors,ss) where
    (rs,ss) = unzip $ map usOfSVD $ flats t
    n = length rs
    dummies = take n $ seqIdx (2*n) "" \\ (namesR t)
    axs = zipWith (\a b->[a,b]) dummies (namesR t)
    factors = renameRaw core dummies : zipWith renameRaw (map (fromMatrix None None . tr) rs) axs
    core = product $ renameRaw t dummies : zipWith renameRaw (map (fromMatrix None None) rs) axs

{- | Multilinear Singular Value Decomposition (or Tucker's method, see Lathauwer et al.).

    The result is a list with the core (head) and rotations so that
    t == product (hsvd t).

    The core and the rotations are truncated to the rank of each mode.

    Use 'hosvd'' to get full transformations and rank information about each mode.

-}
hosvd :: Array Double -> [Array Double]
hosvd a = truncateFactors rs h where
    (h,info) = hosvd' a
    rs = map fst info


-- get the matrices of the flattened tensor for all dimensions
flats t = map (flip fibers t) (namesR t)


--check trans/ctrans
usOfSVD m = if rows m < cols m
        then let (s2,u) = eigSH' $ m <> tr m
                 s = sqrt (abs s2)
              in (u,r s)
        else let (s2,v) = eigSH' $ tr m <> m
                 s = sqrt (abs s2)
                 u = m <> v <> pinv (diag s)
              in (u,r s)
    where r s = (ranksv (sqrt peps) (max (rows m) (cols m)) (toList s), s)
                -- (rank m, sv m) where sv m = s where (_,s,_) = svd m


ttake ns t = (foldl1' (.) $ zipWith (onIndex.take) ns (namesR t)) t

-- | Truncate a 'hosvd' decomposition from the desired number of principal components in each dimension.
truncateFactors :: [Int] -> [Array Double] -> [Array Double]
truncateFactors _ [] = []
truncateFactors ns (c:rs) = ttake ns c : zipWith f rs ns
    where f r n = onIndex (take n) (head (namesR r)) r

------------------------------------------------------------------------

frobT = norm_2 . coords

------------------------------------------------------------------------

unitRows [] = error "unitRows []"
unitRows (c:as) = foldl1' (.*) (c:xs) : as' where
    (xs,as') = unzip (map g as)
    g a = (x,a')
        where n = head (namesR a) -- hmmm
              rs = parts a n
              scs = map frobT rs
              x = diagT scs (order c) `renameRaw` (namesR c)
              a' = (zipWith (.*) (map (scalar.recip) scs)) `onIndex` n $ a


{- | Basic CP optimization for a given rank. The result includes the obtained sequence of errors.

For example, a rank 3 approximation can be obtained as follows, where initialization
is based on the hosvd:

@
(y,errs) = cpRank 3 t
     where cpRank r t = cpRun (cpInitSvd (fst $ hosvd' t) r) defaultParameters t
@

-}
cpRun :: [Array Double] -- ^ starting point
      -> ALSParam None Double     -- ^ optimization parameters
      -> Array Double -- ^ input array
      -> ([Array Double], [Double]) -- ^ factors and error history
cpRun s0 params t = (unitRows $ head s0 : sol, errs) where
    (sol,errs) = mlSolve params [head s0] (tail s0) t



{- | Experimental implementation of the CP decomposition, based on alternating
     least squares. We try approximations of increasing rank, until the relative reconstruction error is below a desired percent of Frobenius norm (epsilon).

     The approximation of rank k is abandoned if the error does not decrease at least delta% in an iteration.

    Practical usage can be based on something like this:

@
cp finit d e t = cpAuto (finit t) defaultParameters {delta = d, epsilon = e} t

cpS = cp (InitSvd . fst . hosvd')
cpR s = cp (cpInitRandom s)
@

     So we can write

@
 \-\- initialization based on hosvd
y = cpS 0.01 1E-6 t

 \-\- (pseudo)random initialization
z = cpR seed 0.1 0.1 t
@

-}
cpAuto :: (Int -> [Array Double]) -- ^ Initialization function for each rank
       -> ALSParam None Double    -- ^ optimization parameters
       -> Array Double -- ^ input array
       -> [Array Double] -- ^ factors
cpAuto finit params t = fst . head . filter ((<epsilon params). head . snd)
                      . map (\r->cpRun (finit r) params t) $ [1 ..]

----------------------

-- | cp initialization based on the hosvd
cpInitSvd :: [NArray None Double] -- ^ hosvd decomposition of the target array
          -> Int                  -- ^ rank
          -> [NArray None Double] -- ^ starting point
cpInitSvd (hos) k = d:as
    where c:rs = hos
          as = trunc (replicate (order c) k) rs
          d = diagT (replicate k 1) (order c) `renameO` (namesR c)
          trunc ns xs = zipWith f xs ns
              where f r n = onIndex (take n . cycle) (head (namesR r)) r

cpInitSeq rs t k = ones:as where
    n = order t
    auxIndx = take n $ seqIdx (2*n) "" \\ namesR t
              --take (order t) $ map return ['a'..] \\ namesR t
    ones = diagT (replicate k 1) (order t) `renameO` auxIndx
    ts = takes (map (*k) (sizesR t)) rs
    as = zipWith4 f ts auxIndx (namesR t) (sizesR t)
    f c n1 n2 p = (listArray [k,p] c) `renameO` [n1,n2]

takes [] _ = []
takes (n:ns) xs = take n xs : takes ns (drop n xs)

-- | pseudorandom cp initialization from a given seed
cpInitRandom :: Int        -- ^ seed
             -> NArray i t -- ^ target array to decompose
             -> Int        -- ^ rank
             -> [NArray None Double] -- ^ random starting point
cpInitRandom seed = cpInitSeq (randomRs (-1,1) (mkStdGen seed))

----------------------------------------------------------------------
