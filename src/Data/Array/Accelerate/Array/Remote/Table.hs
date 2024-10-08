{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UnboxedTuples              #-}
{-# LANGUAGE ViewPatterns               #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Module      : Data.Array.Accelerate.Array.Remote.Table
-- Copyright   : [2008..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Accelerate backends often need to copy arrays to a remote memory before they
-- can be used in computation. This module provides an automated method for
-- doing so. Keeping track of arrays in a `MemoryTable` ensures that any memory
-- allocated for them will be freed when GHC's garbage collector collects the
-- host array.
--
module Data.Array.Accelerate.Array.Remote.Table (

  -- Tables for host/device memory associations
  MemoryTable, new, lookup, malloc, free, freeStable, insertUnmanaged, reclaim,

  -- Internals
  StableBuffer, makeStableBuffer,
  makeWeakArrayData,
  formatStableBuffer,

) where

import Control.Concurrent                                           ( yield )
import Control.Concurrent.MVar                                      ( MVar, newMVar, withMVar, mkWeakMVar )
import Control.Concurrent.Unique                                    ( Unique )
import Control.Monad.IO.Class                                       ( MonadIO, liftIO )
import Data.Functor
import Data.Hashable                                                ( hash, Hashable )
import Data.Maybe                                                   ( isJust )
import Data.Text.Lazy.Builder                                       ( Builder )
import Data.Word
import Foreign.Storable                                             ( sizeOf )
import Formatting
import Prelude                                                      hiding ( lookup, id )
import System.Mem                                                   ( performGC )
import System.Mem.Weak                                              ( Weak, deRefWeak )
import qualified Data.HashTable.IO                                  as HT

import Data.Array.Accelerate.Error                              ( internalError )
import Data.Array.Accelerate.Type
import Data.Array.Accelerate.Array.Unique                       ( UniqueArray(..) )
import Data.Array.Accelerate.Array.Buffer
-- import Data.Array.Accelerate.Array.Data
import Data.Array.Accelerate.Array.Remote.Class
import Data.Array.Accelerate.Array.Remote.Nursery                   ( Nursery(..) )
import Data.Array.Accelerate.Lifetime
import qualified Data.Array.Accelerate.Array.Remote.Nursery         as N
import qualified Data.Array.Accelerate.Debug.Internal.Flags         as Debug
import qualified Data.Array.Accelerate.Debug.Internal.Profile       as Debug
import qualified Data.Array.Accelerate.Debug.Internal.Trace         as Debug

import GHC.Stack


-- We use an MVar to the hash table, so that several threads may safely access
-- it concurrently. This includes the finalisation threads that remove entries
-- from the table.
--
-- It is important that we can garbage collect old entries from the table when
-- the key is no longer reachable in the heap. Hence the value part of each
-- table entry is a (Weak val), where the stable name 'key' is the key for the
-- memo table, and the 'val' is the value of this table entry. When the key
-- becomes unreachable, a finaliser will fire and remove this entry from the
-- hash buckets, and further attempts to dereference the weak pointer will
-- return Nothing. References from 'val' to the key are ignored (see the
-- semantics of weak pointers in the documentation).
--
type HashTable key val  = HT.CuckooHashTable key val
type MT p               = MVar ( HashTable StableBuffer (RemoteArray p) )
data MemoryTable p      = MemoryTable {-# UNPACK #-} !(MT p)
                                      {-# UNPACK #-} !(Weak (MT p))
                                      {-# UNPACK #-} !(Nursery p)
                                      (p Word8 -> IO ())

data RemoteArray p where
  RemoteArray :: !(p Word8)                 -- The actual remote pointer
              -> {-# UNPACK #-} !Int        -- The array size in bytes
              -> {-# UNPACK #-} !(Weak ())  -- Keep track of host array liveness
              -> RemoteArray p

-- | An untyped reference to a buffer, similar to a StableName.
--
newtype StableBuffer = StableBuffer Unique
  deriving (Eq, Hashable)

instance Show StableBuffer where
  show (StableBuffer u) = show (hash u)

formatStableBuffer :: Format r (StableBuffer -> r)
formatStableBuffer = later $ \case
  StableBuffer u -> bformat int (hash u)

-- | Create a new memory table from host to remote arrays.
--
-- The function supplied should be the `free` for the remote pointers being
-- stored. This function will be called by the GC, which typically runs on a
-- different thread. Unlike the `free` in `RemoteMemory`, this function cannot
-- depend on any state.
--
new :: (forall a. ptr a -> IO ()) -> IO (MemoryTable ptr)
new release = do
  message "initialise memory table"
  tbl  <- HT.new
  ref  <- newMVar tbl
  nrs  <- N.new release
  weak <- mkWeakMVar ref (return ())
  return $! MemoryTable ref weak nrs release


-- | Look for the remote pointer corresponding to a given host-side array.
--
lookup :: forall m a. (HasCallStack, RemoteMemory m)
       => MemoryTable (RemotePtr m)
       -> SingleType a
       -> MutableBuffer a
       -> IO (Maybe (RemotePtr m (ScalarArrayDataR a)))
lookup (MemoryTable !ref _ _ _) !tp !arr
  | SingleArrayDict <- singleArrayDict tp = do
    sa <- makeStableBuffer tp arr
    mw <- withMVar ref (`HT.lookup` sa)
    case mw of
      Nothing                  -> trace (bformat ("lookup/not found: " % formatStableBuffer) sa) $ return Nothing
      Just (RemoteArray p _ w) -> do
        mv <- deRefWeak w
        case mv of
          Just{} -> trace (bformat ("lookup/found: " % formatStableBuffer) sa) $ return (Just $ castRemotePtr @m p)

          -- Note: [Weak pointer weirdness]
          --
          -- After the lookup is successful, there might conceivably be no further
          -- references to 'arr'. If that is so, and a garbage collection
          -- intervenes, the weak pointer might get tombstoned before 'deRefWeak'
          -- gets to it. In that case we throw an error (below). However, because
          -- we have used 'arr' in the continuation, this ensures that 'arr' is
          -- reachable in the continuation of 'deRefWeak' and thus 'deRefWeak'
          -- always succeeds. This sort of weirdness, typical of the world of weak
          -- pointers, is why we can not reuse the stable name 'sa' computed
          -- above in the error message.
          --
          Nothing ->
            makeStableBuffer tp arr >>= \x -> internalError ("dead weak pair: " % formatStableBuffer) x

-- | Allocate a new device array to be associated with the given host-side array.
-- This may not always use the `malloc` provided by the `RemoteMemory` instance.
-- In order to reduce the number of raw allocations, previously allocated remote
-- arrays will be re-used. In the event that the remote memory is exhausted,
-- 'Nothing' is returned.
--
malloc :: forall a m. (HasCallStack, RemoteMemory m, MonadIO m)
       => MemoryTable (RemotePtr m)
       -> SingleType a
       -> MutableBuffer a
       -> Int
       -> m (Maybe (RemotePtr m (ScalarArrayDataR a)))
malloc mt@(MemoryTable _ _ !nursery _) !tp !ad !n
  | SingleArrayDict <- singleArrayDict tp
  , SingleDict      <- singleDict tp
  = do
    -- Note: [Allocation sizes]
    --
    -- Instead of allocating the exact number of elements requested, we round up to
    -- a fixed chunk size as specified by RemoteMemory.remoteAllocationSize. This
    -- means there is a greater chance the nursery will get a hit, and moreover
    -- that we can search the nursery for an exact size.
    --
    chunk <- remoteAllocationSize
    let -- next highest multiple of f from x
        multiple x f  = (x + (f-1)) `quot` f
        bs            = chunk * multiple (n * sizeOf (undefined::(ScalarArrayDataR a))) chunk
    --
    message ("malloc " % int % " bytes (" % int % " x " % int % " bytes, type=" % formatSingleType % ", pagesize=" % int % ")") bs n (sizeOf (undefined :: (ScalarArrayDataR a))) tp chunk
    --
    mp <-
      fmap (castRemotePtr @m)
      <$> attempt "malloc/nursery" (liftIO $ N.lookup bs nursery)
          `orElse`
          attempt "malloc/new" (mallocRemote bs)
          `orElse` do message "malloc/remote-malloc-failed (cleaning)"
                      clean mt
                      liftIO $ N.lookup bs nursery
          `orElse` do message "malloc/remote-malloc-failed (purging)"
                      purge mt
                      mallocRemote bs
          `orElse` do message "malloc/remote-malloc-failed (non-recoverable)"
                      return Nothing
    case mp of
      Nothing -> return Nothing
      Just p' -> do
        insert mt tp ad p' bs
        return mp
  where
    {-# INLINE orElse #-}
    orElse :: m (Maybe x) -> m (Maybe x) -> m (Maybe x)
    orElse this next = do
      result <- this
      case result of
        Just{}  -> return result
        Nothing -> next

    {-# INLINE attempt #-}
    attempt :: Builder -> m (Maybe x) -> m (Maybe x)
    attempt msg this = do
      result <- this
      case result of
        Just{}  -> trace msg (return result)
        Nothing -> return Nothing



-- | Deallocate the device array associated with the given host-side array.
-- Typically this should only be called in very specific circumstances.
--
free :: forall m a. (RemoteMemory m)
     => MemoryTable (RemotePtr m)
     -> SingleType a
     -> MutableBuffer a
     -> IO ()
free mt tp !arr = do
  sa <- makeStableBuffer tp arr
  freeStable @m mt sa


-- | Deallocate the device array associated with the given StableBuffer. This
-- is useful for other memory managers built on top of the memory table.
--
freeStable
    :: forall m. RemoteMemory m
    => MemoryTable (RemotePtr m)
    -> StableBuffer
    -> IO ()
freeStable (MemoryTable !ref _ !nrs _) !sa =
  withMVar ref      $ \mt ->
  HT.mutateIO mt sa $ \mw -> do
    case mw of
      Nothing ->
        message ("free/already-removed: " % formatStableBuffer) sa

      Just (RemoteArray !p !n _) -> do
        message ("free/nursery: " % formatStableBuffer % " of " % bytes') sa n
        N.insert n (castRemotePtr @m p) nrs
        -- Debug.remote_memory_free (unsafeRemotePtrToPtr @m p)

    return (Nothing, ())


-- | Record an association between a host-side array and a new device memory
-- area. The device memory will be freed when the host array is garbage
-- collected.
--
insert
    :: forall m a. (RemoteMemory m, MonadIO m)
    => MemoryTable (RemotePtr m)
    -> SingleType a
    -> MutableBuffer a
    -> RemotePtr m (ScalarArrayDataR a)
    -> Int
    -> m ()
insert mt@(MemoryTable !ref _ _ _) !tp !arr !ptr !byteSize | SingleArrayDict <- singleArrayDict tp = do
  key  <- makeStableBuffer tp arr
  weak <- liftIO $ makeWeakArrayData tp arr () (Just $ freeStable @m mt key)
  message ("insert: " % formatStableBuffer) key
  -- liftIO  $ Debug.remote_memory_alloc (unsafeRemotePtrToPtr @m ptr) n
  liftIO  $ withMVar ref $ \tbl -> HT.insert tbl key (RemoteArray (castRemotePtr @m ptr) byteSize weak)


-- | Record an association between a host-side array and a remote memory area
-- that was not allocated by accelerate. The remote memory will NOT be re-used
-- once the host-side array is garbage collected.
--
-- This typically only has use for backends that provide an FFI.
--
insertUnmanaged
    :: forall m a. (MonadIO m, RemoteMemory m)
    => MemoryTable (RemotePtr m)
    -> SingleType a
    -> MutableBuffer a
    -> RemotePtr m (ScalarArrayDataR a)
    -> m ()
insertUnmanaged (MemoryTable !ref !weak_ref _ _) tp !arr !ptr | SingleArrayDict  <- singleArrayDict tp = do
  key  <- makeStableBuffer tp arr
  weak <- liftIO $ makeWeakArrayData tp arr () (Just $ remoteFinalizer weak_ref key)
  message ("insertUnmanaged: " % formatStableBuffer) key
  liftIO  $ withMVar ref $ \tbl -> HT.insert tbl key (RemoteArray (castRemotePtr @m ptr) 0 weak)


-- Removing entries
-- ----------------

-- | Initiate garbage collection and mark any arrays that no longer have
-- host-side equivalents as reusable.
--
clean :: forall m. (RemoteMemory m, MonadIO m) => MemoryTable (RemotePtr m) -> m ()
clean mt@(MemoryTable _ weak_ref nrs _) = management "clean" nrs . liftIO $ do
  -- Unfortunately there is no real way to force a GC then wait for it to
  -- finish. Calling performGC then yielding works moderately well in
  -- single-threaded cases, but tends to fall down otherwise. Either way, given
  -- that finalizers are often significantly delayed, it is worth our while
  -- traversing the table and explicitly freeing any dead entires.
  --
  Debug.emit_remote_gc
  performGC
  yield
  mr <- deRefWeak weak_ref
  case mr of
    Nothing  -> return ()
    Just ref -> do
      rs <- withMVar ref $ HT.foldM removable []  -- collect arrays that can be removed
      mapM_ (freeStable @m mt) rs -- remove them all
  where
    removable rs (sa, RemoteArray _ _ w) = do
      alive <- isJust <$> deRefWeak w
      if alive
        then return rs
        else return (sa:rs)


-- | Call `free` on all arrays that are not currently associated with host-side
-- arrays.
--
purge :: (RemoteMemory m, MonadIO m) => MemoryTable (RemotePtr m) -> m ()
purge (MemoryTable _ _ nursery@(Nursery nrs _) release)
  = management "purge" nursery
  $ liftIO (N.cleanup release nrs)


-- | Initiate garbage collection and `free` any remote arrays that no longer
-- have matching host-side equivalents.
--
reclaim :: forall m. (RemoteMemory m, MonadIO m) => MemoryTable (RemotePtr m) -> m ()
reclaim mt = clean mt >> purge mt

remoteFinalizer :: Weak (MT p) -> StableBuffer -> IO ()
remoteFinalizer !weak_ref !key = do
  mr <- deRefWeak weak_ref
  case mr of
    Nothing  -> message        ("finalise/dead table: " % formatStableBuffer) key
    Just ref -> trace (bformat ("finalise: "            % formatStableBuffer) key) $ withMVar ref (`HT.delete` key)


-- Miscellaneous
-- -------------

-- | Make a new 'StableBuffer'.
--
{-# INLINE makeStableBuffer #-}
makeStableBuffer
    :: MonadIO m
    => SingleType a
    -> MutableBuffer a
    -> m StableBuffer
makeStableBuffer !tp !(MutableBuffer _ ad)
  | SingleArrayDict <- singleArrayDict tp
  = return $! StableBuffer (uniqueArrayId ad)


-- Weak arrays
-- -----------

-- | Make a weak pointer using an array as a key. Unlike the standard `mkWeak`,
-- this guarantees finalisers won't fire early.
--
makeWeakArrayData
    :: forall e c.
       SingleType e
    -> MutableBuffer e
    -> c
    -> Maybe (IO ())
    -> IO (Weak c)
makeWeakArrayData !tp !(MutableBuffer _ ad) !c !mf | SingleArrayDict <- singleArrayDict tp = do
  let !uad = uniqueArrayData ad
  case mf of
    Nothing -> return ()
    Just f  -> addFinalizer uad f
  mkWeak uad c


-- Debug
-- -----

{-# INLINE bytes' #-}
bytes' :: Integral n => Format r (n -> r)
bytes' = bytes (fixed @Double 2 % " ")

{-# INLINE trace #-}
trace :: MonadIO m => Builder -> m a -> m a
trace msg next = message builder msg >> next

{-# INLINE message #-}
message :: MonadIO m => Format (m ()) a -> a
message fmt = Debug.traceM Debug.dump_gc ("gc: " % fmt)

{-# INLINE management #-}
management :: (RemoteMemory m, MonadIO m) => Builder -> Nursery p -> m a -> m a
management msg nrs next = do
  yes <- liftIO $ Debug.getFlag Debug.dump_gc
  if yes
    then do
      total       <- totalRemoteMem
      before      <- availableRemoteMem
      before_nrs  <- liftIO $ N.size nrs
      r           <- next
      after       <- availableRemoteMem
      after_nrs   <- liftIO $ N.size nrs
      message (builder % parenthesised ("freed: " % bytes' % ", stashed: " % bytes' % ", remaining: " % bytes' % " of " % bytes')) msg (before - after) (after_nrs - before_nrs) after total
      --
      return r
    else
      next

