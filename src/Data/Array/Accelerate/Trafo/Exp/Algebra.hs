{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns        #-}
-- |
-- Module      : Data.Array.Accelerate.Trafo.Exp.Algebra
-- Copyright   : [2012..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Algebraic simplifications of scalar expressions, including constant folding
-- and using algebraic properties of particular operator-operand combinations.
--

module Data.Array.Accelerate.Trafo.Exp.Algebra (

  evalPrimApp,

) where

import Data.Array.Accelerate.AST.Exp
import Data.Array.Accelerate.AST.Var
import Data.Array.Accelerate.Analysis.Match
import Data.Array.Accelerate.Pretty.Print                           ( primOperator, isInfix, opName )
import Data.Array.Accelerate.Trafo.Environment
import Data.Array.Accelerate.Type

import qualified Data.Array.Accelerate.Debug.Internal.Stats         as Stats

import Data.Bits
import Data.Monoid
import Data.Text                                                    ( Text )
import Prettyprinter
import Prettyprinter.Render.Text
import Prelude                                                      hiding ( exp )
import qualified Prelude                                            as P

import GHC.Float                                                    ( float2Double, double2Float )


-- Propagate constant expressions, which are either constant valued expressions
-- or constant let bindings. Be careful not to follow self-cycles.
--
propagate
    :: forall arr env exp.
       IsArrayInstr arr
    => Gamma arr env env
    -> PreOpenExp arr env exp
    -> Maybe exp
propagate env = cvtE
  where
    cvtE :: PreOpenExp arr env e -> Maybe e
    cvtE exp = case exp of
      Const _ c                                 -> Just c
      PrimConst c                               -> Just (evalPrimConst c)
      Evar (Var _  ix)
        | e             <- prjExp ix env
        , Nothing       <- matchOpenExp exp e   -> cvtE e
      Nil                                       -> Just ()
      Pair e1 e2                                -> (,) <$> cvtE e1 <*> cvtE e2
      _                                         -> Nothing


-- Attempt to evaluate primitive function applications
--
evalPrimApp
    :: forall arr env a r.
       IsArrayInstr arr
    => Gamma arr env env
    -> PrimFun (a -> r)
    -> PreOpenExp arr env a
    -> (Any, PreOpenExp arr env r)
evalPrimApp env f x
  -- First attempt to move constant values towards the left
  | Just r      <- commutes f x env     = evalPrimApp env f r
--  | Just r      <- associates f x       = r

  -- Now attempt to evaluate any expressions
  | otherwise
  = maybe (Any False, PrimApp f x) (Any True,)
  $ case f of
      PrimAdd ty                -> evalAdd ty x env
      PrimSub ty                -> evalSub ty x env
      PrimMul ty                -> evalMul ty x env
      PrimNeg ty                -> evalNeg ty x env
      PrimAbs ty                -> evalAbs ty x env
      PrimSig ty                -> evalSig ty x env
      PrimQuot ty               -> evalQuot ty x env
      PrimRem ty                -> evalRem ty x env
      PrimQuotRem ty            -> evalQuotRem ty x env
      PrimIDiv ty               -> evalIDiv ty x env
      PrimMod ty                -> evalMod ty x env
      PrimDivMod ty             -> evalDivMod ty x env
      PrimBAnd ty               -> evalBAnd ty x env
      PrimBOr ty                -> evalBOr ty x env
      PrimBXor ty               -> evalBXor ty x env
      PrimBNot ty               -> evalBNot ty x env
      PrimBShiftL ty            -> evalBShiftL ty x env
      PrimBShiftR ty            -> evalBShiftR ty x env
      PrimBRotateL ty           -> evalBRotateL ty x env
      PrimBRotateR ty           -> evalBRotateR ty x env
      PrimPopCount ty           -> evalPopCount ty x env
      PrimCountLeadingZeros ty  -> evalCountLeadingZeros ty x env
      PrimCountTrailingZeros ty -> evalCountTrailingZeros ty x env
      PrimFDiv ty               -> evalFDiv ty x env
      PrimRecip ty              -> evalRecip ty x env
      PrimSin ty                -> evalSin ty x env
      PrimCos ty                -> evalCos ty x env
      PrimTan ty                -> evalTan ty x env
      PrimAsin ty               -> evalAsin ty x env
      PrimAcos ty               -> evalAcos ty x env
      PrimAtan ty               -> evalAtan ty x env
      PrimSinh ty               -> evalSinh ty x env
      PrimCosh ty               -> evalCosh ty x env
      PrimTanh ty               -> evalTanh ty x env
      PrimAsinh ty              -> evalAsinh ty x env
      PrimAcosh ty              -> evalAcosh ty x env
      PrimAtanh ty              -> evalAtanh ty x env
      PrimExpFloating ty        -> evalExpFloating ty x env
      PrimSqrt ty               -> evalSqrt ty x env
      PrimLog ty                -> evalLog ty x env
      PrimFPow ty               -> evalFPow ty x env
      PrimLogBase ty            -> evalLogBase ty x env
      PrimAtan2 ty              -> evalAtan2 ty x env
      PrimTruncate ta tb        -> evalTruncate ta tb x env
      PrimRound ta tb           -> evalRound ta tb x env
      PrimFloor ta tb           -> evalFloor ta tb x env
      PrimCeiling ta tb         -> evalCeiling ta tb x env
      PrimIsNaN ty              -> evalIsNaN ty x env
      PrimIsInfinite ty         -> evalIsInfinite ty x env
      PrimLt ty                 -> evalLt ty x env
      PrimGt ty                 -> evalGt ty x env
      PrimLtEq ty               -> evalLtEq ty x env
      PrimGtEq ty               -> evalGtEq ty x env
      PrimEq ty                 -> evalEq ty x env
      PrimNEq ty                -> evalNEq ty x env
      PrimMax ty                -> evalMax ty x env
      PrimMin ty                -> evalMin ty x env
      PrimLAnd                  -> evalLAnd x env
      PrimLOr                   -> evalLOr x env
      PrimLNot                  -> evalLNot x env
      PrimFromIntegral ta tb    -> evalFromIntegral ta tb x env
      PrimToFloating ta tb      -> evalToFloating ta tb x env


-- Discriminate binary functions that commute, and if so return the operands in
-- a stable ordering. If only one of the arguments is a constant, this is placed
-- to the left of the operator. Returning Nothing indicates no change is made.
--
commutes
    :: forall arr env a r.
       IsArrayInstr arr
    => PrimFun (a -> r)
    -> PreOpenExp arr env a
    -> Gamma arr env env
    -> Maybe (PreOpenExp arr env a)
commutes f x env = case f of
  PrimAdd _     -> swizzle x
  PrimMul _     -> swizzle x
  PrimBAnd _    -> swizzle x
  PrimBOr _     -> swizzle x
  PrimBXor _    -> swizzle x
  PrimEq _      -> swizzle x
  PrimNEq _     -> swizzle x
  PrimMax _     -> swizzle x
  PrimMin _     -> swizzle x
  _             -> Nothing
  where
    swizzle :: PreOpenExp arr env (b,b) -> Maybe (PreOpenExp arr env (b,b))
    swizzle (Pair a b)
      | Nothing         <- propagate env a
      , Just _          <- propagate env b
      = Stats.ruleFired (pprFun "commutes" f)
      $ Just $ Pair b a

--    TLM: changing the ordering here when neither term can be reduced can be
--         disadvantageous: for example in (x &&* y), the user might have put a
--         simpler condition first that is designed to fail fast.
--
--      | Nothing         <- propagate env a
--      , Nothing         <- propagate env b
--      , hashOpenExp a > hashOpenExp b
--      = Just $ Tuple (NilTup `SnocTup` b `SnocTup` a)

    swizzle _
      = Nothing


{--
-- Determine if successive applications of a binary operator will associate, and
-- if so move them to the left. That is:
--
--   a + (b + c)  -->  (a + b) + c
--
-- Returning Nothing indicates no change is made.
--
-- TLM: we might get into trouble here, as we've lost track of where the user
--      has explicitly put parenthesis.
--
-- TLM: BROKEN!! does not correctly change the sign of expressions when flipping
--      (-x+y) or (-y+x).
--
associates
    :: (Elt a, Elt r)
    => PrimFun (a -> r)
    -> PreOpenExp arr env a
    -> Maybe (PreOpenExp arr env r)
associates fun exp = case fun of
  PrimAdd _     -> swizzle fun exp [PrimAdd ty, PrimSub ty]
  PrimSub _     -> swizzle fun exp [PrimAdd ty, PrimSub ty]
  PrimLAnd      -> swizzle fun exp [fun]
  PrimLOr       -> swizzle fun exp [fun]
  _             -> swizzle fun exp [fun]
  where
    -- TODO: check the list of ops is complete (and correct)
    ty  = undefined
    ops = [ PrimMul ty, PrimFDiv ty, PrimAdd ty, PrimSub ty, PrimBAnd ty, PrimBOr ty, PrimBXor ty ]

    swizzle :: (Elt a, Elt r) => PrimFun (a -> r) -> PreOpenExp arr env a -> [PrimFun (a -> r)] -> Maybe (PreOpenExp arr env r)
    swizzle f x lvl
      | Just Refl       <- matches f ops
      , Just (a,bc)     <- untup2 x
      , PrimApp g y     <- bc
      , Just Refl       <- matches g lvl
      , Just (b,c)      <- untup2 y
      = Stats.ruleFired (pprFun "associates" f)
      $ Just $ PrimApp g (tup2 (PrimApp f (tup2 (a,b)), c))

    swizzle _ _ _
      = Nothing

    matches :: (Elt s, Elt t) => PrimFun (s -> a) -> [PrimFun (t -> a)] -> Maybe (s :=: t)
    matches _ []        = Nothing
    matches f (x:xs)
      | Just Refl       <- matchPrimFun' f x
      = Just Refl

      | otherwise
      = matches f xs
--}


-- Helper functions
-- ----------------

type a :-> b = forall arr env. IsArrayInstr arr => PreOpenExp arr env a -> Gamma arr env env -> Maybe (PreOpenExp arr env b)

eval1 :: SingleType b -> (a -> b) -> a :-> b
eval1 tp f x env
  | Just a <- propagate env x   = Stats.substitution "constant fold" . Just $ Const (SingleScalarType tp) (f a)
  | otherwise                   = Nothing

eval2 :: SingleType c -> (a -> b -> c) -> (a,b) :-> c
eval2 tp f (untup2 -> Just (x,y)) env
  | Just a <- propagate env x
  , Just b <- propagate env y
  = Stats.substitution "constant fold"
  $ Just $ Const (SingleScalarType tp) (f a b)
eval2 _ _ _ _
  = Nothing

fromBool :: Bool -> PrimBool
fromBool False = 0
fromBool True  = 1

toBool :: PrimBool -> Bool
toBool 0 = False
toBool _ = True

bool1 :: (a -> Bool) -> a :-> PrimBool
bool1 f x env
  | Just a <- propagate env x
  = Stats.substitution "constant fold"
  . Just $ Const scalarTypeWord8 (fromBool (f a))
bool1 _ _ _
  = Nothing

bool2 :: (a -> b -> Bool) -> (a,b) :-> PrimBool
bool2 f (untup2 -> Just (x,y)) env
  | Just a <- propagate env x
  , Just b <- propagate env y
  = Stats.substitution "constant fold"
  $ Just $ Const scalarTypeWord8 (fromBool (f a b))
bool2 _ _ _
  = Nothing

tup2 :: (PreOpenExp arr env a, PreOpenExp arr env b) -> PreOpenExp arr env (a, b)
tup2 (a,b) = Pair a b

untup2 :: PreOpenExp arr env (a, b) -> Maybe (PreOpenExp arr env a, PreOpenExp arr env b)
untup2 exp
  | Pair a b <- exp = Just (a, b)
  | otherwise       = Nothing

-- If the two arguments are the same, then it will evaluate to that argument
evalIfSameArguments :: (a,a) :-> a
evalIfSameArguments (untup2 -> Just (x,y)) _
  | Just Refl <- matchOpenExp x y = Just x
evalIfSameArguments _ _ = Nothing

pprFun :: Text -> PrimFun f -> Text
pprFun rule f
  = renderStrict
  . layoutCompact
  $ pretty rule <+> f'
  where
    op = primOperator f
    f' = if isInfix op
           then parens (opName op)
           else opName op


-- Methods of Num
-- --------------

evalAdd :: NumType a -> (a,a) :-> a
evalAdd ty@(IntegralNumType ty') | IntegralDict <- integralDict ty' = evalAdd' ty
evalAdd ty@(FloatingNumType ty') | FloatingDict <- floatingDict ty' = evalAdd' ty

evalAdd' :: (Eq a, Num a) => NumType a -> (a,a) :-> a
evalAdd' _  (untup2 -> Just (x,y)) env
  | Just a      <- propagate env x
  , a == 0
  = Stats.ruleFired "x+0" $ Just y

evalAdd' ty arg env
  = eval2 (NumSingleType ty) (+) arg env


evalSub :: NumType a -> (a,a) :-> a
evalSub ty@(IntegralNumType ty') | IntegralDict <- integralDict ty' = evalSub' ty
evalSub ty@(FloatingNumType ty') | FloatingDict <- floatingDict ty' = evalSub' ty

evalSub' :: forall a. (Eq a, Num a) => NumType a -> (a,a) :-> a
evalSub' ty (untup2 -> Just (x,y)) env
  | Just b      <- propagate env y
  , b == 0
  = Stats.ruleFired "x-0" $ Just x

  | Nothing     <- propagate env x
  , Just b      <- propagate env y
  = Stats.ruleFired "-y+x"
  $ Just . snd $ evalPrimApp env (PrimAdd ty) (Const tp (-b) `Pair` x)
  -- (Tuple $ NilTup `SnocTup` Const (fromElt (-b)) `SnocTup` x)

  | Just Refl   <- matchOpenExp x y
  = Stats.ruleFired "x-x"
  $ Just $ Const tp 0
  where
    tp = SingleScalarType $ NumSingleType ty

evalSub' ty arg env
  = eval2 (NumSingleType ty) (-) arg env


evalMul :: NumType a -> (a,a) :-> a
evalMul ty@(IntegralNumType ty') | IntegralDict <- integralDict ty' = evalMul' ty
evalMul ty@(FloatingNumType ty') | FloatingDict <- floatingDict ty' = evalMul' ty

evalMul' :: (Eq a, Num a) => NumType a -> (a,a) :-> a
evalMul' _  (untup2 -> Just (x,y)) env
  | Just a      <- propagate env x
  , Nothing     <- propagate env y
  = case a of
      0         -> Stats.ruleFired "x*0" $ Just x
      1         -> Stats.ruleFired "x*1" $ Just y
      _         -> Nothing

evalMul' ty arg env
  = eval2 (NumSingleType ty) (*) arg env

evalNeg :: NumType a -> a :-> a
evalNeg _                    x _   | PrimApp PrimNeg{} x' <- x       = Stats.ruleFired "negate/negate" $ Just x'
evalNeg (IntegralNumType ty) x env | IntegralDict <- integralDict ty = eval1 (NumSingleType $ IntegralNumType ty) negate x env
evalNeg (FloatingNumType ty) x env | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) negate x env

evalAbs :: NumType a -> a :-> a
evalAbs (IntegralNumType ty) | IntegralDict <- integralDict ty = eval1 (NumSingleType $ IntegralNumType ty) abs
evalAbs (FloatingNumType ty) | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) abs

evalSig :: NumType a -> a :-> a
evalSig (IntegralNumType ty) | IntegralDict <- integralDict ty = eval1 (NumSingleType $ IntegralNumType ty) signum
evalSig (FloatingNumType ty) | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) signum


-- Methods of Integral & Bits
-- --------------------------

evalQuot :: IntegralType a -> (a,a) :-> a
evalQuot ty exp env
  | Just qr    <- evalQuotRem ty exp env
  , Just (q,_) <- untup2 qr
  = Just q
evalQuot _ _ _
  = Nothing

evalRem :: IntegralType a -> (a,a) :-> a
evalRem ty exp env
  | Just qr    <- evalQuotRem ty exp env
  , Just (_,r) <- untup2 qr
  = Just r
evalRem _ _ _
  = Nothing

evalQuotRem :: forall a. IntegralType a -> (a,a) :-> (a,a)
evalQuotRem ty exp env
  | IntegralDict <- integralDict ty
  , Just (x, y)  <- untup2 exp
  , Just b       <- propagate env y
  = case b of
      0 -> Nothing
      1 -> Stats.ruleFired "quotRem x 1" $ Just (tup2 (x, Const tp 0))
      _ -> case propagate env x of
             Nothing -> Nothing
             Just a  -> Stats.substitution "constant fold"
                      $ Just $ let (u,v) = quotRem a b
                               in  tup2 (Const tp u, Const tp v)
  where
    tp = SingleScalarType $ NumSingleType $ IntegralNumType ty
evalQuotRem _ _ _
  = Nothing


evalIDiv :: IntegralType a -> (a,a) :-> a
evalIDiv ty exp env
  | Just dm    <- evalDivMod ty exp env
  , Just (d,_) <- untup2 dm
  = Just d
evalIDiv _ _ _
  = Nothing

evalMod :: IntegralType a -> (a,a) :-> a
evalMod ty exp env
  | Just dm    <- evalDivMod ty exp env
  , Just (_,m) <- untup2 dm
  = Just m
evalMod _ _ _
  = Nothing

evalDivMod :: forall a. IntegralType a -> (a,a) :-> (a,a)
evalDivMod ty exp env
  | IntegralDict <- integralDict ty
  , Just (x, y)  <- untup2 exp
  , Just b       <- propagate env y
  = case b of
      0 -> Nothing
      1 -> Stats.ruleFired "divMod x 1" $ Just (tup2 (x, Const tp 0))
      _ -> case propagate env x of
             Nothing -> Nothing
             Just a  -> Stats.substitution "constant fold"
                      $ Just $ let (u,v) = divMod a b
                               in  tup2 (Const tp u, Const tp v)
  where
    tp = SingleScalarType $ NumSingleType $ IntegralNumType ty
evalDivMod _ _ _
  = Nothing

evalBAnd :: IntegralType a -> (a,a) :-> a
evalBAnd ty | IntegralDict <- integralDict ty = eval2 (NumSingleType $ IntegralNumType ty) (.&.)

evalBOr :: IntegralType a -> (a,a) :-> a
evalBOr ty | IntegralDict <- integralDict ty = evalBOr' ty

evalBOr' :: (Eq a, Num a, Bits a) => IntegralType a -> (a,a) :-> a
evalBOr' _ (untup2 -> Just (x,y)) env
  | Just 0 <- propagate env x
  = Stats.ruleFired "x .|. 0" $ Just y

evalBOr' ty arg env
  = eval2 (NumSingleType $ IntegralNumType ty) (.|.) arg env

evalBXor :: IntegralType a -> (a,a) :-> a
evalBXor ty | IntegralDict <- integralDict ty = eval2 (NumSingleType $ IntegralNumType ty) xor

evalBNot :: IntegralType a -> a :-> a
evalBNot ty | IntegralDict <- integralDict ty = eval1 (NumSingleType $ IntegralNumType ty) complement

evalBShiftL :: IntegralType a -> (a,Int) :-> a
evalBShiftL _ (untup2 -> Just (x,i)) env
  | Just 0 <- propagate env i
  = Stats.ruleFired "x `shiftL` 0" $ Just x

evalBShiftL ty arg env
  | IntegralDict <- integralDict ty = eval2 (NumSingleType $ IntegralNumType ty) shiftL arg env

evalBShiftR :: IntegralType a -> (a,Int) :-> a
evalBShiftR _ (untup2 -> Just (x,i)) env
  | Just 0 <- propagate env i
  = Stats.ruleFired "x `shiftR` 0" $ Just x

evalBShiftR ty arg env
  | IntegralDict <- integralDict ty = eval2 (NumSingleType $ IntegralNumType ty) shiftR arg env

evalBRotateL :: IntegralType a -> (a,Int) :-> a
evalBRotateL _ (untup2 -> Just (x,i)) env
  | Just 0 <- propagate env i
  = Stats.ruleFired "x `rotateL` 0" $ Just x
evalBRotateL ty arg env
  | IntegralDict <- integralDict ty = eval2 (NumSingleType $ IntegralNumType ty) rotateL arg env

evalBRotateR :: IntegralType a -> (a,Int) :-> a
evalBRotateR _ (untup2 -> Just (x,i)) env
  | Just 0 <- propagate env i
  = Stats.ruleFired "x `rotateR` 0" $ Just x
evalBRotateR ty arg env
  | IntegralDict <- integralDict ty = eval2 (NumSingleType $ IntegralNumType ty) rotateR arg env

evalPopCount :: IntegralType a -> a :-> Int
evalPopCount ty | IntegralDict <- integralDict ty = eval1 (NumSingleType $ IntegralNumType TypeInt) popCount

evalCountLeadingZeros :: IntegralType a -> a :-> Int
evalCountLeadingZeros ty | IntegralDict <- integralDict ty = eval1 (NumSingleType $ IntegralNumType TypeInt) countLeadingZeros

evalCountTrailingZeros :: IntegralType a -> a :-> Int
evalCountTrailingZeros ty | IntegralDict <- integralDict ty = eval1 (NumSingleType $ IntegralNumType TypeInt) countTrailingZeros


-- Methods of Fractional & Floating
-- --------------------------------

evalFDiv :: FloatingType a -> (a,a) :-> a
evalFDiv ty | FloatingDict <- floatingDict ty = evalFDiv' ty

evalFDiv' :: (Fractional a, Eq a) => FloatingType a -> (a,a) :-> a
evalFDiv' _ (untup2 -> Just (x,y)) env
  | Just 1      <- propagate env y
  = Stats.ruleFired "x/1" $ Just x

evalFDiv' ty arg env
  = eval2 (NumSingleType $ FloatingNumType ty) (/) arg env


evalRecip :: FloatingType a -> a :-> a
evalRecip ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) recip

evalSin :: FloatingType a -> a :-> a
evalSin ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) sin

evalCos :: FloatingType a -> a :-> a
evalCos ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) cos

evalTan :: FloatingType a -> a :-> a
evalTan ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) tan

evalAsin :: FloatingType a -> a :-> a
evalAsin ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) asin

