{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ViewPatterns      #-}

module GHCup.System.Directory where

import           GHCup.Prelude

import           Control.Monad.Reader
import           Data.Maybe
import           Data.Text               ( Text )
import           Data.Void
import           GHC.IO.Exception
import           System.Directory
import           System.FilePath
import           Text.Regex.Posix

import qualified Data.Text                     as T
import qualified Text.Megaparsec               as MP






-- | Search for a file in the search paths.
--
-- Catches `PermissionDenied` and `NoSuchThing` and returns `Nothing`.
searchPath :: [FilePath] -> FilePath -> IO (Maybe FilePath)
searchPath paths needle = go paths
 where
  go [] = pure Nothing
  go (x : xs) =
    hideErrorDefM [InappropriateType, PermissionDenied, NoSuchThing] (go xs)
      $ do
          contents <- listDirectory x
          findM (isMatch x) contents >>= \case
            Just _ -> pure $ Just (x </> needle)
            Nothing -> go xs
  isMatch basedir p = do
    if p == needle
      then isExecutable (basedir </> needle)
      else pure False

  isExecutable :: FilePath -> IO Bool
  isExecutable file = executable <$> getPermissions file


-- | Check wether a binary is shadowed by another one that comes before
-- it in PATH. Returns the path to said binary, if any.
isShadowed :: FilePath -> IO (Maybe FilePath)
isShadowed p = do
  let dir = takeDirectory p
  let fn = takeFileName p
  spaths <- liftIO getSearchPath
  if dir `elem` spaths
  then do
    let shadowPaths = takeWhile (/= dir) spaths
    searchPath shadowPaths fn
  else pure Nothing


-- | Check whether the binary is in PATH. This returns only `True`
-- if the directory containing the binary is part of PATH.
isInPath :: FilePath -> IO Bool
isInPath p = do
  let dir = takeDirectory p
  let fn = takeFileName p
  spaths <- liftIO getSearchPath
  if dir `elem` spaths
  then isJust <$> searchPath [dir] fn
  else pure False


findFiles :: FilePath -> Regex -> IO [FilePath]
findFiles path regex = do
  contents <- listDirectory path
  pure $ filter (match regex) contents

findFilesDeep :: FilePath -> Regex -> IO [FilePath]
findFilesDeep path regex = do
  contents <- getDirectoryContentsRecursive path
  pure $ filter (match regex) contents

findFiles' :: FilePath -> MP.Parsec Void Text a -> IO [FilePath]
findFiles' path parser = do
  contents <- listDirectory path
  pure $ filter (\fp -> either (const False) (const True) $ MP.parse parser "" (T.pack fp)) contents


checkFileAlreadyExists :: (MonadIO m) => FilePath -> m Bool
checkFileAlreadyExists fp = liftIO $ doesFileExist fp
