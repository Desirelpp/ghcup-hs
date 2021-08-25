{-# LANGUAGE CPP              #-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE QuasiQuotes      #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns     #-}
{-# LANGUAGE OverloadedStrings #-}

module Validate where

import           GHCup
import           GHCup.Download
import           GHCup.Errors
import           GHCup.Platform
import           GHCup.Types                  hiding ( LeanAppState (..) )
import           GHCup.Types.Optics
import           GHCup.Utils
import           GHCup.Utils.Logger
import           GHCup.Utils.Version.QQ

import           Codec.Archive
import           Control.Applicative
import           Control.Exception.Safe
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Reader.Class
import           Control.Monad.Trans.Class      ( lift )
import           Control.Monad.Trans.Reader     ( runReaderT )
import           Control.Monad.Trans.Resource   ( runResourceT
                                                , MonadUnliftIO
                                                )
import           Data.Containers.ListUtils      ( nubOrd )
import           Data.IORef
import           Data.List
import           Data.Versions
import           Haskus.Utils.Variant.Excepts
import           Optics
import           System.FilePath
import           System.Exit
import           System.IO
import           Text.ParserCombinators.ReadP
import           Text.PrettyPrint.HughesPJClass ( prettyShow )
import           Text.Regex.Posix

import qualified Data.ByteString               as B
import qualified Data.Map.Strict               as M
import qualified Data.Text                     as T
import qualified Data.Version                  as V


data ValidationError = InternalError String
  deriving Show

instance Exception ValidationError


addError :: (MonadReader (IORef Int) m, MonadIO m, Monad m) => m ()
addError = do
  ref <- ask
  liftIO $ modifyIORef ref (+ 1)


validate :: (Monad m, MonadLogger m, MonadThrow m, MonadIO m, MonadUnliftIO m)
         => GHCupDownloads
         -> M.Map GlobalTool DownloadInfo
         -> m ExitCode
validate dls _ = do
  ref <- liftIO $ newIORef 0

  -- verify binary downloads --
  flip runReaderT ref $ do
    -- unique tags
    forM_ (M.toList dls) $ \(t, _) -> checkUniqueTags t

    -- required platforms
    forM_ (M.toList dls) $ \(t, versions) ->
      forM_ (M.toList versions) $ \(v, vi) ->
        forM_ (M.toList $ _viArch vi) $ \(arch, pspecs) -> do
          checkHasRequiredPlatforms t v (_viTags vi) arch (M.keys pspecs)

    checkGHCVerIsValid
    forM_ (M.toList dls) $ \(t, _) -> checkMandatoryTags t
    _ <- checkGHCHasBaseVersion

    -- exit
    e <- liftIO $ readIORef ref
    if e > 0
      then pure $ ExitFailure e
      else do
        lift $ $(logInfo) "All good"
        pure ExitSuccess
 where
  checkHasRequiredPlatforms t v tags arch pspecs = do
    let v' = prettyVer v
        arch' = prettyShow arch
    when (notElem (Linux UnknownLinux) pspecs) $ do
      lift $ $(logError) $
        "Linux UnknownLinux missing for for " <> T.pack (prettyShow t) <> " " <> v' <> " " <> T.pack arch'
      addError
    when ((notElem Darwin pspecs) && arch == A_64) $ do
      lift $ $(logError) $ "Darwin missing for for " <> T.pack (prettyShow t) <> " " <> v' <> " " <> T.pack arch'
      addError
    when ((notElem FreeBSD pspecs) && arch == A_64) $ lift $ $(logWarn) $
      "FreeBSD missing for for " <> T.pack (prettyShow t) <> " " <> v' <> " " <> T.pack arch'
    when (notElem Windows pspecs && arch == A_64) $ do
      lift $ $(logError) $ "Windows missing for for " <> T.pack (prettyShow t) <> " " <> v' <> " " <> T.pack arch'
      addError

    -- alpine needs to be set explicitly, because
    -- we cannot assume that "Linux UnknownLinux" runs on Alpine
    -- (although it could be static)
    when (notElem (Linux Alpine) pspecs) $
      case t of
        GHCup | arch `elem` [A_64, A_32] -> lift ($(logError) $ "Linux Alpine missing for " <> T.pack (prettyShow t) <> " " <> v' <> " " <> T.pack (prettyShow arch)) >> addError
        Cabal | v > [vver|2.4.1.0|]
              , arch `elem` [A_64, A_32] -> lift ($(logError) $ "Linux Alpine missing for " <> T.pack (prettyShow t) <> " " <> v' <> " " <> T.pack (prettyShow arch)) >> addError
        GHC | Latest `elem` tags || Recommended `elem` tags
            , arch `elem` [A_64, A_32] -> lift ($(logError) $ "Linux Alpine missing for " <> T.pack (prettyShow t) <> " " <> v' <> " " <> T.pack (prettyShow arch))
        _ -> lift $ $(logWarn) $ "Linux Alpine missing for " <> T.pack (prettyShow t) <> " " <> v' <> " " <> T.pack (prettyShow arch)

  checkUniqueTags tool = do
    let allTags = join $ fmap _viTags $ M.elems $ availableToolVersions dls tool
    let nonUnique =
          fmap fst
            .   filter (\(_, b) -> not b)
            <$> ( mapM
                    (\case
                      [] -> throwM $ InternalError "empty inner list"
                      (t : ts) ->
                        pure $ (t, ) (not (isUniqueTag t) || null ts)
                    )
                . group
                . sort
                $ allTags
                )
    case join nonUnique of
      [] -> pure ()
      xs -> do
        lift $ $(logError) $ "Tags not unique for " <> T.pack (prettyShow tool) <> ": " <> T.pack (prettyShow xs)
        addError
   where
    isUniqueTag Latest         = True
    isUniqueTag Recommended    = True
    isUniqueTag Old            = False
    isUniqueTag Prerelease     = False
    isUniqueTag (Base       _) = False
    isUniqueTag (UnknownTag _) = False

  checkGHCVerIsValid = do
    let ghcVers = toListOf (ix GHC % to M.keys % folded) dls
    forM_ ghcVers $ \v ->
      case [ x | (x,"") <- readP_to_S V.parseVersion (T.unpack . prettyVer $ v) ] of
        [_] -> pure ()
        _   -> do
          lift $ $(logError) $ "GHC version " <> prettyVer v <> " is not valid"
          addError

  -- a tool must have at least one of each mandatory tags
  checkMandatoryTags tool = do
    let allTags = join $ fmap _viTags $ M.elems $ availableToolVersions dls tool
    forM_ [Latest, Recommended] $ \t -> case elem t allTags of
      False -> do
        lift $ $(logError) $ "Tag " <> T.pack (prettyShow t) <> " missing from " <> T.pack (prettyShow tool)
        addError
      True -> pure ()

  -- all GHC versions must have a base tag
  checkGHCHasBaseVersion = do
    let allTags = M.toList $ availableToolVersions dls GHC
    forM allTags $ \(ver, _viTags -> tags) -> case any isBase tags of
      False -> do
        lift $ $(logError) $ "Base tag missing from GHC ver " <> prettyVer ver
        addError
      True -> pure ()

  isBase (Base _) = True
  isBase _        = False

data TarballFilter = TarballFilter
  { tfTool    :: Either GlobalTool (Maybe Tool)
  , tfVersion :: Regex
  }

validateTarballs :: ( Monad m
                    , MonadLogger m
                    , MonadThrow m
                    , MonadIO m
                    , MonadUnliftIO m
                    , MonadMask m
                    , Alternative m
                    , MonadFail m
                    )
                 => TarballFilter
                 -> GHCupDownloads
                 -> M.Map GlobalTool DownloadInfo
                 -> m ExitCode
validateTarballs (TarballFilter etool versionRegex) dls gt = do
  ref <- liftIO $ newIORef 0

  flip runReaderT ref $ do
     -- download/verify all tarballs
    let dlis = either (const []) (\tool -> nubOrd $ dls ^.. each %& indices (maybe (const True) (==) tool) %> each %& indices (matchTest versionRegex . T.unpack . prettyVer) % (viSourceDL % _Just `summing` viArch % each % each % each)) etool
    let gdlis = nubOrd $ gt ^.. each
    let allDls = either (const gdlis) (const dlis) etool
    when (null allDls) $ $(logError) "no tarballs selected by filter" *> addError
    forM_ allDls downloadAll

    -- exit
    e <- liftIO $ readIORef ref
    if e > 0
      then pure $ ExitFailure e
      else do
        lift $ $(logInfo) "All good"
        pure ExitSuccess

 where
  runLogger = myLoggerT LoggerConfig { lcPrintDebug = True
                                     , colorOutter  = B.hPut stderr
                                     , rawOutter    = \_ -> pure ()
                                     }
  downloadAll dli = do
    dirs <- liftIO getAllDirs

    pfreq <- (
      runLogger . runE @'[NoCompatiblePlatform, NoCompatibleArch, DistroNotFound] . liftE $ platformRequest
      ) >>= \case
              VRight r -> pure r
              VLeft e -> do
                lift $ runLogger
                  ($(logError) $ T.pack $ prettyShow e)
                liftIO $ exitWith (ExitFailure 2)

    let appstate = AppState (Settings True False Never Curl True GHCupURL False) dirs defaultKeyBindings (GHCupInfo mempty mempty mempty) pfreq

    r <-
      runLogger
      . flip runReaderT appstate
      . runResourceT
      . runE @'[DigestError
               , DownloadFailed
               , UnknownArchive
               , ArchiveResult
               ]
      $ do
        case etool of
          Right (Just GHCup) -> do
            tmpUnpack <- lift mkGhcupTmpDir
            _ <- liftE $ download (_dlUri dli) (Just (_dlHash dli)) tmpUnpack Nothing False
            pure Nothing
          Right _ -> do
            p <- liftE $ downloadCached dli Nothing
            fmap (Just . head . splitDirectories . head)
              . liftE
              . getArchiveFiles
              $ p
          Left ShimGen -> do
            tmpUnpack <- lift mkGhcupTmpDir
            _ <- liftE $ download (_dlUri dli) (Just (_dlHash dli)) tmpUnpack Nothing False
            pure Nothing
    case r of
      VRight (Just basePath) -> do
        case _dlSubdir dli of
          Just (RealDir prel) -> do
            lift $ $(logInfo)
              $ " verifying subdir: " <> T.pack prel
            when (basePath /= prel) $ do
              lift $ $(logError) $
                "Subdir doesn't match: expected " <> T.pack prel <> ", got " <> T.pack basePath
              addError
          Just (RegexDir regexString) -> do
            lift $ $(logInfo) $
              "verifying subdir (regex): " <> T.pack regexString
            let regex = makeRegexOpts
                  compIgnoreCase
                  execBlank
                  regexString
            when (not (match regex basePath)) $ do
              lift $ $(logError) $
                "Subdir doesn't match: expected regex " <> T.pack regexString <> ", got " <> T.pack basePath
              addError
          Nothing -> pure ()
      VRight Nothing -> pure ()
      VLeft  e -> do
        lift $ $(logError) $
          "Could not download (or verify hash) of " <> T.pack (show dli) <> ", Error was: " <> T.pack (prettyShow e)
        addError