evalAcos :: FloatingType a -> a :-> a
evalAcos ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) acos

evalAtan :: FloatingType a -> a :-> a
evalAtan ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) atan

evalSinh :: FloatingType a -> a :-> a
evalSinh ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) sinh

evalCosh :: FloatingType a -> a :-> a
evalCosh ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) cosh

evalTanh :: FloatingType a -> a :-> a
evalTanh ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) tanh

evalAsinh :: FloatingType a -> a :-> a
evalAsinh ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) asinh

evalAcosh :: FloatingType a -> a :-> a
evalAcosh ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) acosh

evalAtanh :: FloatingType a -> a :-> a
evalAtanh ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) atanh

evalExpFloating :: FloatingType a -> a :-> a
evalExpFloating ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) P.exp

evalSqrt :: FloatingType a -> a :-> a
evalSqrt ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) sqrt

evalLog :: FloatingType a -> a :-> a
evalLog ty | FloatingDict <- floatingDict ty = eval1 (NumSingleType $ FloatingNumType ty) log

evalFPow :: FloatingType a -> (a,a) :-> a
evalFPow ty | FloatingDict <- floatingDict ty = eval2 (NumSingleType $ FloatingNumType ty) (**)

evalLogBase :: FloatingType a -> (a,a) :-> a
evalLogBase ty | FloatingDict <- floatingDict ty = eval2 (NumSingleType $ FloatingNumType ty) logBase

