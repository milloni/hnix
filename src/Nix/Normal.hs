{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Code for normalization (reduction into a normal form) of Nix expressions.
-- Nix language allows recursion, so some expressions do not converge.
-- And so do not converge into a normal form.
module Nix.Normal where

import           Control.Monad
import           Control.Monad.Free
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State
import           Data.Set
import           Nix.Cited
import           Nix.Frames
import           Nix.String
import           Nix.Thunk
import           Nix.Value
import           Nix.Utils
import Data.Bool (bool)

newtype NormalLoop t f m = NormalLoop (NValue t f m)
    deriving Show

instance MonadDataErrorContext t f m => Exception (NormalLoop t f m)

-- | Normalize the value as much as possible, leaving only detected cycles.
normalizeValue
  :: forall e t m f
   . ( Framed e m
     , MonadThunk t m (NValue t f m)
     , MonadDataErrorContext t f m
     , Ord (ThunkId m)
     )
  => NValue t f m
  -> m (NValue t f m)
-- normalizeValue tnk = undefined
normalizeValue tnk = run $ iterNValueM run go (fmap Free . sequenceNValue' run) tnk
 where
  start = 0 :: Int
  table = mempty

  run :: ReaderT Int (StateT (Set (ThunkId m)) m) r -> m r
  run = (`evalStateT` table) . (`runReaderT` start)

  go
    :: t
    -> (  NValue t f m
       -> ReaderT Int (StateT (Set (ThunkId m)) m) (NValue t f m)
       )
    -> ReaderT Int (StateT (Set (ThunkId m)) m) (NValue t f m)
  go t k = do
    b <- seen t
    bool
      (do
        i <- ask
        when (i > 2000)
          $ error "Exceeded maximum normalization depth of 2000 levels"
        --  2021-02-22: NOTE: `normalizeValue` should be adopted to work without fliping of the force (f)
        lifted (lifted $ \f -> f =<< force t) $ local succ . k
      )
      (pure $ pure t)
      b

  seen t = do
    let tid = thunkId t
    lift $ do
      res <- gets (member tid)
      unless res $ modify (insert tid)
      pure res

normalForm
  :: ( Framed e m
     , MonadThunk t m (NValue t f m)
     , MonadDataErrorContext t f m
     , HasCitations m (NValue t f m) t
     , HasCitations1 m (NValue t f m) f
     , Ord (ThunkId m)
     )
  => NValue t f m
  -> m (NValue t f m)
normalForm t = stubCycles <$> normalizeValue t

normalForm_
  :: ( Framed e m
     , MonadThunk t m (NValue t f m)
     , MonadDataErrorContext t f m
     , Ord (ThunkId m)
     )
  => NValue t f m
  -> m ()
normalForm_ t = void (normalizeValue t)

stubCycles
  :: forall t f m
   . ( MonadDataContext f m
     , HasCitations m (NValue t f m) t
     , HasCitations1 m (NValue t f m) f
     )
  => NValue t f m
  -> NValue t f m
stubCycles = flip iterNValue Free $ \t _ ->
  Free
    $ NValue
    $ Prelude.foldr (addProvenance1 @m @(NValue t f m)) cyc
    $ reverse
    $ citations @m @(NValue t f m) t
 where
  Free (NValue cyc) = opaque

removeEffects
  :: (MonadThunk t m (NValue t f m), MonadDataContext f m)
  => NValue t f m
  -> m (NValue t f m)
removeEffects =
  iterNValueM
    id
    --  2021-02-25: NOTE: Please, unflip this up the stack
    (\ t f -> queryM f (pure opaque) t)
    (fmap Free . sequenceNValue' id)

opaque :: Applicative f => NValue t f m
opaque = nvStr $ makeNixStringWithoutContext "<expr>"

dethunk
  :: (MonadThunk t m (NValue t f m), MonadDataContext f m)
  => t
  -> m (NValue t f m)
dethunk = queryM removeEffects (pure opaque)
