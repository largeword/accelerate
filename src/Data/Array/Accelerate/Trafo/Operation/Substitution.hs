{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns        #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Module      : Data.Array.Accelerate.Trafo.Operation.Substitution
-- Copyright   : [2012..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.Trafo.Operation.Substitution (
  Sink(..),
  reindexPartial,
  reindexPartialAfun,
  pair, alet,
) where

import Data.Array.Accelerate.AST.Idx
import Data.Array.Accelerate.AST.Var
import Data.Array.Accelerate.AST.LeftHandSide
import Data.Array.Accelerate.AST.Operation
import Data.Array.Accelerate.AST.Environment
import Data.Array.Accelerate.Representation.Type
import Data.Array.Accelerate.Trafo.Var
import Data.Array.Accelerate.Trafo.Substitution       (Sink(..))
import Data.Array.Accelerate.Trafo.Exp.Substitution

data SunkReindexPartial f env env' where
  Sink     :: SunkReindexPartial f env env' -> SunkReindexPartial f (env, s) (env', s)
  ReindexF :: ReindexPartial f env env' -> SunkReindexPartial f env env'

reindexPartial :: (IsExecutableAcc exe, Applicative f) => ReindexPartial f env env' -> PreOpenAcc exe env t -> f (PreOpenAcc exe env' t)
reindexPartial k = reindexA' (ReindexF k)

reindexPartialAfun :: (IsExecutableAcc exe, Applicative f) => ReindexPartial f env env' -> PreOpenAfun exe env t -> f (PreOpenAfun exe env' t)
reindexPartialAfun k = reindexAfun' (ReindexF k)

instance IsExecutableAcc exe => Sink (PreOpenAcc exe) where
  weaken k = runIdentity . reindexPartial (Identity . (k >:>))

instance IsExecutableAcc exe => Sink (PreOpenAfun exe) where
  weaken k = runIdentity . reindexPartialAfun (Identity . (k >:>))

sinkReindexWithLHS :: LeftHandSide s t env1 env1' -> LeftHandSide s t env2 env2' -> SunkReindexPartial f env1 env2 -> SunkReindexPartial f env1' env2'
sinkReindexWithLHS (LeftHandSideWildcard _) (LeftHandSideWildcard _) k = k
sinkReindexWithLHS (LeftHandSideSingle _)   (LeftHandSideSingle _)   k = Sink k
sinkReindexWithLHS (LeftHandSidePair a1 b1) (LeftHandSidePair a2 b2) k = sinkReindexWithLHS b1 b2 $ sinkReindexWithLHS a1 a2 k
sinkReindexWithLHS _ _ _ = error "sinkReindexWithLHS: left hand sides don't match"

-- All functions ending in a prime work with SunkReindexPartial instead of ReindexPartial.
reindex' :: Applicative f => SunkReindexPartial f env env' -> ReindexPartial f env env'
reindex' (ReindexF f) = f
reindex' (Sink k) = \case
  ZeroIdx    -> pure ZeroIdx
  SuccIdx ix -> SuccIdx <$> reindex' k ix