evalAtan2 :: FloatingType a -> (a,a) :-> a
evalAtan2 ty | FloatingDict <- floatingDict ty = eval2 (NumSingleType $ FloatingNumType ty) atan2

evalTruncate :: FloatingType a -> IntegralType b -> a :-> b
evalTruncate ta tb
  | FloatingDict <- floatingDict ta
  , IntegralDict <- integralDict tb
  = eval1 (NumSingleType $ IntegralNumType tb) truncate

evalRound :: FloatingType a -> IntegralType b -> a :-> b
evalRound ta tb
  | FloatingDict <- floatingDict ta
  , IntegralDict <- integralDict tb
  = eval1 (NumSingleType $ IntegralNumType tb) round

evalFloor :: FloatingType a -> IntegralType b -> a :-> b
evalFloor ta tb
  | FloatingDict <- floatingDict ta
  , IntegralDict <- integralDict tb
  = eval1 (NumSingleType $ IntegralNumType tb) floor

evalCeiling :: FloatingType a -> IntegralType b -> a :-> b
evalCeiling ta tb
  | FloatingDict <- floatingDict ta
  , IntegralDict <- integralDict tb
  = eval1 (NumSingleType $ IntegralNumType tb) ceiling

evalIsNaN :: FloatingType a -> a :-> PrimBool
evalIsNaN ty | FloatingDict <- floatingDict ty = bool1 isNaN

