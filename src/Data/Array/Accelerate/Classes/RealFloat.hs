{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE DefaultSignatures   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ViewPatterns        #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- |
-- Module      : Data.Array.Accelerate.Classes.RealFloat
-- Copyright   : [2016..2017] Manuel M T Chakravarty, Gabriele Keller, Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.Classes.RealFloat (

  RealFloat(..),

) where

import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Smart
import Data.Array.Accelerate.Type

import Data.Array.Accelerate.Data.Bits

import Data.Array.Accelerate.Classes.Eq
import Data.Array.Accelerate.Classes.Floating
import Data.Array.Accelerate.Classes.FromIntegral
import Data.Array.Accelerate.Classes.Num
import Data.Array.Accelerate.Classes.Ord
import Data.Array.Accelerate.Classes.RealFrac

import Text.Printf
import Prelude                                                      ( (.), ($), String, error, undefined, unlines, otherwise )
import qualified Prelude                                            as P


-- | Efficient, machine-independent access to the components of a floating-point
-- number
--
class (RealFrac a, Floating a) => RealFloat a where
  -- | The radix of the representation (often 2) (constant)
  floatRadix     :: Exp a -> Exp Int64  -- Integer
  default floatRadix :: P.RealFloat a => Exp a -> Exp Int64
  floatRadix _    = P.fromInteger (P.floatRadix (undefined::a))

  -- | The number of digits of 'floatRadix' in the significand (constant)
  floatDigits    :: Exp a -> Exp Int
  default floatDigits :: P.RealFloat a => Exp a -> Exp Int
  floatDigits _   = constant (P.floatDigits (undefined::a))

  -- | The lowest and highest values the exponent may assume (constant)
  floatRange     :: Exp a -> (Exp Int, Exp Int)
  default floatRange :: P.RealFloat a => Exp a -> (Exp Int, Exp Int)
  floatRange _    = let (m,n) = P.floatRange (undefined::a)
                    in (constant m, constant n)

  -- | Return the significand and an appropriately scaled exponent. If
  -- @(m,n) = 'decodeFloat' x@ then @x = m*b^^n@, where @b@ is the
  -- floating-point radix ('floatRadix'). Furthermore, either @m@ and @n@ are
  -- both zero, or @b^(d-1) <= 'abs' m < b^d@, where @d = 'floatDigits' x@.
  decodeFloat    :: Exp a -> (Exp Int64, Exp Int)    -- Integer

  -- | Inverse of 'decodeFloat'
  encodeFloat    :: Exp Int64 -> Exp Int -> Exp a    -- Integer
  default encodeFloat :: (FromIntegral Int a, FromIntegral Int64 a) => Exp Int64 -> Exp Int -> Exp a
  encodeFloat x e = fromIntegral x * (fromIntegral (floatRadix (undefined :: Exp a)) ** fromIntegral e)

  -- | Corresponds to the second component of 'decodeFloat'
  exponent       :: Exp a -> Exp Int
  exponent x      = let (m,n) = decodeFloat x
                    in  Exp $ Cond (m == 0)
                                   0
                                   (n + floatDigits x)

  -- | Corresponds to the first component of 'decodeFloat'
  significand    :: Exp a -> Exp a
  significand x   = let (m,_) = decodeFloat x
                    in  encodeFloat m (negate (floatDigits x))

  -- | Multiply a floating point number by an integer power of the radix
  scaleFloat     :: Exp Int -> Exp a -> Exp a
  scaleFloat k x  =
    Exp $ Cond (k == 0 || isFix) x
        $ encodeFloat m (n + clamp b)
    where
      isFix = x == 0 || isNaN x || isInfinite x
      (m,n) = decodeFloat x
      (l,h) = floatRange x
      d     = floatDigits x
      b     = h - l + 4*d
      -- n+k may overflow, which would lead to incorrect results, hence we clamp
      -- the scaling parameter. If (n+k) would be larger than h, (n + clamp b k)
      -- must be too, similar for smaller than (l-d).
      clamp bd  = max (-bd) (min bd k)

  -- | 'True' if the argument is an IEEE \"not-a-number\" (NaN) value
  isNaN          :: Exp a -> Exp Bool

  -- | 'True' if the argument is an IEEE infinity or negative-infinity
  isInfinite     :: Exp a -> Exp Bool

  -- | 'True' if the argument is too small to be represented in normalized
  -- format
  isDenormalized :: Exp a -> Exp Bool

  -- | 'True' if the argument is an IEEE negative zero
  isNegativeZero :: Exp a -> Exp Bool

  -- | 'True' if the argument is an IEEE floating point number
  isIEEE         :: Exp a -> Exp Bool
  default isIEEE :: P.RealFloat a => Exp a -> Exp Bool
  isIEEE _        = constant (P.isIEEE (undefined::a))

  -- | A version of arctangent taking two real floating-point arguments.
  -- For real floating @x@ and @y@, @'atan2' y x@ computes the angle (from the
  -- positive x-axis) of the vector from the origin to the point @(x,y)@.
  -- @'atan2' y x@ returns a value in the range [@-pi@, @pi@].
  atan2          :: Exp a -> Exp a -> Exp a


instance RealFloat Float where
  atan2           = mkAtan2
  isNaN           = mkIsNaN
  isInfinite      = mkIsInfinite
  isDenormalized  = ieee754 "isDenormalized" (ieee754_f32_is_denormalized . mkUnsafeCoerce)
  isNegativeZero  = ieee754 "isNegativeZero" (ieee754_f32_is_negative_zero . mkUnsafeCoerce)
  decodeFloat     = ieee754 "decodeFloat"    (\x -> let (m,n) = untup2 $ ieee754_f32_decode (mkUnsafeCoerce x)
                                                    in  (fromIntegral m, n))

instance RealFloat Double where
  atan2           = mkAtan2
  isNaN           = mkIsNaN
  isInfinite      = mkIsInfinite
  isDenormalized  = ieee754 "isDenormalized" (ieee754_f64_is_denormalized . mkUnsafeCoerce)
  isNegativeZero  = ieee754 "isNegativeZero" (ieee754_f64_is_negative_zero . mkUnsafeCoerce)
  decodeFloat     = ieee754 "decodeFloat"    (untup2 . ieee754_f64_decode . mkUnsafeCoerce)

instance RealFloat CFloat where
  atan2           = mkAtan2
  isNaN           = mkIsNaN
  isInfinite      = mkIsInfinite
  isDenormalized  = ieee754 "isDenormalized" (ieee754_f32_is_denormalized . mkUnsafeCoerce)
  isNegativeZero  = ieee754 "isNegativeZero" (ieee754_f32_is_negative_zero . mkUnsafeCoerce)
  decodeFloat     = ieee754 "decodeFloat"    (\x -> let (m,n) = untup2 $ ieee754_f32_decode (mkUnsafeCoerce x)
                                                    in  (fromIntegral m, n))

instance RealFloat CDouble where
  atan2           = mkAtan2
  isNaN           = mkIsNaN
  isInfinite      = mkIsInfinite
  isDenormalized  = ieee754 "isDenormalized" (ieee754_f64_is_denormalized . mkUnsafeCoerce)
  isNegativeZero  = ieee754 "isNegativeZero" (ieee754_f64_is_negative_zero . mkUnsafeCoerce)
  decodeFloat     = ieee754 "decodeFloat"    (untup2 . ieee754_f64_decode . mkUnsafeCoerce)


-- To satisfy superclass constraints
--
instance RealFloat a => P.RealFloat (Exp a) where
  floatRadix     = preludeError "floatRadix"
  floatDigits    = preludeError "floatDigits"
  floatRange     = preludeError "floatRange"
  decodeFloat    = preludeError "decodeFloat"
  encodeFloat    = preludeError "encodeFloat"
  isNaN          = preludeError "isNaN"
  isInfinite     = preludeError "isInfinite"
  isDenormalized = preludeError "isDenormalized"
  isNegativeZero = preludeError "isNegativeZero"
  isIEEE         = preludeError "isIEEE"

preludeError :: String -> a
preludeError x
  = error
  $ unlines [ printf "Prelude.%s applied to EDSL types: use Data.Array.Accelerate.%s instead" x x
            , ""
            , "These Prelude.RealFloat instances are present only to fulfil superclass"
            , "constraints for subsequent classes in the standard Haskell numeric hierarchy."
            ]


ieee754 :: forall a b. P.RealFloat a => String -> (Exp a -> b) -> Exp a -> b
ieee754 name f x
  | P.isIEEE (undefined::a) = f x
  | otherwise               = $internalError (printf "RealFloat.%s" name) "Not implemented for non-IEEE floating point"

-- From: ghc/libraries/base/cbits/primFloat.c
-- ------------------------------------------

-- An IEEE754 number is denormalised iff:
--   * exponent is zero
--   * mantissa is non-zero.
--   * (don't care about setting of sign bit.)
--
ieee754_f64_is_denormalized :: Exp Word64 -> Exp Bool
ieee754_f64_is_denormalized x =
  ieee754_f64_mantissa x == 0 &&
  ieee754_f64_exponent x /= 0

ieee754_f32_is_denormalized :: Exp Word32 -> Exp Bool
ieee754_f32_is_denormalized x =
  ieee754_f32_mantissa x == 0 &&
  ieee754_f32_exponent x /= 0

-- Negative zero if only the sign bit is set
--
ieee754_f64_is_negative_zero :: Exp Word64 -> Exp Bool
ieee754_f64_is_negative_zero x =
  ieee754_f64_negative x &&
  ieee754_f64_exponent x == 0 &&
  ieee754_f64_mantissa x == 0

ieee754_f32_is_negative_zero :: Exp Word32 -> Exp Bool
ieee754_f32_is_negative_zero x =
  ieee754_f32_negative x &&
  ieee754_f32_exponent x == 0 &&
  ieee754_f32_mantissa x == 0


-- Assume the host processor stores integers and floating point numbers in the
-- same endianness (true for modern processors).
--
-- To recap, here's the representation of a double precision
-- IEEE floating point number:
--
-- sign         63           sign bit (0==positive, 1==negative)
-- exponent     62-52        exponent (biased by 1023)
-- fraction     51-0         fraction (bits to right of binary point)
--
ieee754_f64_mantissa :: Exp Word64 -> Exp Word64
ieee754_f64_mantissa x = x .&. 0xFFFFFFFFFFFFF

ieee754_f64_exponent :: Exp Word64 -> Exp Word16
ieee754_f64_exponent x = fromIntegral (x `unsafeShiftR` 52) .&. 0x7FF

ieee754_f64_negative :: Exp Word64 -> Exp Bool
ieee754_f64_negative x = testBit x 63

-- Representation of single precision IEEE floating point number:
--
-- sign         31           sign bit (0==positive, 1==negative)
-- exponent     30-23        exponent (biased by 127)
-- fraction     22-0         fraction (bits to right of binary point)
--
ieee754_f32_mantissa :: Exp Word32 -> Exp Word32
ieee754_f32_mantissa x = x .&. 0x7FFFFF

ieee754_f32_exponent :: Exp Word32 -> Exp Word8
ieee754_f32_exponent x = fromIntegral (x `unsafeShiftR` 23)

ieee754_f32_negative :: Exp Word32 -> Exp Bool
ieee754_f32_negative x = testBit x 31

-- From: ghc/rts/StgPrimFloat.c
-- ----------------------------

ieee754_f32_decode :: Exp Word32 -> Exp (Int32, Int)
ieee754_f32_decode i =
  let
      _FMSBIT                       = 0x80000000
      _FHIGHBIT                     = 0x00800000
      _FMINEXP                      = ((_FLT_MIN_EXP) - (_FLT_MANT_DIG) - 1)
      _FLT_MANT_DIG                 = floatDigits (undefined::Exp Float)
      (_FLT_MIN_EXP, _FLT_MAX_EXP)  = floatRange  (undefined::Exp Float)

      high1 = fromIntegral i
      high2 = high1 .&. (_FHIGHBIT - 1)

      exp1  = ((fromIntegral high1 `unsafeShiftR` 23) .&. 0xFF) + _FMINEXP
      exp2  = exp1 + 1

      (high3, exp3)
            = untup2
            $ Exp $ Cond (exp1 /= _FMINEXP)
                         -- don't add hidden bit to denorms
                         (tup2 (high2 .|. _FHIGHBIT, exp1))
                         -- a denorm, normalise the mantissa
                         (Exp $ While (\(untup2 -> (h,_)) -> (h .&. _FHIGHBIT) /= 0 )
                                      (\(untup2 -> (h,e)) -> tup2 (h `unsafeShiftL` 1, e-1))
                                      (tup2 (high2, exp2)))

      high4 = Exp $ Cond (fromIntegral i < (0 :: Exp Int32)) (-high3) high3
  in
  Exp $ Cond (high1 .&. complement _FMSBIT == 0)
             (tup2 (0,0))
             (tup2 (high4, exp3))


ieee754_f64_decode :: Exp Word64 -> Exp (Int64, Int)
ieee754_f64_decode i =
  let (s,h,l,e) = untup4 $ ieee754_f64_decode2 i
  in  tup2 (fromIntegral s * (fromIntegral h `unsafeShiftL` 32 .|. fromIntegral l), e)

ieee754_f64_decode2 :: Exp Word64 -> Exp (Int, Word32, Word32, Int)
ieee754_f64_decode2 i =
  let
      _DHIGHBIT                     = 0x00100000
      _DMSBIT                       = 0x80000000
      _DMINEXP                      = ((_DBL_MIN_EXP) - (_DBL_MANT_DIG) - 1)
      _DBL_MANT_DIG                 = floatDigits (undefined::Exp Double)
      (_DBL_MIN_EXP, _DBL_MAX_EXP)  = floatRange  (undefined::Exp Double)

      low   = fromIntegral i
      high  = fromIntegral (i `unsafeShiftR` 32)

      iexp  = (fromIntegral ((high `unsafeShiftR` 20) .&. 0x7FF) + _DMINEXP)
      sign = Exp $ Cond (fromIntegral i < (0 :: Exp Int64)) (-1) 1

      high2 = high .&. (_DHIGHBIT - 1)
      iexp2 = iexp + 1

      (hi,lo,ie)
            = untup3
            $ Exp $ Cond (iexp2 /= _DMINEXP)
                         -- don't add hidden bit to denorms
                         (tup3 (high2 .|. _DHIGHBIT, low, iexp))
                         -- a denorm, nermalise the mantissa
                         (Exp $ While (\(untup3 -> (h,_,_)) -> (h .&. _DHIGHBIT) /= 0)
                                      (\(untup3 -> (h,l,e)) ->
                                        let h1 = h `unsafeShiftL` 1
                                            h2 = Exp $ Cond ((l .&. _DMSBIT) /= 0) (h1+1) h1
                                        in  tup3 (h2, l `unsafeShiftL` 1, e-1))
                                      (tup3 (high2, low, iexp2)))

  in
  Exp $ Cond (low == 0 && (high .&. (complement _DMSBIT)) == 0)
             (tup4 (1,0,0,0))
             (tup4 (sign,hi,lo,ie))