reindexVar' :: Applicative f => SunkReindexPartial f env env' -> Var s env t -> f (Var s env' t)
reindexVar' k (Var repr ix) = Var repr <$> reindex' k ix

reindexVars' :: Applicative f => SunkReindexPartial f env env' -> Vars s env t -> f (Vars s env' t)
reindexVars' _ TupRunit = pure $ TupRunit
reindexVars' k (TupRsingle var) = TupRsingle <$> reindexVar' k var
reindexVars' k (TupRpair v1 v2) = TupRpair <$> reindexVars' k v1 <*> reindexVars' k v2

reindexArrayInstr' :: Applicative f => SunkReindexPartial f env env' -> ArrayInstr env (s -> t) -> f (ArrayInstr env' (s -> t))
reindexArrayInstr' k (Index     v) = Index     <$> reindexVar' k v
reindexArrayInstr' k (Parameter v) = Parameter <$> reindexVar' k v

reindexExp' :: (Applicative f, RebuildableExp e) => SunkReindexPartial f benv benv' -> e (ArrayInstr benv) env t -> f (e (ArrayInstr benv') env t)
reindexExp' k = rebuildArrayInstrPartial (rebuildArrayInstrMap $ reindexArrayInstr' k)

reindexA' :: forall exe f env env' t. (IsExecutableAcc exe, Applicative f) => SunkReindexPartial f env env' -> PreOpenAcc exe env t -> f (PreOpenAcc exe env' t)
reindexA' k = \case
    Exec exe -> Exec <$> reindexExecPartial (reindex' k) exe
    Return vars -> Return <$> reindexVars' k vars
    Compute e -> Compute <$> reindexExp' k e
    Alet lhs bnd body
      | Exists lhs' <- rebuildLHS lhs -> Alet lhs' <$> travA bnd <*> reindexA' (sinkReindexWithLHS lhs lhs' k) body
    Alloc shr tp sh -> Alloc shr tp <$> reindexVars' k sh
    Use tp buffer -> pure $ Use tp buffer
    Unit var -> Unit <$> reindexVar' k var
    Clone shr sh buffer -> Clone shr <$> reindexVars' k sh <*> reindexVar' k buffer
    Acond c t f -> Acond <$> reindexVar' k c <*> travA t <*> travA f
    Awhile c f i -> Awhile <$> reindexAfun' k c <*> reindexAfun' k f <*> travA i
  where
    travA :: PreOpenAcc exe env s -> f (PreOpenAcc exe env' s)
    travA = reindexA' k

reindexAfun' :: (IsExecutableAcc exe, Applicative f) => SunkReindexPartial f env env' -> PreOpenAfun exe env t -> f (PreOpenAfun exe env' t)
reindexAfun' k (Alam lhs f)
  | Exists lhs' <- rebuildLHS lhs = Alam lhs' <$> reindexAfun' (sinkReindexWithLHS lhs lhs' k) f
reindexAfun' k (Abody a) = Abody <$> reindexA' k a

pair :: forall exe env a b. IsExecutableAcc exe => PreOpenAcc exe env a -> PreOpenAcc exe env b -> PreOpenAcc exe env (a, b)
pair a b = goA weakenId a
  where
    -- Traverse 'a' and look for a return. We can jump over let bindings
    -- If we don't find a 'return', we must first bind the value in a let,
    -- and then use the newly defined variables instead.
    --
    goA :: env :> env' -> PreOpenAcc exe env' a -> PreOpenAcc exe env' (a, b)
    goA k (Alet lhs bnd x) = Alet lhs bnd $ goA (weakenWithLHS lhs .> k) x
    goA k (Return vars)    = goB vars $ weaken k b
    goA k acc
      | DeclareVars lhs k' value <- declareVars $ groundsR acc
                           = Alet lhs acc $ goB (value weakenId) $ weaken (k' .> k) b

    goB :: GroundVars env' a -> PreOpenAcc exe env' b -> PreOpenAcc exe env' (a, b)
    goB varsA (Alet lhs bnd x) = Alet lhs bnd $ goB (weakenVars (weakenWithLHS lhs) varsA) x
    goB varsA (Return varsB)   = Return (TupRpair varsA varsB)
    goB varsA acc
      | DeclareVars lhs k value <- declareVars $ groundsR b
                               = Alet lhs acc $ Return (TupRpair (weakenVars k varsA) (value weakenId))

alet :: IsExecutableAcc exe => GLeftHandSide t env env' -> PreOpenAcc exe env t -> PreOpenAcc exe env' s -> PreOpenAcc exe env s
alet lhs1 (Alet lhs2 a1 a2) a3
  | Exists lhs1' <- rebuildLHS lhs1 = Alet lhs2 a1 $ alet lhs1' a2 $ weaken (sinkWithLHS lhs1 lhs1' $ weakenWithLHS lhs2) a3
alet lhs  (Return vars)     a       = weaken (substituteLHS lhs vars) a
alet lhs  bnd               a       = Alet lhs bnd a