evalIsInfinite :: FloatingType a -> a :-> PrimBool
evalIsInfinite ty | FloatingDict <- floatingDict ty = bool1 isInfinite


-- Relational & Equality
-- ---------------------

evalLt :: SingleType a -> (a,a) :-> PrimBool
evalLt (NumSingleType (IntegralNumType ty)) | IntegralDict <- integralDict ty = bool2 (<)
evalLt (NumSingleType (FloatingNumType ty)) | FloatingDict <- floatingDict ty = bool2 (<)

evalGt :: SingleType a -> (a,a) :-> PrimBool
evalGt (NumSingleType (IntegralNumType ty)) | IntegralDict <- integralDict ty = bool2 (>)
evalGt (NumSingleType (FloatingNumType ty)) | FloatingDict <- floatingDict ty = bool2 (>)

evalLtEq :: SingleType a -> (a,a) :-> PrimBool
evalLtEq (NumSingleType (IntegralNumType ty)) | IntegralDict <- integralDict ty = bool2 (<=)
evalLtEq (NumSingleType (FloatingNumType ty)) | FloatingDict <- floatingDict ty = bool2 (<=)

evalGtEq :: SingleType a -> (a,a) :-> PrimBool
evalGtEq (NumSingleType (IntegralNumType ty)) | IntegralDict <- integralDict ty = bool2 (>=)
evalGtEq (NumSingleType (FloatingNumType ty)) | FloatingDict <- floatingDict ty = bool2 (>=)

