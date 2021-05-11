{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE ViewPatterns          #-}

{-|
Module      : GHCup.Utils
Description : GHCup domain specific utilities
Copyright   : (c) Julian Ospald, 2020
License     : LGPL-3.0
Maintainer  : hasufell@hasufell.de
Stability   : experimental
Portability : POSIX

This module contains GHCup helpers specific to
installation and introspection of files/versions etc.
-}
module GHCup.Utils
  ( module GHCup.Utils.Dirs
  , module GHCup.Utils
  )
where


import           GHCup.Errors
import           GHCup.Types
import           GHCup.Types.Optics
import           GHCup.Types.JSON               ( )
import           GHCup.Utils.Dirs
import           GHCup.Utils.File
import           GHCup.Utils.MegaParsec
import           GHCup.Utils.Prelude
import           GHCup.Utils.String.QQ

#if !defined(TAR)
import           Codec.Archive           hiding ( Directory )
#endif
import           Control.Applicative
import           Control.Exception.Safe
import           Control.Monad
#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.ByteString                ( ByteString )
import           Data.Either
import           Data.Foldable
import           Data.List
import           Data.List.NonEmpty             ( NonEmpty( (:|) ))
import           Data.List.Split
import           Data.Maybe
import           Data.String.Interpolate
import           Data.Text                      ( Text )
import           Data.Versions
import           Data.Word8
import           GHC.IO.Exception
import           HPath
import           HPath.IO                hiding ( hideError )
import           Haskus.Utils.Variant.Excepts
import           Optics
import           Prelude                 hiding ( abs
                                                , readFile
                                                , writeFile
                                                )
import           Safe
import           System.IO.Error
import           System.Posix.FilePath          ( getSearchPath
                                                , takeFileName
                                                )
import           System.Posix.Files.ByteString  ( readSymbolicLink )
import           Text.Regex.Posix
import           URI.ByteString

#if defined(TAR)
import qualified Codec.Archive.Tar             as Tar
#endif
import qualified Codec.Compression.BZip        as BZip
import qualified Codec.Compression.GZip        as GZip
import qualified Codec.Compression.Lzma        as Lzma
import qualified Data.ByteString               as B
import qualified Data.ByteString.Lazy          as BL
import qualified Data.Map.Strict               as Map
#if !defined(TAR)
import qualified Data.Text                     as T
#endif
import qualified Data.Text.Encoding            as E
import qualified Text.Megaparsec               as MP
import System.Console.Regions
import Data.Sequence (Seq)
import qualified Data.Sequence as Sq
import Control.Concurrent





    ------------------------
    --[ Symlink handling ]--
    ------------------------


-- | The symlink destination of a ghc tool.
ghcLinkDestination :: (MonadReader AppState m, MonadThrow m, MonadIO m)
                   => ByteString -- ^ the tool, such as 'ghc', 'haddock' etc.
                   -> GHCTargetVersion
                   -> m ByteString
ghcLinkDestination tool ver = do
  AppState { dirs = Dirs {..} } <- ask
  t <- parseRel tool
  ghcd <- ghcupGHCDir ver
  pure (relativeSymlink binDir (ghcd </> [rel|bin|] </> t))


-- | Removes the minor GHC symlinks, e.g. ghc-8.6.5.
rmMinorSymlinks :: ( MonadReader AppState m
                   , MonadIO m
                   , MonadLogger m
                   , MonadThrow m
                   , MonadFail m
                   , MonadReader AppState m
                   )
                => GHCTargetVersion
                -> Excepts '[NotInstalled] m ()
rmMinorSymlinks tv@GHCTargetVersion{..} = do
  AppState { dirs = Dirs {..} } <- lift ask

  files                         <- liftE $ ghcToolFiles tv
  forM_ files $ \f -> do
    f_xyz <- liftIO $ parseRel (toFilePath f <> B.singleton _hyphen <> verToBS _tvVersion)
    let fullF = binDir </> f_xyz
    lift $ $(logDebug) [i|rm -f #{toFilePath fullF}|]
    liftIO $ hideError doesNotExistErrorType $ deleteFile fullF


-- | Removes the set ghc version for the given target, if any.
rmPlain :: ( MonadReader AppState m
           , MonadLogger m
           , MonadThrow m
           , MonadFail m
           , MonadIO m
           )
        => Maybe Text -- ^ target
        -> Excepts '[NotInstalled] m ()
rmPlain target = do
  AppState { dirs = Dirs {..} } <- lift ask
  mtv                           <- lift $ ghcSet target
  forM_ mtv $ \tv -> do
    files <- liftE $ ghcToolFiles tv
    forM_ files $ \f -> do
      let fullF = binDir </> f
      lift $ $(logDebug) [i|rm -f #{toFilePath fullF}|]
      liftIO $ hideError doesNotExistErrorType $ deleteFile fullF
    -- old ghcup
    let hdc_file = binDir </> [rel|haddock-ghc|]
    lift $ $(logDebug) [i|rm -f #{toFilePath hdc_file}|]
    liftIO $ hideError doesNotExistErrorType $ deleteFile hdc_file


-- | Remove the major GHC symlink, e.g. ghc-8.6.
rmMajorSymlinks :: ( MonadReader AppState m
                   , MonadIO m
                   , MonadLogger m
                   , MonadThrow m
                   , MonadFail m
                   , MonadReader AppState m
                   )
                => GHCTargetVersion
                -> Excepts '[NotInstalled] m ()
rmMajorSymlinks tv@GHCTargetVersion{..} = do
  AppState { dirs = Dirs {..} } <- lift ask
  (mj, mi) <- getMajorMinorV _tvVersion
  let v' = intToText mj <> "." <> intToText mi

  files                         <- liftE $ ghcToolFiles tv
  forM_ files $ \f -> do
    f_xyz <- liftIO $ parseRel (toFilePath f <> B.singleton _hyphen <> E.encodeUtf8 v')
    let fullF = binDir </> f_xyz
    lift $ $(logDebug) [i|rm -f #{toFilePath fullF}|]
    liftIO $ hideError doesNotExistErrorType $ deleteFile fullF




    -----------------------------------
    --[ Set/Installed introspection ]--
    -----------------------------------


-- | Whether the given GHC versin is installed.
ghcInstalled :: (MonadIO m, MonadReader AppState m, MonadThrow m) => GHCTargetVersion -> m Bool
ghcInstalled ver = do
  ghcdir <- ghcupGHCDir ver
  liftIO $ doesDirectoryExist ghcdir


-- | Whether the given GHC version is installed from source.
ghcSrcInstalled :: (MonadIO m, MonadReader AppState m, MonadThrow m) => GHCTargetVersion -> m Bool
ghcSrcInstalled ver = do
  ghcdir <- ghcupGHCDir ver
  liftIO $ doesFileExist (ghcdir </> ghcUpSrcBuiltFile)


-- | Whether the given GHC version is set as the current.
ghcSet :: (MonadReader AppState m, MonadThrow m, MonadIO m)
       => Maybe Text   -- ^ the target of the GHC version, if any
                       --  (e.g. armv7-unknown-linux-gnueabihf)
       -> m (Maybe GHCTargetVersion)
ghcSet mtarget = do
  AppState {dirs = Dirs {..}} <- ask
  ghc    <- parseRel $ E.encodeUtf8 (maybe "ghc" (<> "-ghc") mtarget)
  let ghcBin = binDir </> ghc

  -- link destination is of the form ../ghc/<ver>/bin/ghc
  -- for old ghcup, it is ../ghc/<ver>/bin/ghc-<ver>
  liftIO $ handleIO' NoSuchThing (\_ -> pure Nothing) $ do
    link <- readSymbolicLink $ toFilePath ghcBin
    Just <$> ghcLinkVersion link

ghcLinkVersion :: MonadThrow m => ByteString -> m GHCTargetVersion
ghcLinkVersion bs = do
  t <- throwEither $ E.decodeUtf8' bs
  throwEither $ MP.parse parser "ghcLinkVersion" t
 where
  parser =
      (do
         _    <- parseUntil1 (MP.chunk "/ghc/")
         _    <- MP.chunk "/ghc/"
         r    <- parseUntil1 (MP.chunk "/")
         rest <- MP.getInput
         MP.setInput r
         x <- ghcTargetVerP
         MP.setInput rest
         pure x
       )
      <* MP.chunk "/"
      <* MP.takeRest
      <* MP.eof


-- | Get all installed GHCs by reading ~/.ghcup/ghc/<dir>.
-- If a dir cannot be parsed, returns left.
getInstalledGHCs :: (MonadReader AppState m, MonadIO m) => m [Either (Path Rel) GHCTargetVersion]
getInstalledGHCs = do
  ghcdir <- ghcupGHCBaseDir
  fs     <- liftIO $ hideErrorDef [NoSuchThing] [] $ getDirsFiles' ghcdir
  forM fs $ \f -> case parseGHCupGHCDir f of
    Right r -> pure $ Right r
    Left  _ -> pure $ Left f


-- | Get all installed cabals, by matching on @~\/.ghcup\/bin/cabal-*@.
getInstalledCabals :: (MonadLogger m, MonadReader AppState m, MonadIO m, MonadCatch m)
                   => m [Either (Path Rel) Version]
getInstalledCabals = do
  cs <- cabalSet -- for legacy cabal
  getInstalledCabals' cs


getInstalledCabals' :: (MonadLogger m, MonadReader AppState m, MonadIO m, MonadCatch m)
                   => Maybe Version
                   -> m [Either (Path Rel) Version]
getInstalledCabals' cs = do
  AppState {dirs = Dirs {..}} <- ask
  bins   <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts compExtended execBlank ([s|^cabal-.*$|] :: ByteString))
  vs <- forM bins $ \f -> case fmap (version . decUTF8Safe) . B.stripPrefix "cabal-" . toFilePath $ f of
    Just (Right r) -> pure $ Right r
    Just (Left  _) -> pure $ Left f
    Nothing        -> pure $ Left f
  pure $ maybe vs (\x -> nub $ Right x:vs) cs


-- | Whether the given cabal version is installed.
cabalInstalled :: (MonadLogger m, MonadIO m, MonadReader AppState m, MonadCatch m) => Version -> m Bool
cabalInstalled ver = do
  vers <- fmap rights getInstalledCabals
  pure $ elem ver vers


-- Return the currently set cabal version, if any.
cabalSet :: (MonadLogger m, MonadReader AppState m, MonadIO m, MonadThrow m, MonadCatch m) => m (Maybe Version)
cabalSet = do
  AppState {dirs = Dirs {..}} <- ask
  let cabalbin = binDir </> [rel|cabal|]
  b        <- handleIO (\_ -> pure False) $ fmap (== SymbolicLink) $ liftIO $ getFileType cabalbin
  if
    | b -> do
      handleIO' NoSuchThing (\_ -> pure Nothing) $ do
        broken <- liftIO $ isBrokenSymlink cabalbin
        if broken
          then do
            $(logWarn) [i|Symlink #{cabalbin} is broken.|]
            pure Nothing
          else do
            link <- liftIO $ readSymbolicLink $ toFilePath cabalbin
            case linkVersion link of
              Right v -> pure $ Just v
              Left err -> do
                $(logWarn) [i|Failed to parse cabal symlink target with: "#{err}". The symlink #{toFilePath cabalbin} needs to point to valid cabal binary, such as 'cabal-3.4.0.0'.|]
                pure Nothing
    | otherwise -> do -- legacy behavior
      mc <- liftIO $ handleIO (\_ -> pure Nothing) $ fmap Just $ executeOut
        cabalbin
        ["--numeric-version"]
        Nothing
      fmap join $ forM mc $ \c -> if
        | not (B.null (_stdOut c)), _exitCode c == ExitSuccess -> do
          let reportedVer = fst . B.spanEnd (== _lf) . _stdOut $ c
          case version $ decUTF8Safe reportedVer of
            Left  e -> throwM e
            Right r -> pure $ Just r
        | otherwise -> pure Nothing
 where
  -- We try to be extra permissive with link destination parsing,
  -- because of:
  --   https://gitlab.haskell.org/haskell/ghcup-hs/-/issues/119
  linkVersion :: MonadThrow m => ByteString -> m Version
  linkVersion bs = do
    t <- throwEither $ E.decodeUtf8' bs
    throwEither $ MP.parse parser "" t

  parser
    =   MP.try (stripAbsolutePath *> cabalParse)
    <|> MP.try (stripRelativePath *> cabalParse)
    <|> cabalParse
  -- parses the version of "cabal-3.2.0.0" -> "3.2.0.0"
  cabalParse = MP.chunk "cabal-" *> version'
  -- parses any path component ending with path separator,
  -- e.g. "foo/"
  stripPathComponet = parseUntil1 "/" *> MP.chunk "/"
  -- parses an absolute path up until the last path separator,
  -- e.g. "/bar/baz/foo" -> "/bar/baz/", leaving "foo"
  stripAbsolutePath = MP.chunk "/" *> MP.many (MP.try stripPathComponet)
  -- parses a relative path up until the last path separator,
  -- e.g. "bar/baz/foo" -> "bar/baz/", leaving "foo"
  stripRelativePath = MP.many (MP.try stripPathComponet)



-- | Get all installed hls, by matching on
-- @~\/.ghcup\/bin/haskell-language-server-wrapper-<\hlsver\>@.
getInstalledHLSs :: (MonadReader AppState m, MonadIO m, MonadCatch m)
                 => m [Either (Path Rel) Version]
getInstalledHLSs = do
  AppState { dirs = Dirs {..} } <- ask
  bins                          <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts compExtended
                   execBlank
                   ([s|^haskell-language-server-wrapper-.*$|] :: ByteString)
    )
  forM bins $ \f ->
    case
          fmap (version . decUTF8Safe) . B.stripPrefix "haskell-language-server-wrapper-" . toFilePath $ f
      of
        Just (Right r) -> pure $ Right r
        Just (Left  _) -> pure $ Left f
        Nothing        -> pure $ Left f


-- | Whether the given HLS version is installed.
hlsInstalled :: (MonadIO m, MonadReader AppState m, MonadCatch m) => Version -> m Bool
hlsInstalled ver = do
  vers <- fmap rights getInstalledHLSs
  pure $ elem ver vers



-- Return the currently set hls version, if any.
hlsSet :: (MonadReader AppState m, MonadIO m, MonadThrow m, MonadCatch m) => m (Maybe Version)
hlsSet = do
  AppState {dirs = Dirs {..}} <- ask
  let hlsBin = binDir </> [rel|haskell-language-server-wrapper|]

  liftIO $ handleIO' NoSuchThing (\_ -> pure Nothing) $ do
    broken <- isBrokenSymlink hlsBin
    if broken
      then pure Nothing
      else do
        link <- readSymbolicLink $ toFilePath hlsBin
        Just <$> linkVersion link
 where
  linkVersion :: MonadThrow m => ByteString -> m Version
  linkVersion bs = do
    t <- throwEither $ E.decodeUtf8' bs
    throwEither $ MP.parse parser "" t
   where
    parser =
      MP.chunk "haskell-language-server-wrapper-" *> version'


-- | Return the GHC versions the currently selected HLS supports.
hlsGHCVersions :: ( MonadReader AppState m
                  , MonadIO m
                  , MonadThrow m
                  , MonadCatch m
                  )
               => m [Version]
hlsGHCVersions = do
  h                             <- hlsSet
  vers                          <- forM h $ \h' -> do
    bins <- hlsServerBinaries h'
    pure $ fmap
      (version
        . decUTF8Safe
        . fromJust
        . B.stripPrefix "haskell-language-server-"
        . head
        . B.split _tilde
        . toFilePath
      )
      bins
  pure . rights . concat . maybeToList $ vers


-- | Get all server binaries for an hls version, if any.
hlsServerBinaries :: (MonadReader AppState m, MonadIO m)
                  => Version
                  -> m [Path Rel]
hlsServerBinaries ver = do
  AppState { dirs = Dirs {..} } <- ask
  liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts
      compExtended
      execBlank
      ([s|^haskell-language-server-.*~|] <> escapeVerRex ver <> [s|$|] :: ByteString
      )
    )


-- | Get the wrapper binary for an hls version, if any.
hlsWrapperBinary :: (MonadReader AppState m, MonadThrow m, MonadIO m)
                 => Version
                 -> m (Maybe (Path Rel))
hlsWrapperBinary ver = do
  AppState { dirs = Dirs {..} } <- ask
  wrapper                       <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts
      compExtended
      execBlank
      ([s|^haskell-language-server-wrapper-|] <> escapeVerRex ver <> [s|$|] :: ByteString
      )
    )
  case wrapper of
    []  -> pure Nothing
    [x] -> pure $ Just x
    _   -> throwM $ UnexpectedListLength
      "There were multiple hls wrapper binaries for a single version"


-- | Get all binaries for an hls version, if any.
hlsAllBinaries :: (MonadReader AppState m, MonadIO m, MonadThrow m) => Version -> m [Path Rel]
hlsAllBinaries ver = do
  hls     <- hlsServerBinaries ver
  wrapper <- hlsWrapperBinary ver
  pure (maybeToList wrapper ++ hls)


-- | Get the active symlinks for hls.
hlsSymlinks :: (MonadReader AppState m, MonadIO m, MonadCatch m) => m [Path Rel]
hlsSymlinks = do
  AppState { dirs = Dirs {..} } <- ask
  oldSyms                       <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts compExtended
                   execBlank
                   ([s|^haskell-language-server-.*$|] :: ByteString)
    )
  filterM
    ( fmap (== SymbolicLink)
    . liftIO
    . getFileType
    . (binDir </>)
    )
    oldSyms



    -----------------------------------------
    --[ Major version introspection (X.Y) ]--
    -----------------------------------------


-- | Extract (major, minor) from any version.
getMajorMinorV :: MonadThrow m => Version -> m (Int, Int)
getMajorMinorV Version {..} = case _vChunks of
  ((Digits x :| []) :| ((Digits y :| []):_)) -> pure (fromIntegral x, fromIntegral y)
  _ -> throwM $ ParseError "Could not parse X.Y from version"


matchMajor :: Version -> Int -> Int -> Bool
matchMajor v' major' minor' = case getMajorMinorV v' of
  Just (x, y) -> x == major' && y == minor'
  Nothing     -> False


-- | Get the latest installed full GHC version that satisfies X.Y.
-- This reads `ghcupGHCBaseDir`.
getGHCForMajor :: (MonadReader AppState m, MonadIO m, MonadThrow m)
               => Int        -- ^ major version component
               -> Int        -- ^ minor version component
               -> Maybe Text -- ^ the target triple
               -> m (Maybe GHCTargetVersion)
getGHCForMajor major' minor' mt = do
  ghcs <- rights <$> getInstalledGHCs

  pure
    . lastMay
    . sortBy (\x y -> compare (_tvVersion x) (_tvVersion y))
    . filter
        (\GHCTargetVersion {..} ->
          _tvTarget == mt && matchMajor _tvVersion major' minor'
        )
    $ ghcs


-- | Get the latest available ghc for X.Y major version.
getLatestGHCFor :: Int -- ^ major version component
                -> Int -- ^ minor version component
                -> GHCupDownloads
                -> Maybe (Version, VersionInfo)
getLatestGHCFor major' minor' dls =
  preview (ix GHC % to Map.toDescList) dls >>= lastMay . filter (\(v, _) -> matchMajor v major' minor')




    -----------------
    --[ Unpacking ]--
    -----------------



-- | Unpack an archive to a temporary directory and return that path.
unpackToDir :: (MonadLogger m, MonadIO m, MonadThrow m)
            => Path Abs       -- ^ destination dir
            -> Path Abs       -- ^ archive path
            -> Excepts '[UnknownArchive
#if !defined(TAR)
                        , ArchiveResult
#endif
                        ] m ()
unpackToDir dest av = do
  fp <- decUTF8Safe . toFilePath <$> basename av
  let dfp = decUTF8Safe . toFilePath $ dest
  lift $ $(logInfo) [i|Unpacking: #{fp} to #{dfp}|]
  fn <- toFilePath <$> basename av

#if defined(TAR)
  let untar :: MonadIO m => BL.ByteString -> Excepts '[] m ()
      untar = liftIO . Tar.unpack (toFilePath dest) . Tar.read

      rf :: MonadIO m => Path Abs -> Excepts '[] m BL.ByteString
      rf = liftIO . readFile
#else
  let untar :: MonadIO m => BL.ByteString -> Excepts '[ArchiveResult] m ()
      untar = lEM . liftIO . runArchiveM . unpackToDirLazy (T.unpack . decUTF8Safe . toFilePath $ dest)

      rf :: MonadIO m => Path Abs -> Excepts '[ArchiveResult] m BL.ByteString
      rf = liftIO . readFile
#endif

  -- extract, depending on file extension
  if
    | ".tar.gz" `B.isSuffixOf` fn -> liftE
      (untar . GZip.decompress =<< rf av)
    | ".tar.xz" `B.isSuffixOf` fn -> do
      filecontents <- liftE $ rf av
      let decompressed = Lzma.decompress filecontents
      liftE $ untar decompressed
    | ".tar.bz2" `B.isSuffixOf` fn ->
      liftE (untar . BZip.decompress =<< rf av)
    | ".tar" `B.isSuffixOf` fn -> liftE (untar =<< rf av)
    | otherwise -> throwE $ UnknownArchive fn


getArchiveFiles :: (MonadLogger m, MonadIO m, MonadThrow m)
                => Path Abs       -- ^ archive path
                -> Excepts '[UnknownArchive
#if defined(TAR)
                            , Tar.FormatError
#else
                            , ArchiveResult
#endif
                            ] m [ByteString]
getArchiveFiles av = do
  fn <- toFilePath <$> basename av

#if defined(TAR)
  let entries :: Monad m => BL.ByteString -> Excepts '[Tar.FormatError] m [ByteString]
      entries =
          lE @Tar.FormatError
          . Tar.foldEntries
            (\e x -> fmap (Tar.entryPath e :) x)
            (Right [])
            (\e -> Left e)
          . Tar.read

      rf :: MonadIO m => Path Abs -> Excepts '[Tar.FormatError] m BL.ByteString
      rf = liftIO . readFile
#else
  let entries :: Monad m => BL.ByteString -> Excepts '[ArchiveResult] m [ByteString]
      entries = (fmap . fmap) (E.encodeUtf8 . T.pack . filepath) . lE . readArchiveBSL

      rf :: MonadIO m => Path Abs -> Excepts '[ArchiveResult] m BL.ByteString
      rf = liftIO . readFile
#endif

  -- extract, depending on file extension
  if
    | ".tar.gz" `B.isSuffixOf` fn -> liftE
      (entries . GZip.decompress =<< rf av)
    | ".tar.xz" `B.isSuffixOf` fn -> do
      filecontents <- liftE $ rf av
      let decompressed = Lzma.decompress filecontents
      liftE $ entries decompressed
    | ".tar.bz2" `B.isSuffixOf` fn ->
      liftE (entries . BZip.decompress =<< rf av)
    | ".tar" `B.isSuffixOf` fn -> liftE (entries =<< rf av)
    | otherwise -> throwE $ UnknownArchive fn


intoSubdir :: (MonadLogger m, MonadIO m, MonadThrow m, MonadCatch m)
           => Path Abs       -- ^ unpacked tar dir
           -> TarDir         -- ^ how to descend
           -> Excepts '[TarDirDoesNotExist] m (Path Abs)
intoSubdir bdir tardir = case tardir of
  RealDir pr -> do
    whenM (fmap not . liftIO . doesDirectoryExist $ (bdir </> pr))
          (throwE $ TarDirDoesNotExist tardir)
    pure (bdir </> pr)
  RegexDir r -> do
    let rs = splitOn "/" r
    foldlM
      (\y x ->
        (handleIO (\_ -> pure []) . liftIO . findFiles y . regex $ x) >>= (\case
          []      -> throwE $ TarDirDoesNotExist tardir
          (p : _) -> pure (y </> p)) . sort
      )
      bdir
      rs
    where regex = makeRegexOpts compIgnoreCase execBlank




    ------------
    --[ Tags ]--
    ------------


-- | Get the tool version that has this tag. If multiple have it,
-- picks the greatest version.
getTagged :: Tag
          -> AffineFold (Map.Map Version VersionInfo) (Version, VersionInfo)
getTagged tag =
  to (Map.filter (\VersionInfo {..} -> tag `elem` _viTags))
  % to Map.toDescList
  % _head

getLatest :: GHCupDownloads -> Tool -> Maybe (Version, VersionInfo)
getLatest av tool = headOf (ix tool % getTagged Latest) av

getRecommended :: GHCupDownloads -> Tool -> Maybe (Version, VersionInfo)
getRecommended av tool = headOf (ix tool % getTagged Recommended) av


-- | Gets the latest GHC with a given base version.
getLatestBaseVersion :: GHCupDownloads -> PVP -> Maybe (Version, VersionInfo)
getLatestBaseVersion av pvpVer =
  headOf (ix GHC % getTagged (Base pvpVer)) av



    -----------------------
    --[ AppState Getter ]--
    -----------------------


getCache :: MonadReader AppState m => m Bool
getCache = ask <&> cache . settings


getDownloader :: MonadReader AppState m => m Downloader
getDownloader = ask <&> downloader . settings



    -------------
    --[ Other ]--
    -------------


urlBaseName :: MonadThrow m
            => ByteString  -- ^ the url path (without scheme and host)
            -> m (Path Rel)
urlBaseName = parseRel . snd . B.breakEnd (== _slash) . urlDecode False


-- | Get tool files from @~\/.ghcup\/bin\/ghc\/\<ver\>\/bin\/\*@
-- while ignoring @*-\<ver\>@ symlinks and accounting for cross triple prefix.
--
-- Returns unversioned relative files, e.g.:
--
--   - @["hsc2hs","haddock","hpc","runhaskell","ghc","ghc-pkg","ghci","runghc","hp2ps"]@
ghcToolFiles :: (MonadReader AppState m, MonadThrow m, MonadFail m, MonadIO m)
             => GHCTargetVersion
             -> Excepts '[NotInstalled] m [Path Rel]
ghcToolFiles ver = do
  ghcdir <- lift $ ghcupGHCDir ver
  let bindir = ghcdir </> [rel|bin|]

  -- fail if ghc is not installed
  whenM (fmap not $ liftIO $ doesDirectoryExist ghcdir)
        (throwE (NotInstalled GHC ver))

  files    <- liftIO $ getDirsFiles' bindir
  -- figure out the <ver> suffix, because this might not be `Version` for
  -- alpha/rc releases, but x.y.a.somedate.

  -- for cross, this won't be "ghc", but e.g.
  -- "armv7-unknown-linux-gnueabihf-ghc"
  [ghcbin] <- liftIO $ findFiles
    bindir
    (makeRegexOpts compExtended
                   execBlank
                   ([s|^([a-zA-Z0-9_-]*[a-zA-Z0-9_]-)?ghc$|] :: ByteString)
    )

  let ghcbinPath = bindir </> ghcbin
  ghcIsHadrian    <- liftIO $ isHadrian ghcbinPath
  onlyUnversioned <- if ghcIsHadrian
    then pure id
    else do
      (Just symver) <-
        B.stripPrefix (toFilePath ghcbin <> "-") . takeFileName
          <$> liftIO (readSymbolicLink $ toFilePath ghcbinPath)
      when (B.null symver)
           (throwIO $ userError "Fatal: ghc symlink target is broken")
      pure $ filter (\x -> not $ symver `B.isSuffixOf` toFilePath x)

  pure $ onlyUnversioned files
 where
    -- GHC is moving some builds to Hadrian for bindists,
    -- which doesn't create versioned binaries.
    -- https://gitlab.haskell.org/haskell/ghcup-hs/issues/31
  isHadrian :: Path Abs -- ^ ghcbin path
            -> IO Bool
  isHadrian = fmap (/= SymbolicLink) . getFileType


-- | This file, when residing in @~\/.ghcup\/ghc\/\<ver\>\/@ signals that
-- this GHC was built from source. It contains the build config.
ghcUpSrcBuiltFile :: Path Rel
ghcUpSrcBuiltFile = [rel|.ghcup_src_built|]


-- | Calls gmake if it exists in PATH, otherwise make.
make :: (MonadThrow m, MonadIO m, MonadReader AppState m, MonadMask m)
     => [ByteString]
     -> Maybe (Path Abs)
     -> MVar Bool
     -> Seq ConsoleRegion
     -> m (Either ProcessError ())
make args workdir pState rs = do
  spaths    <- catMaybes . fmap parseAbs <$> liftIO getSearchPath
  has_gmake <- isJust <$> liftIO (searchPath spaths [rel|gmake|])
  let mymake = if has_gmake then "gmake" else "make"
  execLogged mymake True args [rel|ghc-make|] workdir Nothing pState rs

makeOut :: [ByteString]
        -> Maybe (Path Abs)
        -> IO CapturedProcess
makeOut args workdir = do
  spaths    <- catMaybes . fmap parseAbs <$> liftIO getSearchPath
  has_gmake <- isJust <$> liftIO (searchPath spaths [rel|gmake|])
  let mymake = if has_gmake then [rel|gmake|] else [rel|make|]
  liftIO $ executeOut mymake args workdir


-- | Try to apply patches in order. Fails with 'PatchFailed'
-- on first failure.
applyPatches :: (MonadLogger m, MonadIO m)
             => Path Abs   -- ^ dir containing patches
             -> Path Abs   -- ^ dir to apply patches in
             -> Excepts '[PatchFailed] m ()
applyPatches pdir ddir = do
  patches <- liftIO $ getDirsFiles pdir
  forM_ (sort patches) $ \patch' -> do
    lift $ $(logInfo) [i|Applying patch #{patch'}|]
    fmap (either (const Nothing) Just)
         (liftIO $ exec
           "patch"
           True
           ["-p1", "-i", toFilePath patch']
           (Just ddir)
           Nothing)
      !? PatchFailed


-- | https://gitlab.haskell.org/ghc/ghc/-/issues/17353
darwinNotarization :: Platform -> Path Abs -> IO (Either ProcessError ())
darwinNotarization Darwin path = exec
  "xattr"
  True
  ["-r", "-d", "com.apple.quarantine", toFilePath path]
  Nothing
  Nothing
darwinNotarization _ _ = pure $ Right ()


getChangeLog :: GHCupDownloads -> Tool -> Either Version Tag -> Maybe URI
getChangeLog dls tool (Left v') =
  preview (ix tool % ix v' % viChangeLog % _Just) dls
getChangeLog dls tool (Right tag) =
  preview (ix tool % getTagged tag % to snd % viChangeLog % _Just) dls


-- | Execute a build action while potentially cleaning up:
--
--   1. the build directory, depending on the KeepDirs setting
--   2. the install destination, depending on whether the build failed
runBuildAction :: (Show (V e), MonadReader AppState m, MonadIO m, MonadMask m)
               => Path Abs          -- ^ build directory (cleaned up depending on Settings)
               -> Maybe (Path Abs)  -- ^ dir to *always* clean up on exception
               -> Excepts e m a
               -> Excepts '[BuildFailed] m a
runBuildAction bdir instdir action = do
  AppState { settings = Settings {..} } <- lift ask
  let exAction = do
        forM_ instdir $ \dir ->
          liftIO $ hideError doesNotExistErrorType $ deleteDirRecursive dir
        when (keepDirs == Never)
          $ liftIO
          $ hideError doesNotExistErrorType
          $ deleteDirRecursive bdir
  v <-
    flip onException exAction
    $ catchAllE
        (\es -> do
          exAction
          throwE (BuildFailed bdir es)
        ) action

  when (keepDirs == Never || keepDirs == Errors) $ liftIO $ deleteDirRecursive
    bdir
  pure v


-- | More permissive version of 'createDirRecursive'. This doesn't
-- error when the destination is a symlink to a directory.
createDirRecursive' :: Path b -> IO ()
createDirRecursive' p =
  handleIO (\e -> if isAlreadyExistsError e then isSymlinkDir e else throwIO e)
    . createDirRecursive newDirPerms
    $ p

 where
  isSymlinkDir e = do
    ft <- getFileType p
    case ft of
      SymbolicLink -> do
        rp <- canonicalizePath p
        rft <- getFileType rp
        case rft of
          Directory -> pure ()
          _ -> throwIO e
      _ -> throwIO e


getVersionInfo :: Version
               -> Tool
               -> GHCupDownloads
               -> Maybe VersionInfo
getVersionInfo v' tool =
  headOf
    ( ix tool
    % to (Map.filterWithKey (\k _ -> k == v'))
    % to Map.elems
    % _head
    )


-- Gathering monoidal values
traverseFold :: (Foldable t, Applicative m, Monoid b) => (a -> m b) -> t a -> m b
traverseFold f = foldl (\mb a -> (<>) <$> mb <*> f a) (pure mempty)

-- | Gathering monoidal values
forFold :: (Foldable t, Applicative m, Monoid b) => t a -> (a -> m b) -> m b
forFold = \t -> (`traverseFold` t)


withConsoleRegions :: (MonadReader AppState m, MonadIO m, MonadMask m) => (MVar Bool -> Seq ConsoleRegion -> m a) -> m a
withConsoleRegions = withConsoleRegions' Linear 6


withConsoleRegions' :: (MonadReader AppState m, MonadIO m, MonadMask m) => RegionLayout -> Int -> (MVar Bool -> Seq ConsoleRegion -> m a) -> m a
withConsoleRegions' ly size action = do
  AppState { settings = Settings {..} } <- ask
  pState <- liftIO newEmptyMVar
  if (not verbose)
  then displayConsoleRegions $
          bracketIO
                (fmap Sq.fromList . sequence . replicate size . openConsoleRegion $ ly)
                (\rs -> uninterruptibleMask_ $ do
                  ps <- takeMVar pState
                  when ps (forM_ rs closeConsoleRegion))
                (action pState)
  else
    action pState mempty
  
 where
  bracketIO :: (MonadMask m, MonadIO m) => IO v -> (v -> IO b) -> (v -> m a) -> m a
  bracketIO setup cleanup' = bracket (liftIO setup) (liftIO . cleanup')
