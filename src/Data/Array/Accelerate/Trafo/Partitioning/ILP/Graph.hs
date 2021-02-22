{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.Array.Accelerate.Trafo.Partitioning.ILP.Graph where

import Data.Array.Accelerate.Trafo.Partitioning.ILP.Labels

-- accelerate imports
import Data.Array.Accelerate.AST.Idx ( Idx(..) )
import Data.Array.Accelerate.AST.Operation

-- Data structures
-- In this file, order very often subly does matter.
-- To keep this clear, we use Set whenever it does not,
-- and [] only when it does. It's also often efficient
-- by removing duplicates.
import Data.Set (Set)
import Data.IntMap (IntMap)
import qualified Data.Set as S
import qualified Data.IntMap as M


-- GHC imports
import Data.Kind ( Type )
import Unsafe.Coerce (unsafeCoerce)


-- Limp is a Linear Integer Mixed Programming library.
-- We only use the Integer part (not the Mixed part, 
-- which allows you to add non-integer variables and
-- constraints). It has a backend that binds to CBC, 
-- which is apparently a good one? Does not seem to be
-- actively maintained though.
-- We can always switch to a different ILP library
-- later, the interfaces are all quite similar.
import qualified Numeric.Limp.Program as LIMP
import qualified Numeric.Limp.Rep     as LIMP
import Numeric.Limp.Program hiding ( Bounds, Constraint, Program, Linear, r )
import Numeric.Limp.Rep ( IntDouble )
import Data.Array.Accelerate.Array.Buffer
import Data.Array.Accelerate.Type
import Control.Monad.State


-- | We have Int variables represented by @Variable op@, and no real variables.
-- These type synonyms instantiate the @z@, @r@ and @c@ type variables in Limp.
type LIMP  datatyp op   = datatyp (Variable op) () IntDouble
type LIMP' datatyp op a = datatyp (Variable op) () IntDouble a

type Assignment op =  LIMP  LIMP.Assignment op
type Bounds     op = [LIMP  LIMP.Bounds     op]
type Constraint op =  LIMP  LIMP.Constraint op
type ILP        op =  LIMP  LIMP.Program    op
type Linear op res =  LIMP' LIMP.Linear     op res

-- | Directed edge (a,b): `b` depends on `a`.
type Edge = (Label, Label)


data Graph = Graph
  { graphNodes     :: Set Label
  , fusibleEdges   :: Set Edge  -- Can   be fused over, otherwise `a` before `b`.
  , infusibleEdges :: Set Edge  -- Can't be fused over, always    `a` before `b`.
  }
instance Semigroup Graph where
  Graph n f i <> Graph n' f' i' = Graph (n <> n') (f <> f') (i <> i')
instance Monoid Graph where
  mempty = Graph mempty mempty mempty

-- The graph is the 'common part' of the ILP,
-- each backend has to encode their own constraints
-- describing the fusion rules. The bounds is a [] instead of Set
-- for practical reasons (no Ord instance, LIMP expects a list) only.
data Information op = Info 
  { graphI :: Graph
  , constr :: Constraint op
  , bounds :: Bounds op
  }
instance Semigroup (Information op) where
  Info g c b <> Info g' c' b' = Info (g <> g') (c <> c') (b <> b')
instance Monoid (Information op) where
  mempty = Info mempty mempty mempty



data Variable op
  = Pi    Label                     -- For acyclic ordering of clusters
  | Fused Label Label               -- 0 is fused (same cluster), 1 is unfused. We do *not* have one of these for all pairs!
  | BackendSpecific (BackendVar op) -- Variables needed to express backend-specific fusion rules.

-- convenience synonyms
pi :: Label -> Linear op 'KZ
pi l = z1 $ Pi l
fused :: Label -> Label -> Linear op 'KZ
fused x y = z1 $ Fused x y


class MakesILP op where
  -- Variables needed to express backend-specific fusion rules.
  type BackendVar op

  -- | This function only needs to do the backend-specific things, that is, things which depend on the definition of @op@.
  -- That includes "BackendVar op's" and all their constraints/bounds, but also some (in)fusible edges.
  -- As a conveniece, fusible edges have already been made from all (incoming) labels in the LabelArgs to the current label. 
  -- These can be 'strengthened' by adding a corresponding infusible edge, in which case the fusible edge will later be optimised away.
  mkGraph :: op args -> LabelArgs args -> Label -> Information op

