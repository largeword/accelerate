{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Module      : Data.Array.Accelerate.Trafo.Environment
-- Copyright   : [2012..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.Trafo.Environment
  where

import Data.Array.Accelerate.AST
import Data.Array.Accelerate.AST.Environment
import Data.Array.Accelerate.AST.Idx
import Data.Array.Accelerate.AST.LeftHandSide
import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Representation.Array
import Data.Array.Accelerate.Trafo.Substitution
import Data.Array.Accelerate.Type

import Data.Array.Accelerate.Debug.Internal.Stats                   as Stats


-- An environment that holds let-bound scalar expressions. The second
-- environment variable env' is used to project out the corresponding
-- index when looking up in the environment congruent expressions.
--
data Gamma arr env env' where
  EmptyExp :: Gamma arr env env'

  PushExp  :: Gamma arr env env'
           -> WeakOpenExp arr env t
           -> Gamma arr env (env', t)

data WeakOpenExp arr env t where
  Subst    :: env :> env'
           -> PreOpenExp  arr env  t
           -> PreOpenExp  arr env' t {- LAZY -}
           -> WeakOpenExp arr env' t

-- XXX: The simplifier calls this function every time it moves under a let
-- binding. This means we have a number of calls to 'weakenE' exponential in the
-- depth of nested let bindings, which quickly causes problems.
--
-- We can improve the situation slightly by observing that weakening by a single
-- variable does no less work than weaking by multiple variables at once; both
-- require a deep copy of the AST. By exploiting laziness (or, an IORef) we can
-- queue up multiple weakenings to happen in a single step.
--
-- <https://github.com/AccelerateHS/accelerate-llvm/issues/20>
--
incExp
    :: Gamma arr env     env'
    -> Gamma arr (env,s) env'
incExp EmptyExp        = EmptyExp
incExp (PushExp env w) = incExp env `PushExp` subs w
  where
    subs :: forall arr env s t. WeakOpenExp arr env t -> WeakOpenExp arr (env,s) t
    subs (Subst k (e :: PreOpenExp arr env_ t) _) = Subst (weakenSucc' k) e (weakenE (weakenSucc' k) e)

prjExp :: HasCallStack => Idx env' t -> Gamma arr env env' -> PreOpenExp arr env t
prjExp ZeroIdx      (PushExp _   (Subst _ _ e)) = e
prjExp (SuccIdx ix) (PushExp env _)             = prjExp ix env
prjExp _            _                           = internalError "inconsistent valuation"

pushExp :: Gamma arr env env' -> PreOpenExp arr env t -> Gamma arr env (env',t)
pushExp env e = env `PushExp` Subst weakenId e e

{--
lookupExp
    :: Gamma      arr env env'
    -> PreOpenExp arr env      t
    -> Maybe (Idx env' t)
lookupExp EmptyExp        _ = Nothing
lookupExp (PushExp env e) x
  | Just Refl <- match e x  = Just ZeroIdx
  | otherwise               = SuccIdx `fmap` lookupExp env x
--}

-- As part of various transformations we often need to lift out array valued
-- inputs to be let-bound at a higher point.
--
-- The Extend type is a heterogeneous snoc-list of array terms that witnesses
-- how the array environment is extended by binding these additional terms.
--
data Extend s f env env' where
  BaseEnv :: Extend s f env env

  PushEnv :: Extend s f env env'
          -> LeftHandSide s t env' env''
          -> f env' t
          -> Extend s f env env''

pushArrayEnv
    :: HasArraysR acc
    => Extend ArrayR acc aenv aenv'
    -> acc aenv' (Array sh e)
    -> Extend ArrayR acc aenv (aenv', Array sh e)
pushArrayEnv env a = PushEnv env (LeftHandSideSingle $ arrayR a) a


-- Append two environment witnesses
--
append :: Extend s acc env env' -> Extend s acc env' env'' -> Extend s acc env env''
append x BaseEnv           = x
append x (PushEnv e lhs a) = PushEnv (append x e) lhs a

-- Bring into scope all of the array terms in the Extend environment list. This
-- converts a term in the inner environment (aenv') into the outer (aenv).
--
bind :: (forall env t. PreOpenAcc acc env t -> acc env t)
     -> Extend ArrayR  acc aenv aenv'
     -> PreOpenAcc acc      aenv' a
     -> PreOpenAcc acc aenv       a
bind _      BaseEnv           = id
bind inject (PushEnv g lhs a) = bind inject g . Alet lhs a . inject

-- Sink a term from one array environment into another, where additional
-- bindings have come into scope according to the witness and no old things have
-- vanished.
--
sinkA :: Sink f => Extend s acc env env' -> f env t -> f env' t
sinkA env = weaken (sinkWeaken env) -- TODO: Fix Stats sinkA vs sink1

sink1 :: Sink f => Extend s acc env env' -> f (env,t') t -> f (env',t') t
sink1 env = weaken $ sink $ sinkWeaken env

sinkWeaken :: Extend s acc env env' -> env :> env'
sinkWeaken (PushEnv e (LeftHandSideWildcard _) _) = sinkWeaken e
sinkWeaken (PushEnv e (LeftHandSideSingle _)   _) = weakenSucc' $ sinkWeaken e
sinkWeaken (PushEnv e (LeftHandSidePair l1 l2) _) = sinkWeaken (PushEnv (PushEnv e l1 undefined) l2 undefined)
sinkWeaken BaseEnv = Stats.substitution "sink" weakenId

sinkArrayInstr :: RebuildableExp f => Extend s acc aenv aenv' -> f (ArrayInstr aenv) env t -> f (ArrayInstr aenv') env t
sinkArrayInstr env = weakenArrayInstr (sinkWeaken env)

-- Wrapper around OpenExp, with the order of type arguments env and aenv flipped
newtype OpenExp' aenv env e = OpenExp' (OpenExp env aenv e)

bindExps :: Extend ScalarType (OpenExp' aenv) env env'
         -> OpenExp env' aenv e
         -> OpenExp env  aenv e
bindExps BaseEnv = id
bindExps (PushEnv g lhs (OpenExp' b)) = bindExps g . Let lhs b

