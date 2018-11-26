module UnliftIO.AsyncSpec (spec) where

import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck
import UnliftIO
import Data.List (nub)
import Control.Applicative
import Control.Concurrent (myThreadId, threadDelay)
import GHC.Conc.Sync (ThreadStatus(..), threadStatus)
import Control.Concurrent.STM (throwSTM)
import Control.Exception (getMaskingState, MaskingState (Unmasked))

data MyExc = MyExc
  deriving (Show, Eq, Typeable)
instance Exception MyExc

spec :: Spec
spec = do
  describe "replicateConcurrently_" $ do
    prop "works" $ \(NonNegative cnt) -> do
      ref <- newIORef (0 :: Int)
      replicateConcurrently_ cnt $ atomicModifyIORef' ref $ \i -> (i + 1, ())
      readIORef ref `shouldReturn` cnt

    it "uses a different thread per replicated action" $
      forAllShrink ((+ 1) . abs <$> arbitrary) (filter (>= 1) . shrink) $ \n -> do
        threadIdsRef <- newIORef []
        let action = myThreadId >>= \tid -> atomicModifyIORef' threadIdsRef (\acc -> (tid:acc, ()))
        replicateConcurrently_ n action
        tids <- readIORef threadIdsRef
        tids `shouldBe` (nub tids)

  describe "conc" $ do
    it "handles exceptions" $ do
      runConc (conc (pure ()) *> conc (throwIO MyExc))
        `shouldThrow` (== MyExc)

    it "has an Unmasked masking state for given subroutines" $
      uninterruptibleMask_ $
        runConc $ conc (threadDelay maxBound) <|>
          conc (getMaskingState `shouldReturn` Unmasked)

    -- NOTE: given that we don't have the ThreadId of the resulting threads
    -- there is no other way to 'throwTo' those threads
    it "allows to kill parent via timeout" $ do
      ref <- newIORef (0 :: Int)
      mres <- timeout 20 $ runConc $
        conc (pure ()) *>
        conc ((writeIORef ref 1 >> threadDelay maxBound >> writeIORef ref 2)
              `finally` writeIORef ref 3)
      mres `shouldBe` Nothing
      res <- readIORef ref
      case res of
        0 -> putStrLn "make timeout longer"
        1 -> error "it's 1"
        2 -> error "it's 2"
        3 -> pure ()
        _ -> error $ "what? " ++ show res

    it "throws right exception on empty" $
      runConc empty `shouldThrow` (== EmptyWithNoAlternative)

  describe "Conc Applicative instance" $ do
    prop "doesn't fork a new thread on a pure call" $ \i ->
      runConc (pure (i :: Int)) `shouldReturn` i

    it "evaluates all needed sub-routines " $ do
      runConc (conc (pure ()) *> conc (throwIO MyExc))
        `shouldThrow` (== MyExc)

    it "cleanup on brackets work" $ do
      var <- newTVarIO (0 :: Int)
      let worker = conc $ bracket_
            (atomically $ modifyTVar' var (+ 1))
            (atomically $ modifyTVar' var (subtract 1))
            (threadDelay 10000000 >> error "this should never happen")
          count = 10
          killer = conc $ atomically $ do
            count' <- readTVar var
            checkSTM $ count == count'
            throwSTM MyExc
          composed = foldr (*>) killer (replicate count worker)
      runConc composed `shouldThrow` (== MyExc)
      atomically (readTVar var) `shouldReturn` 0

    it "re-throws exception that happened first" $ do
      let composed = conc (throwIO MyExc) *> conc (threadDelay 1000000 >> error "foo")
      runConc composed `shouldThrow` (== MyExc)

  describe "Conc Alternative instance" $ do
    it "executes body of all alternative blocks" $ do
      var <- newEmptyMVar
      runConc $
        conc (takeMVar var) <|>
        conc (threadDelay maxBound) <|>
        conc (threadDelay 100 >> pure ())
      -- if a GC runs at the right time, it's possible that both `takeMVar` and
      -- `runConc` itself will be in a "blocked indefinitely on MVar" situation,
      -- adding line bellow to avoid that
      putMVar var ()

    it "finishes all threads that didn't finish first" $ do
      ref <- newIORef []
      runConc $
        conc (do tid <- myThreadId
                 atomicModifyIORef' ref (\acc -> (tid:acc, ()))
                 -- it is never going to finish
                 threadDelay maxBound) <|>
        conc (do tid <- myThreadId
                 -- it finishes after registering thread id
                 atomicModifyIORef' ref (\acc -> (tid:acc, ()))
                 threadDelay 500) <|>
        conc (do tid <- myThreadId
                 atomicModifyIORef' ref (\acc -> (tid:acc, ()))
                 -- it is never going to finish
                 threadDelay maxBound)
      threads <- readIORef ref
      statusList <- mapM threadStatus threads
      length (filter (== ThreadFinished) statusList) `shouldBe` 3

    it "nesting works" $ do
      var <- newEmptyMVar
      let sillyAlts :: Conc IO a -> Conc IO a
          sillyAlts c = c <|> conc (takeMVar var >> error "shouldn't happen")
      res <- runConc $ sillyAlts $ (+)
        <$> sillyAlts (conc (pure 1))
        <*> sillyAlts (conc (pure 2))
      res `shouldBe` 3
      putMVar var ()