-- Control flow cannot be fused, so we make separate ILPs for e.g.
-- then-branch and else-branch. In the future, a possible optimisation is to
-- generate code for the awhile-condition twice: once maybe fused after the body,
-- once maybe fused after input. For now, condition and body are both treated
-- as 'foreign calls', like if-then-else.
-- The IntMap maps from a label to the corresponding ILP (only for things treated
-- as 'foreign calls', like control flow).
-- A program can result in multiple ILPs, for example, the body of an 'awhile' cannot be fused with anything outside of it.
-- you `can` encode this in the ILP, but since the solutions are independant of each other it should be much more efficient
-- to solve them separately. This avoids many 'infusible edges', and significantly reduces the search space. The extracted
-- subtree gets encoded as a sort of 'foreign call', preventing all fusion. TODO test with 'nested foreign functions':
-- Does the algorithm work if a while contains other Awhile or Acond nodes in its condition or body?


-- In the Operation-based AST, everything is powered by side effects.
-- This makes a full-program analysis like this much more difficult,
-- luckily the Args give us all the information we really require.
-- For each node, we get the set of incoming edges and the set
-- of outgoing edges. Let-bindings are easy, but the array-level
-- control flow (acond and awhile) compensate: their bodies form separate
-- graphs.
-- We can practically ignore 'Return' nodes.
-- Let bindings are more tricky, because of the side effects. Often,
-- a let will not add to the environment but instead mutate it.


makeFullGraph :: MakesILP op
              => PreOpenAcc op () a
              -> (Information op, IntMap (Information op), IntMap (Construction op))
makeFullGraph acc = (i, iM, constrM)
  where (FGRes i iM _ constrM, _) = runState (mkFullGraph acc) $ FGState LabelEnvNil 1 1

data FullGraphState env = FGState 
  { lenv   :: LabelEnv env -- sources of open outgoing edges for env
  , freshL :: Label  -- next fresh counter
  , freshE :: ELabel -- next fresh counter
  }
getL :: State (FullGraphState env) Label
getL = do
  l <- gets freshL
  modify (\fgs -> fgs {freshL = 1 + freshL fgs})
  return l
getE :: State (FullGraphState env) ELabel
getE = do
  e <- gets freshE
  modify (\fgs -> fgs {freshE = 1 + freshE fgs})
  return e
putE :: ELabel -> State (FullGraphState env) ()
putE e = modify $ \stt -> stt{freshE = e}
putEnv :: LabelEnv env -> State (FullGraphState env) ()
putEnv env = modify $ \stt -> stt{lenv = env}
data FullGraphResult op = FGRes
  { info   :: Information op
  , infoM  :: IntMap (Information op)
  , lset   :: Set Label    -- sources of open outgoing edges for result
  , construc :: IntMap (Construction op)
  }
instance Semigroup (FullGraphResult op) where
  FGRes a b c d <> FGRes e f g h = FGRes (a <> e) (b <> f) (c <> g) (d <> h)
instance Monoid (FullGraphResult op) where mempty = FGRes mempty mempty mempty mempty

mkFullGraph :: MakesILP op => PreOpenAcc op env a -> State (FullGraphState env) (FullGraphResult op)
mkFullGraph (Exec op args) = do
  l <- getL
  env <- gets lenv
  putEnv $ updateLabelEnv args env l
  let fuseedges = S.map (, l) $ getInputArgLabels args env
  return $ FGRes (mkGraph op (getLabelArgs args env) l <> mempty{graphI = Graph (S.singleton l) fuseedges mempty})
                 mempty
                 mempty
                 (M.singleton l $ CExe env args op)

