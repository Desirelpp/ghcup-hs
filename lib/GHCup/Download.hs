{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}


{-|
Module      : GHCup.Download
Description : Downloading
Copyright   : (c) Julian Ospald, 2020
License     : LGPL-3.0
Maintainer  : hasufell@hasufell.de
Stability   : experimental
Portability : portable

Module for handling all download related functions.

Generally we support downloading via:

  - curl (default)
  - wget
  - internal downloader (only when compiled)
-}
module GHCup.Download where

#if defined(INTERNAL_DOWNLOADER)
import           GHCup.Download.IOStreams
import           GHCup.Download.Utils
#endif
import           GHCup.Errors
import           GHCup.Types
import           GHCup.Types.JSON               ( )
import           GHCup.Types.Optics
import           GHCup.Utils.Dirs
import           GHCup.Utils.File
import           GHCup.Utils.Prelude
import           GHCup.Version

import           Control.Applicative
import           Control.Exception.Safe
import           Control.Monad
#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
                                         hiding ( throwM )
import           Data.Aeson
import           Data.Bifunctor
import           Data.ByteString                ( ByteString )
import           Data.CaseInsensitive           ( mk )
import           Data.List.Extra
import           Data.Maybe
import           Data.String.Interpolate
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.Versions
import           Data.Word8              hiding ( isSpace )
import           Haskus.Utils.Variant.Excepts
#if defined(INTERNAL_DOWNLOADER)
import           Network.Http.Client     hiding ( URL )
#endif
import           Optics
import           Prelude                 hiding ( abs
                                                , readFile
                                                , writeFile
                                                )
import           System.Directory
import           System.Environment
import           System.Exit
import           System.FilePath
import           System.IO.Error
import           System.IO.Temp
import           Text.PrettyPrint.HughesPJClass ( prettyShow )
import           URI.ByteString

import qualified Crypto.Hash.SHA256            as SHA256
import qualified Data.ByteString               as B
import qualified Data.ByteString.Base16        as B16
import qualified Data.ByteString.Lazy          as L
import qualified Data.Map.Strict               as M
import qualified Data.Text                     as T
import qualified Data.Text.IO                  as T
import qualified Data.Text.Encoding            as E
import qualified Data.Yaml                     as Y






    ------------------
    --[ High-level ]--
    ------------------



-- | Downloads the download information! But only if we need to ;P
getDownloadsF :: ( FromJSONKey Tool
                 , FromJSONKey Version
                 , FromJSON VersionInfo
                 , MonadReader env m
                 , HasSettings env
                 , HasDirs env
                 , MonadIO m
                 , MonadCatch m
                 , MonadLogger m
                 , MonadThrow m
                 , MonadFail m
                 , MonadMask m
                 )
              => Excepts
                   '[JSONError , DownloadFailed , FileDoesNotExistError]
                   m
                   GHCupInfo
getDownloadsF = do
  Settings { urlSource } <- lift getSettings
  case urlSource of
    GHCupURL -> liftE $ getBase ghcupURL
    (OwnSource url) -> liftE $ getBase url
    (OwnSpec av) -> pure av
    (AddSource (Left ext)) -> do
      base <- liftE $ getBase ghcupURL
      pure (mergeGhcupInfo base ext)
    (AddSource (Right uri)) -> do
      base <- liftE $ getBase ghcupURL
      ext  <- liftE $ getBase uri
      pure (mergeGhcupInfo base ext)

    where

  mergeGhcupInfo :: GHCupInfo -- ^ base to merge with
                 -> GHCupInfo -- ^ extension overwriting the base
                 -> GHCupInfo
  mergeGhcupInfo (GHCupInfo tr base base2) (GHCupInfo _ ext ext2) =
    let newDownloads = M.mapWithKey (\k a -> case M.lookup k ext of
                                        Just a' -> M.union a' a
                                        Nothing -> a
                                    ) base
        newGlobalTools = M.union base2 ext2
    in GHCupInfo tr newDownloads newGlobalTools