evalEq :: SingleType a -> (a,a) :-> PrimBool
evalEq (NumSingleType (IntegralNumType ty)) | IntegralDict <- integralDict ty = bool2 (==)
evalEq (NumSingleType (FloatingNumType ty)) | FloatingDict <- floatingDict ty = bool2 (==)

evalNEq :: SingleType a -> (a,a) :-> PrimBool
evalNEq (NumSingleType (IntegralNumType ty)) | IntegralDict <- integralDict ty = bool2 (/=)
evalNEq (NumSingleType (FloatingNumType ty)) | FloatingDict <- floatingDict ty = bool2 (/=)

evalMax :: SingleType a -> (a,a) :-> a
evalMax ty args env
  | Just arg <- evalIfSameArguments args env
  = Stats.ruleFired "max x x" $ Just arg

  | NumSingleType (IntegralNumType ty') <- ty
  , IntegralDict <- integralDict ty'
  = eval2 ty max args env

  | NumSingleType (FloatingNumType ty') <- ty
  , FloatingDict <- floatingDict ty'
  = eval2 ty max args env

evalMin :: SingleType a -> (a,a) :-> a
evalMin ty args env
  | Just arg <- evalIfSameArguments args env
  = Stats.ruleFired "min x x" $ Just arg

  | NumSingleType (IntegralNumType ty') <- ty
  , IntegralDict <- integralDict ty'
  = eval2 ty min args env

  | NumSingleType (FloatingNumType ty') <- ty
  , FloatingDict <- floatingDict ty'
  = eval2 ty min args env

-- Logical operators
-- -----------------

evalLAnd :: (PrimBool,PrimBool) :-> PrimBool
evalLAnd (untup2 -> Just (x,y)) env
  | Just a      <- propagate env x
  = Just
  $ if toBool a then Stats.ruleFired "True &&" y
                else Stats.ruleFired "False &&" $ Const scalarTypeWord8 0

  | Just b      <- propagate env y
  = Just
  $ if toBool b then Stats.ruleFired "True &&" x
                else Stats.ruleFired "False &&" $ Const scalarTypeWord8 0

evalLAnd _ _
  = Nothing

evalLOr  :: (PrimBool,PrimBool) :-> PrimBool
evalLOr (untup2 -> Just (x,y)) env
  | Just a      <- propagate env x
  = Just
  $ if toBool a then Stats.ruleFired "True ||" $ Const scalarTypeWord8 1
                else Stats.ruleFired "False ||" y

  | Just b      <- propagate env y
  = Just
  $ if toBool b then Stats.ruleFired "True ||" $ Const scalarTypeWord8 1
                else Stats.ruleFired "False ||" x

evalLOr _ _
  = Nothing

evalLNot :: PrimBool :-> PrimBool
evalLNot x _   | PrimApp PrimLNot x' <- x = Stats.ruleFired "not/not" $ Just x'
evalLNot x env                            = bool1 (not . toBool) x env

evalFromIntegral :: IntegralType a -> NumType b -> a :-> b
evalFromIntegral ta (IntegralNumType tb)
  | IntegralDict <- integralDict ta
  , IntegralDict <- integralDict tb = eval1 (NumSingleType $ IntegralNumType tb) fromIntegral

evalFromIntegral ta (FloatingNumType tb)
  | IntegralDict <- integralDict ta
  , FloatingDict <- floatingDict tb = eval1 (NumSingleType $ FloatingNumType tb) fromIntegral

evalToFloating :: NumType a -> FloatingType b -> a :-> b
evalToFloating (IntegralNumType ta) tb x env
  | IntegralDict <- integralDict ta
  , FloatingDict <- floatingDict tb = eval1 (NumSingleType $ FloatingNumType tb) realToFrac x env

evalToFloating (FloatingNumType ta) tb x env
  | TypeHalf   <- ta
  , TypeHalf   <- tb = Just x

  | TypeFloat  <- ta
  , TypeFloat  <- tb = Just x

  | TypeDouble <- ta
  , TypeDouble <- tb = Just x

  | TypeFloat  <- ta
  , TypeDouble <- tb = eval1 (NumSingleType $ FloatingNumType tb) float2Double x env

  | TypeDouble <- ta
  , TypeFloat  <- tb = eval1 (NumSingleType $ FloatingNumType tb) double2Float x env

  | FloatingDict <- floatingDict ta
  , FloatingDict <- floatingDict tb = eval1 (NumSingleType $ FloatingNumType tb) realToFrac x env


-- Scalar primitives
-- -----------------

evalPrimConst :: PrimConst a -> a
evalPrimConst (PrimMinBound ty) = evalMinBound ty
evalPrimConst (PrimMaxBound ty) = evalMaxBound ty
evalPrimConst (PrimPi       ty) = evalPi ty

evalMinBound :: BoundedType a -> a
evalMinBound (IntegralBoundedType ty) | IntegralDict <- integralDict ty = minBound

evalMaxBound :: BoundedType a -> a
evalMaxBound (IntegralBoundedType ty) | IntegralDict <- integralDict ty = maxBound

evalPi :: FloatingType a -> a
evalPi ty | FloatingDict <- floatingDict ty = pi

