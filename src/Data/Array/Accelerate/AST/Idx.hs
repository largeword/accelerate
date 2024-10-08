{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE EmptyCase           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns        #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Module      : Data.Array.Accelerate.AST.Idx
-- Copyright   : [2008..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Typed de Bruijn indices
--

module Data.Array.Accelerate.AST.Idx (
  Idx(ZeroIdx, SuccIdx, VoidIdx),
  idxToInt,
  rnfIdx, liftIdx, matchIdx,

  PairIdx(..)
) where

import Control.DeepSeq
import Data.Kind
import Language.Haskell.TH.Extra                                    hiding ( Type )

#ifndef ACCELERATE_INTERNAL_CHECKS
import Data.Type.Equality                                           ( (:~:)(Refl) )
import Unsafe.Coerce                                                ( unsafeCoerce )
#endif


#ifdef ACCELERATE_INTERNAL_CHECKS

-- | De Bruijn variable index projecting a specific type from a type
-- environment.  Type environments are nested pairs (..((), t1), t2, ..., tn).
--
data Idx env t where
  ZeroIdx ::              Idx (env, t) t
  SuccIdx :: Idx env t -> Idx (env, s) t
  deriving (Eq, Ord)

idxToInt :: Idx env t -> Int
idxToInt ZeroIdx       = 0
idxToInt (SuccIdx idx) = 1 + idxToInt idx

rnfIdx :: Idx env t -> ()
rnfIdx ZeroIdx      = ()
rnfIdx (SuccIdx ix) = rnfIdx ix

liftIdx :: Idx env t -> CodeQ (Idx env t)
liftIdx ZeroIdx      = [|| ZeroIdx ||]
liftIdx (SuccIdx ix) = [|| SuccIdx $$(liftIdx ix) ||]

{-# INLINEABLE matchIdx #-}
matchIdx :: Idx env s -> Idx env t -> Maybe (s :~: t)
matchIdx ZeroIdx     ZeroIdx     = Just Refl
matchIdx (SuccIdx u) (SuccIdx v) = matchIdx u v
matchIdx _           _           = Nothing

#else

-- | De Bruijn variable index projecting a specific type from a type
-- environment.  Type environments are nested pairs (..((), t1), t2, ..., tn).
--
-- Outside of this file, pretend that this is an ordinary GADT:
-- data Idx env t where
--   ZeroIdx ::              Idx (env, t) t
--   SuccIdx :: Idx env t -> Idx (env, s) t
--
-- For performance, it uses an Int under the hood.
--
newtype Idx :: Type -> Type -> Type where
  UnsafeIdxConstructor :: { unsafeRunIdx :: Int } -> Idx env t
  deriving (Eq, Ord)
{-# COMPLETE ZeroIdx, SuccIdx #-}

pattern ZeroIdx :: forall envt t. () => forall env. (envt ~ (env, t)) => Idx envt t
pattern ZeroIdx <- (\x -> (idxToInt x, unsafeCoerce Refl) -> (0, Refl :: envt :~: (env, t)))
  where
    ZeroIdx = UnsafeIdxConstructor 0

pattern SuccIdx :: forall envs t. () => forall s env. (envs ~ (env, s)) => Idx env t -> Idx envs t
pattern SuccIdx idx <- (unSucc -> Just (idx, Refl))
  where
    SuccIdx (UnsafeIdxConstructor i) = UnsafeIdxConstructor (i+1)

unSucc :: Idx envs t -> Maybe (Idx env t, envs :~: (env, s))
unSucc (UnsafeIdxConstructor i)
  | i < 1     = Nothing
  | otherwise = Just (UnsafeIdxConstructor (i-1), unsafeCoerce Refl)

idxToInt :: Idx env t -> Int
idxToInt = unsafeRunIdx

rnfIdx :: Idx env t -> ()
rnfIdx !_ = ()

liftIdx :: Idx env t -> CodeQ (Idx env t)
liftIdx (UnsafeIdxConstructor i) = [|| UnsafeIdxConstructor i ||]

{-# INLINEABLE matchIdx #-}
matchIdx :: Idx env s -> Idx env t -> Maybe (s :~: t)
matchIdx (UnsafeIdxConstructor i) (UnsafeIdxConstructor j)
  | i == j = Just $ unsafeCoerce Refl
  | otherwise = Nothing
#endif

instance NFData (Idx env t) where
  rnf = rnfIdx

-- | Despite the 'complete' pragma above, GHC can't infer that there is no
-- pattern possible if the environment is empty. This can be used instead.
--
{-# COMPLETE VoidIdx #-}
pattern VoidIdx :: forall env t a. (env ~ ()) => () => a -> Idx env t
pattern VoidIdx a <- (\case{} -> a)

{-# COMPLETE VoidIdx #-}

data PairIdx p a where
  PairIdxLeft  :: PairIdx (a, b) a
  PairIdxRight :: PairIdx (a, b) b