-- We throw away the uniquenessess information here, that's Future Work..
-- Probably need to re-infer it after fusion anyway, until we incorporate in-place into ILP
mkFullGraph (Alet lhs _ bnd scp) = do
  e <- getE
  env <- gets lenv
  bndRes@(FGRes _ _ bndL _) <- mkFullGraph bnd
  let (e', env') = addLhsLabels lhs e bndL env
  putE e'
  -- Because the type of the state is different in the 'scope', we explicitly wrap/unwrap the State monad
  stt <- get 
  let (scpRes@(FGRes _ _ scpL _), scpState) = runState (mkFullGraph scp) stt{lenv = env'}
  put (scpState{lenv = weakLhsEnv lhs (lenv scpState)})
  return $ (bndRes <> scpRes){lset = scpL} 

mkFullGraph (Return vars) = do
  env <- gets lenv
  return $ mempty{lset = getLabelsTup vars env}
mkFullGraph (Compute expr) = do
  env <- gets lenv
  return $ mempty{lset = getLabelsExp expr env}
mkFullGraph Alloc{} = return mempty

-- We put this as a 'foreign' thing, forcing it to be unfused with anything.
-- This is because it doesn't go into a 'cluster': it's not a computation.
-- We simply let-bind it at some point before the computation!
-- note that we let the ILP decide where to let-bind it, so (within the control 
-- flow region) it might be bound way higher than needed, causing slower compile times.
mkFullGraph (Use sctype buff) = _ -- TODO do as the comment says ^^^^^^^^
  -- l <- getL
  -- return $ FGRes mempty{graph = mempty{graphNodes = S.singleton l}}
  --                mempty 
  --                (S.singleton l)
  --                (M.singleton l $ CUse sctype buff)

-- gets a variable from the env, puts it in a singleton buffer.
-- Here I'm assuming this fuses nicely, and doesn't even need a new label 
-- (reuse the one that belongs to the variable). Might need to add a label
-- to avoid obfuscating the AST though. Change when needed.
mkFullGraph (Unit var) = do
  env <- gets lenv
  return mempty{lset = getLabelsVar var env}

-- NOTE: We explicitly add infusible edges from every label in `lenv` to this Acond.
-- This makes the previous let-bindings strict: even if some result is only used in one
-- branch, we now require it to be present before we evaluate the condition.
-- I think this is safe: if a result is only used in one branch, it should be let-bound
-- within that branch already. Note that this also means we ignore the contents of 'cond' for the graph.
-- We also add edges from the Acond to the true-branch, and from the true-branch to the false-branch?
-- TODO check if this is right/needed/if passing even more fresh labels down is correct.
mkFullGraph (Acond cond tacc facc) = do
  l  <- getL
  tl <- getL
  fl <- getL
  env <- gets lenv
  let emptyEnv = emptyLabelEnv env
  putEnv emptyEnv
  FGRes tinfo tinfoM _ tConstr <- mkFullGraph tacc
  putEnv emptyEnv
  FGRes finfo finfoM _ fConstr <- mkFullGraph facc
  putEnv emptyEnv
  let nonfuse = S.map (,l) (getAllLabelsEnv env) <> S.fromList [(l,tl), (tl,fl)]
  return $ FGRes mempty{graphI = Graph (S.fromList [l, tl, fl]) mempty nonfuse}
                 (M.insert tl tinfo $ M.insert fl finfo $ tinfoM <> finfoM)
                 (S.singleton l)
                 (M.insert l (CITE env cond tl fl) $ tConstr <> fConstr)

-- like Acond. The biggest difference is that 'cond' is a function instead of an expression here.
-- In fact, for the graph, we use 'startvars' much like we used 'cond' in Acond, and we use
-- 'cond' and 'bdy' much like we used 'tbranch' and 'fbranch'.
mkFullGraph (Awhile u cond bdy startvars) = do
  l  <- getL
  cl <- getL
  bl <- getL
  env <- gets lenv
  let emptyEnv = emptyLabelEnv env
  putEnv emptyEnv
  FGRes cinfo cinfoM _ cConstr <- mkFullGraphF cond
  putEnv emptyEnv
  FGRes binfo binfoM _ bConstr <- mkFullGraphF bdy
  putEnv emptyEnv
  let nonfuse = S.map (,l) (getAllLabelsEnv env) <> S.fromList [(l,cl), (cl,bl)]
  return $ FGRes mempty{graphI = Graph (S.fromList [l, cl, bl]) mempty nonfuse}
                 (M.insert cl cinfo $ M.insert bl binfo $ cinfoM <> binfoM)
                 (S.singleton l)
                 (M.insert l (CWhl env u cl bl startvars) $ cConstr <> bConstr)


-- | Like mkFullGraph, but for @PreOpenAfun@.
mkFullGraphF :: MakesILP op
             => PreOpenAfun op env a
             -> State (FullGraphState env) (FullGraphResult op)
mkFullGraphF (Abody acc) = mkFullGraph acc
mkFullGraphF (Alam lhs f) = do
  e <- gets freshE
  env <- gets lenv
  let (e', env') = addLhsLabels lhs e mempty env
  putE e'
  stt <- get
  let (res, stt') = runState (mkFullGraphF f) stt{lenv=env'}
  put stt'{lenv = weakLhsEnv lhs $ lenv stt'}
  return res


