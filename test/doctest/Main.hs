-- |
-- Module      : Main
-- Copyright   : [2017..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

-- module Main where

-- import Build_doctests                           ( flags, pkgs, module_sources )
-- import DatFoldable                            ( traverse_ )
-- import Test.DocTest

-- main :: IO ()
-- main = do
--   traverse_ putStrLn args
--   doctest args
--   where
--     args = flags ++ pkgs ++ module_sources

{-# language FlexibleInstances #-}
{-# language FlexibleContexts #-}
{-# language ScopedTypeVariables #-}
{-# language TemplateHaskell #-}
{-# language TypeApplications #-}
{-# language TypeOperators #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE LambdaCase #-}
module Main where

import Data.Array.Accelerate
import Data.Array.Accelerate.Interpreter
import qualified Prelude as P

dotp :: Acc (Vector Int) -> Acc (Vector Int) -> Acc (Scalar Int)
dotp a b = fold (+) 0 $ zipWith (*) (map (+1) a) (map (`div` 2) b)

twoMaps :: Acc (Vector Int)-- -> Acc (Vector Int)
twoMaps = map (+1) . map (*2) . use $ fromList (Z :. 10) [1..]

-- data Foo = Foo Int Int
--   deriving (Generic, Elt)
-- mkPattern ''Foo

-- mapGen :: Acc (Vector Foo) -> Acc (Matrix Int)
-- mapGen acc = map (match $ \(Foo_ x y) -> x * y) $ generate (I2 size size) (\(I2 i j) -> acc ! I1 (max i j))
--   where
--     I1 size = shape acc

awhile' :: Acc (Vector Int) -> Acc (Vector Int)
awhile' = awhile (\x -> unit ((x ! I1 0) == 0)) P.id

iffy :: Acc (Vector Int) -> Acc (Vector Int)
iffy acc = if (acc ! I1 0) == 0 then twoMaps else reshape (Z_ ::. 1) (unit 1)

main :: P.IO ()
main = P.seq (test @InterpretOp awhile') (P.return ())

