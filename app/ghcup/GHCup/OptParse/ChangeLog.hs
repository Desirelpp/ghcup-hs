{-# LANGUAGE CPP               #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes #-}

module GHCup.OptParse.ChangeLog where


import           GHCup.Types
import           GHCup.Logger
import           GHCup.OptParse.Common
import           GHCup.QQ.String

#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           Data.Functor
import           Data.Maybe
import           Options.Applicative     hiding ( style )
import           Prelude                 hiding ( appendFile )
import           System.Exit
import           Text.PrettyPrint.HughesPJClass ( prettyShow )

import qualified Data.Text                     as T
import Control.Exception.Safe (MonadMask)
import GHCup.Types.Optics
import GHCup.Utils
import Data.Versions
import URI.ByteString (serializeURIRef')
import GHCup.Prelude
import GHCup.System.Process (exec)
import Data.Char (toLower)



    ---------------
    --[ Options ]--
    ---------------


data ChangeLogOptions = ChangeLogOptions
  { clOpen    :: Bool
  , clTool    :: Maybe Tool
  , clToolVer :: Maybe ToolVersion
  }




    ---------------
    --[ Parsers ]--
    ---------------

          
changelogP :: Parser ChangeLogOptions
changelogP =
  (\x y -> ChangeLogOptions x y)
    <$> switch (short 'o' <> long "open" <> help "xdg-open the changelog url")
    <*> optional
          (option
            (eitherReader
              (\s' -> case fmap toLower s' of
                "ghc"   -> Right GHC
                "cabal" -> Right Cabal
                "ghcup" -> Right GHCup
                "stack" -> Right Stack
                e       -> Left e
              )
            )
            (short 't' <> long "tool" <> metavar "<ghc|cabal|ghcup>" <> help
              "Open changelog for given tool (default: ghc)"
            )
          )
    <*> optional (toolVersionArgument Nothing Nothing)



    --------------
    --[ Footer ]--
    --------------


changeLogFooter :: String
changeLogFooter = [s|Discussion:
  By default returns the URI of the ChangeLog of the latest GHC release.
  Pass '-o' to automatically open via xdg-open.|]



    ------------------
    --[ Entrypoint ]--
    ------------------



changelog :: ( Monad m
             , MonadMask m
             , MonadUnliftIO m
             , MonadFail m
             )
          => ChangeLogOptions
          -> (forall a . ReaderT AppState m a -> m a)
          -> (ReaderT LeanAppState m () -> m ())
          -> m ExitCode
changelog ChangeLogOptions{..} runAppState runLogger = do
  GHCupInfo { _ghcupDownloads = dls } <- runAppState getGHCupInfo
  let tool = fromMaybe GHC clTool
      ver' = maybe
        (Right Latest)
        (\case
          ToolVersion tv -> Left (_tvVersion tv) -- FIXME: ugly sharing of ToolVersion
          ToolTag     t  -> Right t
        )
        clToolVer
      muri = getChangeLog dls tool ver'
  case muri of
    Nothing -> do
      runLogger
        (logWarn $
          "Could not find ChangeLog for " <> T.pack (prettyShow tool) <> ", version " <> either prettyVer (T.pack . show) ver'
        )
      pure ExitSuccess
    Just uri -> do
      pfreq <- runAppState getPlatformReq
      let uri' = T.unpack . decUTF8Safe . serializeURIRef' $ uri
          cmd = case _rPlatform pfreq of
                  Darwin  -> "open"
                  Linux _ -> "xdg-open"
                  FreeBSD -> "xdg-open"
                  Windows -> "start"

      if clOpen
        then do
          runAppState $
            exec cmd
                 [T.unpack $ decUTF8Safe $ serializeURIRef' uri]
                 Nothing
                 Nothing
              >>= \case
                    Right _ -> pure ExitSuccess
                    Left  e -> logError (T.pack $ prettyShow e)
                      >> pure (ExitFailure 13)
        else liftIO $ putStrLn uri' >> pure ExitSuccess
