{-# LANGUAGE CPP               #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes #-}

module GHCup.OptParse.ToolRequirements where


import           GHCup.Errors
import           GHCup.Types
import           GHCup.Utils.Logger

#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           Haskus.Utils.Variant.Excepts
import           Options.Applicative     hiding ( style )
import           Prelude                 hiding ( appendFile )
import           System.Exit
import           Text.PrettyPrint.HughesPJClass ( prettyShow )

import qualified Data.Text                     as T
import qualified Data.Text.IO                  as T
import Control.Exception.Safe (MonadMask)
import GHCup.Types.Optics
import GHCup.Platform
import GHCup.Utils.Prelude
import GHCup.Requirements
import System.IO





    ---------------------------
    --[ Effect interpreters ]--
    ---------------------------


type ToolRequirementsEffects = '[ NoCompatiblePlatform , DistroNotFound , NoToolRequirements ]


runToolRequirements :: (ReaderT env m (VEither ToolRequirementsEffects a) -> m (VEither ToolRequirementsEffects a))
                    -> (Excepts ToolRequirementsEffects (ReaderT env m) a)
                    -> m (VEither ToolRequirementsEffects a)
runToolRequirements runAppState =
    runAppState
    . runE
      @ToolRequirementsEffects



    ------------------
    --[ Entrypoint ]--
    ------------------



toolRequirements :: ( Monad m
                    , MonadMask m
                    , MonadUnliftIO m
                    , MonadFail m
                    , Alternative m
                    )
                 => (ReaderT AppState m (VEither ToolRequirementsEffects ()) -> m (VEither ToolRequirementsEffects ()))
                 -> (ReaderT LeanAppState m () -> m ())
                 -> m ExitCode
toolRequirements runAppState runLogger = runToolRequirements runAppState (do
    GHCupInfo { .. } <- lift getGHCupInfo
    platform' <- liftE getPlatform
    req      <- getCommonRequirements platform' _toolRequirements ?? NoToolRequirements
    liftIO $ T.hPutStr stdout (prettyRequirements req)
  )
    >>= \case
          VRight _ -> pure ExitSuccess
          VLeft  e -> do
            runLogger $ logError $ T.pack $ prettyShow e
            pure $ ExitFailure 12