-- | Information to construct AST nodes. Generally, constructors contain
-- both actual information, and a LabelEnv of the original environment
-- which helps to re-index into the new environment later.
data Construction (op :: Type -> Type) where
  CExe :: LabelEnv env -> Args env args -> op args                                  -> Construction op
  CUse ::                 ScalarType e -> Buffer e                                  -> Construction op
  CITE :: LabelEnv env -> ExpVar env PrimBool -> Label -> Label                     -> Construction op
  CWhl :: LabelEnv env -> Uniquenesses a      -> Label -> Label -> GroundVars env a -> Construction op

constructExe :: LabelEnv env' -> LabelEnv env 
             -> Args env args -> op args 
             -> Maybe (PreOpenAcc op env' ())
constructExe env' env args op = Exec op <$> reindexArgs (mkReindexPartial env env') args
constructUse :: ScalarType e -> Buffer e 
             -> PreOpenAcc op env (Buffer e)
constructUse = Use
constructITE :: LabelEnv env' -> LabelEnv env 
             -> ExpVar env PrimBool -> PreOpenAcc op env' a -> PreOpenAcc op env' a 
             -> Maybe (PreOpenAcc op env' a)
constructITE env' env cond tbranch fbranch = Acond <$> reindexVar (mkReindexPartial env env') cond 
                                                     <*> pure tbranch 
                                                     <*> pure fbranch
constructWhl :: LabelEnv env' -> LabelEnv env 
             -> Uniquenesses a -> PreOpenAfun op env' (a -> PrimBool) -> PreOpenAfun op env' (a -> a) -> GroundVars env a 
             -> Maybe (PreOpenAcc op env' a)
constructWhl env' env u cond body start = Awhile u cond body <$> reindexVars (mkReindexPartial env env') start



-- | Makes a ReindexPartial, which allows us to transform indices in @env@ into indices in @env'@.
-- We cannot guarantee the index is present in env', so we use the partiality of ReindexPartial by
-- returning a Maybe. Uses unsafeCoerce to re-introduce type information implied by the ELabels.
mkReindexPartial :: LabelEnv env -> LabelEnv env' -> ReindexPartial Maybe env env'
mkReindexPartial env env' idx = go env'  
  where
    -- The ELabel in the original environment
    e = getELabelIdx idx env
    go :: forall e a. LabelEnv e -> Maybe (Idx e a)
    go ((e',_) :>>>: rest) -- e' is the ELabel in the new environment
      -- Here we have to convince GHC that the top element in the environment 
      -- really does have the same type as the one we were searching for.
      -- Some literature does this stuff too: 'effect handlers in haskell, evidently'
      -- and 'a monadic framework for delimited continuations' come to mind.
      -- Basically: standard procedure if you're using Ints as a unique identifier
      -- and want to re-introduce type information. :)
      -- Type applications allow us to restrict unsafeCoerce to the return type.
      | e == e' = Just $ unsafeCoerce @(Idx e _) 
                                      @(Idx e a) 
                                      ZeroIdx
      -- Recurse if we did not find e' yet.
      | otherwise = SuccIdx <$> go rest
    -- If we hit the end, the Elabel was not present in the environment.
    -- That probably means we'll error out at a later point, but maybe there is
    -- a case where we try multiple options? No need to worry about it here.
    go LabelEnvNil = Nothing