yamlFromCache :: (MonadReader env m, HasDirs env) => URI -> m FilePath
yamlFromCache uri = do
  Dirs{..} <- getDirs
  pure (cacheDir </> (T.unpack . decUTF8Safe . urlBaseName . view pathL' $ uri))


etagsFile :: FilePath -> FilePath
etagsFile = (<.> "etags")


getBase :: ( MonadReader env m
           , HasDirs env
           , HasSettings env
           , MonadFail m
           , MonadIO m
           , MonadCatch m
           , MonadLogger m
           , MonadMask m
           )
        => URI
        -> Excepts '[JSONError] m GHCupInfo
getBase uri = do
  Settings { noNetwork } <- lift getSettings
  yaml <- lift $ yamlFromCache uri
  unless noNetwork $
    handleIO (\e -> warnCache (displayException e))
      . catchE @_ @_ @'[] (\e@(DownloadFailed _) -> warnCache (prettyShow e))
      . reThrowAll @_ @_ @'[DownloadFailed] DownloadFailed
      . smartDl
      $ uri
  liftE
    . onE_ (onError yaml)
    . lEM' @_ @_ @'[JSONError] JSONDecodeError
    . fmap (first (\e -> [i|#{displayException e}
Consider removing "#{yaml}" manually.|]))
    . liftIO
    . Y.decodeFileEither
    $ yaml
 where
  -- On error, remove the etags file and set access time to 0. This should ensure the next invocation
  -- may re-download and succeed.
  onError :: (MonadLogger m, MonadMask m, MonadCatch m, MonadIO m) => FilePath -> m ()
  onError fp = do
    let efp = etagsFile fp
    handleIO (\e -> $(logWarn) [i|Couldn't remove file #{efp}, error was: #{displayException e}|])
      (hideError doesNotExistErrorType $ rmFile efp)
    liftIO $ hideError doesNotExistErrorType $ setAccessTime fp (posixSecondsToUTCTime (fromIntegral @Int 0))
  warnCache s = do
    lift $ $(logWarn) [i|Could not get download info, trying cached version (this may not be recent!)|]
    lift $ $(logDebug) [i|Error was: #{s}|]

  -- First check if the json file is in the ~/.ghcup/cache dir
  -- and check it's access time. If it has been accessed within the
  -- last 5 minutes, just reuse it.
  --
  -- Always save the local file with the mod time of the remote file.
  smartDl :: forall m1 env1
           . ( MonadReader env1 m1
             , HasDirs env1
             , HasSettings env1
             , MonadCatch m1
             , MonadIO m1
             , MonadFail m1
             , MonadLogger m1
             , MonadMask m1
             )
          => URI
          -> Excepts
               '[ DownloadFailed
                , DigestError
                ]
               m1
               ()
  smartDl uri' = do
    json_file <- lift $ yamlFromCache uri'
    e <- liftIO $ doesFileExist json_file
    currentTime <- liftIO getCurrentTime
    if e
      then do
        accessTime <- liftIO $ getAccessTime json_file

        -- access time won't work on most linuxes, but we can try regardless
        when ((utcTimeToPOSIXSeconds currentTime - utcTimeToPOSIXSeconds accessTime) > 300) $
          -- no access in last 5 minutes, re-check upstream mod time
          dlWithMod currentTime json_file
      else
        dlWithMod currentTime json_file
   where
    dlWithMod modTime json_file = do
      let (dir, fn) = splitFileName json_file
      f <- liftE $ download uri' Nothing dir (Just fn) True
      liftIO $ setModificationTime f modTime
      liftIO $ setAccessTime f modTime
 


getDownloadInfo :: ( MonadReader env m
                   , HasPlatformReq env
                   , HasGHCupInfo env
                   )
                => Tool
                -> Version
                -- ^ tool version
                -> Excepts
                     '[NoDownload]
                     m
                     DownloadInfo
getDownloadInfo t v = do
  (PlatformRequest a p mv) <- lift getPlatformReq
  GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo

  let distro_preview f g =
        let platformVersionSpec =
              preview (ix t % ix v % viArch % ix a % ix (f p)) dls
            mv' = g mv
        in  fmap snd
              .   find
                    (\(mverRange, _) -> maybe
                      (isNothing mv')
                      (\range -> maybe False (`versionRange` range) mv')
                      mverRange
                    )
              .   M.toList
              =<< platformVersionSpec
      with_distro        = distro_preview id id
      without_distro_ver = distro_preview id (const Nothing)
      without_distro     = distro_preview (set _Linux UnknownLinux) (const Nothing)

  maybe
    (throwE NoDownload)
    pure
    (case p of
      -- non-musl won't work on alpine
      Linux Alpine -> with_distro <|> without_distro_ver
      _            -> with_distro <|> without_distro_ver <|> without_distro
    )


-- | Tries to download from the given http or https url
-- and saves the result in continuous memory into a file.
-- If the filename is not provided, then we:
--   1. try to guess the filename from the url path
--   2. otherwise create a random file
--
-- The file must not exist.
download :: ( MonadReader env m
            , HasSettings env
            , HasDirs env
            , MonadMask m
            , MonadThrow m
            , MonadLogger m
            , MonadIO m
            )
         => URI
         -> Maybe T.Text      -- ^ expected hash
         -> FilePath          -- ^ destination dir
         -> Maybe FilePath    -- ^ optional filename
         -> Bool              -- ^ whether to read an write etags
         -> Excepts '[DigestError , DownloadFailed] m FilePath
download uri eDigest dest mfn etags
  | scheme == "https" = dl
  | scheme == "http"  = dl
  | scheme == "file"  = cp
  | otherwise = throwE $ DownloadFailed (variantFromValue UnsupportedScheme)

 where
  scheme = view (uriSchemeL' % schemeBSL') uri
  cp     = do
    -- destination dir must exist
    liftIO $ createDirRecursive' dest
    let fromFile = T.unpack . decUTF8Safe $ path
    liftIO $ copyFile fromFile destFile
    pure destFile
  dl = do
    let uri' = decUTF8Safe (serializeURIRef' uri)
    lift $ $(logInfo) [i|downloading: #{uri'}|]

    -- destination dir must exist
    liftIO $ createDirRecursive' dest

    -- download
    flip onException
         (lift $ hideError doesNotExistErrorType $ recycleFile destFile)
     $ catchAllE @_ @'[ProcessError, DownloadFailed, UnsupportedScheme]
          (\e ->
            lift (hideError doesNotExistErrorType $ recycleFile destFile)
              >> (throwE . DownloadFailed $ e)
          ) $ do
              Settings{ downloader, noNetwork } <- lift getSettings
              when noNetwork $ throwE (DownloadFailed (V NoNetwork :: V '[NoNetwork]))
              case downloader of
                Curl -> do
                  o' <- liftIO getCurlOpts
                  if etags
                    then do
                      dh <- liftIO $ emptySystemTempFile "curl-header"
                      flip finally (try @_ @SomeException $ rmFile dh) $ do
                        metag <- readETag destFile
                        liftE $ lEM @_ @'[ProcessError] $ exec "curl" 
                            (o' ++ (if etags then ["--dump-header", dh] else [])
                                ++ maybe [] (\t -> ["-H", [i|If-None-Match: #{t}|]]) metag
                                ++ ["-fL", "-o", destFile, T.unpack uri']) Nothing Nothing
                        headers <- liftIO $ T.readFile dh
                        writeEtags (parseEtags headers)
                    else
                      liftE $ lEM @_ @'[ProcessError] $ exec "curl" 
                        (o' ++ ["-fL", "-o", destFile, T.unpack uri']) Nothing Nothing
                Wget -> do
                  destFileTemp <- liftIO $ emptySystemTempFile "wget-tmp"
                  flip finally (try @_ @SomeException $ rmFile destFileTemp) $ do
                    o' <- liftIO getWgetOpts
                    metag <- readETag destFile
                    if etags
                      then do
                        let opts = o' ++ maybe [] (\t -> ["--header", [i|If-None-Match: #{t}|]]) metag
                                      ++ ["-q", "-S", "-O", destFileTemp , T.unpack uri']
                        CapturedProcess {_exitCode, _stdErr} <- lift $ executeOut "wget" opts Nothing
                        case _exitCode of
                          ExitSuccess -> do
                            liftIO $ copyFile destFileTemp destFile
                            writeEtags (parseEtags (decUTF8Safe' _stdErr))
                          ExitFailure i'
                            | i' == 8
                            , Just _ <- find (T.pack "304 Not Modified" `T.isInfixOf`) . T.lines . decUTF8Safe' $ _stdErr
                                     -> do
                                          $logDebug "Not modified, skipping download"
                                          writeEtags (parseEtags (decUTF8Safe' _stdErr))
                            | otherwise -> throwE (NonZeroExit i' "wget" opts)
                      else do
                        let opts = o' ++ ["-O", destFileTemp , T.unpack uri']
                        liftE $ lEM @_ @'[ProcessError] $ exec "wget" opts Nothing Nothing
                        liftIO $ copyFile destFileTemp destFile
#if defined(INTERNAL_DOWNLOADER)
                Internal -> do
                  (https, host, fullPath, port) <- liftE $ uriToQuadruple uri
                  metag <- readETag destFile
                  let addHeaders = maybe mempty (\etag -> M.fromList [ (mk . E.encodeUtf8 . T.pack $ "If-None-Match"
                                                                     , E.encodeUtf8 etag)]) metag
                  if etags
                    then
                      liftE
                        $ catchE @HTTPNotModified @'[DownloadFailed] @'[] (\(HTTPNotModified etag) -> lift $ writeEtags (pure $ Just etag))
                        $ do
                          r <- downloadToFile https host fullPath port destFile addHeaders
                          writeEtags (pure $ decUTF8Safe <$> getHeader r "etag")
                    else void $ liftE $ catchE @HTTPNotModified
                                        @'[DownloadFailed]
                                   (\e@(HTTPNotModified _) ->
                                     throwE @_ @'[DownloadFailed] (DownloadFailed (toVariantAt @0 e :: V '[HTTPNotModified])))
                               $ downloadToFile https host fullPath port destFile mempty
#endif

    forM_ eDigest (liftE . flip checkDigest destFile)
    pure destFile

  -- Manage to find a file we can write the body into.
  destFile :: FilePath
  destFile = maybe (dest </> T.unpack (decUTF8Safe (urlBaseName path)))
                  (dest </>)
                  mfn

  path = view pathL' uri

  parseEtags :: (MonadLogger m, MonadIO m, MonadThrow m) => T.Text -> m (Maybe T.Text)
  parseEtags stderr = do
    let mEtag = find (\line -> T.pack "etag:" `T.isPrefixOf` T.toLower line) . fmap T.strip . T.lines $ stderr
    case T.words <$> mEtag of
      (Just []) -> do
        $logDebug "Couldn't parse etags, no input: "
        pure Nothing
      (Just [_, etag']) -> do
        $logDebug [i|Parsed etag: #{etag'}|]
        pure (Just etag')
      (Just xs) -> do
        $logDebug ("Couldn't parse etags, unexpected input: " <> T.unwords xs)
        pure Nothing
      Nothing -> do
        $logDebug "No etags header found"
        pure Nothing

  writeEtags :: (MonadLogger m, MonadIO m, MonadThrow m) => m (Maybe T.Text) -> m ()
  writeEtags getTags = do
    getTags >>= \case
      Just t -> do
        $logDebug [i|Writing etagsFile #{(etagsFile destFile)}|]
        liftIO $ T.writeFile (etagsFile destFile) t
      Nothing ->
        $logDebug [i|No etags files written|]

  readETag :: (MonadLogger m, MonadCatch m, MonadIO m) => FilePath -> m (Maybe T.Text)
  readETag fp = do
    e <- liftIO $ doesFileExist fp
    if e
    then do
      rE <- try @_ @SomeException $ liftIO $ fmap stripNewline' $ T.readFile (etagsFile fp)
      case rE of
        (Right et) -> do
          $logDebug [i|Read etag: #{et}|]
          pure (Just et)
        (Left _) -> do
          $logDebug [i|Etag file doesn't exist (yet)|]
          pure Nothing
    else do
      $logDebug [i|Skipping and deleting etags file because destination file #{fp} doesn't exist|]
      liftIO $ hideError doesNotExistErrorType $ rmFile (etagsFile fp)
      pure Nothing


-- | Download into tmpdir or use cached version, if it exists. If filename
-- is omitted, infers the filename from the url.
downloadCached :: ( MonadReader env m
                  , HasDirs env
                  , HasSettings env
                  , MonadMask m
                  , MonadResource m
                  , MonadThrow m
                  , MonadLogger m
                  , MonadIO m
                  , MonadUnliftIO m
                  )
               => DownloadInfo
               -> Maybe FilePath  -- ^ optional filename
               -> Excepts '[DigestError , DownloadFailed] m FilePath
downloadCached dli mfn = do
  Settings{ cache } <- lift getSettings
  case cache of
    True -> downloadCached' dli mfn Nothing
    False -> do
      tmp <- lift withGHCupTmpDir
      liftE $ download (_dlUri dli) (Just (_dlHash dli)) tmp mfn False


downloadCached' :: ( MonadReader env m
                   , HasDirs env
                   , HasSettings env
                   , MonadMask m
                   , MonadThrow m
                   , MonadLogger m
                   , MonadIO m
                   , MonadUnliftIO m
                   )
                => DownloadInfo
                -> Maybe FilePath  -- ^ optional filename
                -> Maybe FilePath  -- ^ optional destination dir (default: cacheDir)
                -> Excepts '[DigestError , DownloadFailed] m FilePath
downloadCached' dli mfn mDestDir = do
  Dirs { cacheDir } <- lift getDirs
  let destDir = fromMaybe cacheDir mDestDir
  let fn = fromMaybe ((T.unpack . decUTF8Safe) $ urlBaseName $ view (dlUri % pathL') dli) mfn
  let cachfile = destDir </> fn
  fileExists <- liftIO $ doesFileExist cachfile
  if
    | fileExists -> do
      liftE $ checkDigest (view dlHash dli) cachfile
      pure cachfile
    | otherwise -> liftE $ download (_dlUri dli) (Just (_dlHash dli)) destDir mfn False




    ------------------
    --[ Low-level ]--
    ------------------



checkDigest :: ( MonadReader env m
               , HasDirs env
               , HasSettings env
               , MonadIO m
               , MonadThrow m
               , MonadLogger m
               )
            => T.Text     -- ^ the hash
            -> FilePath
            -> Excepts '[DigestError] m ()
checkDigest eDigest file = do
  Settings{ noVerify } <- lift getSettings
  let verify = not noVerify
  when verify $ do
    let p' = takeFileName file
    lift $ $(logInfo) [i|verifying digest of: #{p'}|]
    c <- liftIO $ L.readFile file
    cDigest <- throwEither . E.decodeUtf8' . B16.encode . SHA256.hashlazy $ c
    when ((cDigest /= eDigest) && verify) $ throwE (DigestError cDigest eDigest)


-- | Get additional curl args from env. This is an undocumented option.
getCurlOpts :: IO [String]
getCurlOpts =
  lookupEnv "GHCUP_CURL_OPTS" >>= \case
    Just r  -> pure $ splitOn " " r
    Nothing -> pure []


-- | Get additional wget args from env. This is an undocumented option.
getWgetOpts :: IO [String]
getWgetOpts =
  lookupEnv "GHCUP_WGET_OPTS" >>= \case
    Just r  -> pure $ splitOn " " r
    Nothing -> pure []


urlBaseName :: ByteString  -- ^ the url path (without scheme and host)
            -> ByteString
urlBaseName = snd . B.breakEnd (== _slash) . urlDecode False

