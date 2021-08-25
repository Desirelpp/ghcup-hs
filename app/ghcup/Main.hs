{-# LANGUAGE CPP               #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}


module Main where

#if defined(BRICK)
import           BrickMain                    ( brickMain )
#endif

import           GHCup
import           GHCup.Download
import           GHCup.Errors
import           GHCup.Platform
import           GHCup.Requirements
import           GHCup.Types
import           GHCup.Types.Optics
import           GHCup.Utils
import           GHCup.Utils.File
import           GHCup.Utils.Logger
import           GHCup.Utils.MegaParsec
import           GHCup.Utils.Prelude
import           GHCup.Utils.String.QQ
import           GHCup.Version

import           Codec.Archive
import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.DeepSeq                ( force )
import           Control.Exception              ( evaluate )
import           Control.Exception.Safe
#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           Data.Bifunctor
import           Data.Char
import           Data.Either
import           Data.Functor
import           Data.List                      ( intercalate, nub, sort, sortBy )
import           Data.List.NonEmpty             (NonEmpty ((:|)))
import           Data.Maybe
import           Data.Text                      ( Text )
import           Data.Versions           hiding ( str )
import           Data.Void
import           GHC.IO.Encoding
import           Haskus.Utils.Variant.Excepts
import           Language.Haskell.TH
import           Options.Applicative     hiding ( style )
import           Options.Applicative.Help.Pretty ( text )
import           Prelude                 hiding ( appendFile )
import           Safe
import           System.Console.Pretty   hiding ( color )
import qualified System.Console.Pretty         as Pretty
import           System.Environment
import           System.Exit
import           System.FilePath
import           System.IO               hiding ( appendFile )
import           Text.Read               hiding ( lift )
import           Text.PrettyPrint.HughesPJClass ( prettyShow )
import           URI.ByteString

import qualified Data.ByteString               as B
import qualified Data.ByteString.UTF8          as UTF8
import qualified Data.Map.Strict               as M
import qualified Data.Text                     as T
import qualified Data.Text.IO                  as T
import qualified Data.Text.Encoding            as E
import qualified Data.Yaml                     as Y
import qualified Data.Yaml.Pretty              as YP
import qualified Text.Megaparsec               as MP
import qualified Text.Megaparsec.Char          as MPC



data Options = Options
  {
  -- global options
    optVerbose   :: Maybe Bool
  , optCache     :: Maybe Bool
  , optUrlSource :: Maybe URI
  , optNoVerify  :: Maybe Bool
  , optKeepDirs  :: Maybe KeepDirs
  , optsDownloader :: Maybe Downloader
  , optNoNetwork :: Maybe Bool
  -- commands
  , optCommand   :: Command
  }

data Command
  = Install (Either InstallCommand InstallOptions)
  | InstallCabalLegacy InstallOptions
  | Set (Either SetCommand SetOptions)
  | List ListOptions
  | Rm (Either RmCommand RmOptions)
  | DInfo
  | Compile CompileCommand
  | Config ConfigCommand
  | Whereis WhereisOptions WhereisCommand
  | Upgrade UpgradeOpts Bool
  | ToolRequirements
  | ChangeLog ChangeLogOptions
  | Nuke
#if defined(BRICK)
  | Interactive
#endif
  | Prefetch PrefetchCommand

data ToolVersion = ToolVersion GHCTargetVersion -- target is ignored for cabal
                 | ToolTag Tag

prettyToolVer :: ToolVersion -> String
prettyToolVer (ToolVersion v') = T.unpack $ tVerToText v'
prettyToolVer (ToolTag t) = show t

toSetToolVer :: Maybe ToolVersion -> SetToolVersion
toSetToolVer (Just (ToolVersion v')) = SetToolVersion v'
toSetToolVer (Just (ToolTag t')) = SetToolTag t'
toSetToolVer Nothing = SetRecommended


data InstallCommand = InstallGHC InstallOptions
                    | InstallCabal InstallOptions
                    | InstallHLS InstallOptions
                    | InstallStack InstallOptions

data InstallOptions = InstallOptions
  { instVer      :: Maybe ToolVersion
  , instPlatform :: Maybe PlatformRequest
  , instBindist  :: Maybe URI
  , instSet      :: Bool
  , isolateDir   :: Maybe FilePath
  }

data SetCommand = SetGHC SetOptions
                | SetCabal SetOptions
                | SetHLS SetOptions
                | SetStack SetOptions

-- a superset of ToolVersion
data SetToolVersion = SetToolVersion GHCTargetVersion
                    | SetToolTag Tag
                    | SetRecommended
                    | SetNext

data SetOptions = SetOptions
  { sToolVer :: SetToolVersion
  }

data ListOptions = ListOptions
  { loTool     :: Maybe Tool
  , lCriteria  :: Maybe ListCriteria
  , lRawFormat :: Bool
  }

data RmCommand = RmGHC RmOptions
               | RmCabal Version
               | RmHLS Version
               | RmStack Version

data RmOptions = RmOptions
  { ghcVer :: GHCTargetVersion
  }


data CompileCommand = CompileGHC GHCCompileOptions

data ConfigCommand = ShowConfig | SetConfig String String | InitConfig

data GHCCompileOptions = GHCCompileOptions
  { targetGhc    :: Either Version GitBranch
  , bootstrapGhc :: Either Version FilePath
  , jobs         :: Maybe Int
  , buildConfig  :: Maybe FilePath
  , patchDir     :: Maybe FilePath
  , crossTarget  :: Maybe Text
  , addConfArgs  :: [Text]
  , setCompile   :: Bool
  , ovewrwiteVer :: Maybe Version
  , buildFlavour :: Maybe String
  , hadrian      :: Bool
  , isolateDir   :: Maybe FilePath
  }

data UpgradeOpts = UpgradeInplace
                 | UpgradeAt FilePath
                 | UpgradeGHCupDir
                 deriving Show

data ChangeLogOptions = ChangeLogOptions
  { clOpen    :: Bool
  , clTool    :: Maybe Tool
  , clToolVer :: Maybe ToolVersion
  }


data WhereisCommand = WhereisTool Tool (Maybe ToolVersion)

data WhereisOptions = WhereisOptions {
   directory :: Bool
}

data PrefetchOptions = PrefetchOptions {
  pfCacheDir :: Maybe FilePath
}

data PrefetchCommand = PrefetchGHC PrefetchGHCOptions (Maybe ToolVersion)
                     | PrefetchCabal PrefetchOptions (Maybe ToolVersion)
                     | PrefetchHLS PrefetchOptions (Maybe ToolVersion)
                     | PrefetchStack PrefetchOptions (Maybe ToolVersion)
                     | PrefetchMetadata

data PrefetchGHCOptions = PrefetchGHCOptions {
    pfGHCSrc :: Bool
  , pfGHCCacheDir :: Maybe FilePath
}


-- https://github.com/pcapriotti/optparse-applicative/issues/148

-- | A switch that can be enabled using --foo and disabled using --no-foo.
--
-- The option modifier is applied to only the option that is *not* enabled
-- by default. For example:
--
-- > invertableSwitch "recursive" True (help "do not recurse into directories")
--
-- This example makes --recursive enabled by default, so
-- the help is shown only for --no-recursive.
invertableSwitch
    :: String              -- ^ long option
    -> Char                -- ^ short option for the non-default option
    -> Bool                -- ^ is switch enabled by default?
    -> Mod FlagFields Bool -- ^ option modifier
    -> Parser (Maybe Bool)
invertableSwitch longopt shortopt defv optmod = invertableSwitch' longopt shortopt defv
    (if defv then mempty else optmod)
    (if defv then optmod else mempty)

-- | Allows providing option modifiers for both --foo and --no-foo.
invertableSwitch'
    :: String              -- ^ long option (eg "foo")
    -> Char                -- ^ short option for the non-default option
    -> Bool                -- ^ is switch enabled by default?
    -> Mod FlagFields Bool -- ^ option modifier for --foo
    -> Mod FlagFields Bool -- ^ option modifier for --no-foo
    -> Parser (Maybe Bool)
invertableSwitch' longopt shortopt defv enmod dismod = optional
    ( flag' True ( enmod <> long longopt <> if defv then mempty else short shortopt)
    <|> flag' False (dismod <> long nolongopt <> if defv then short shortopt else mempty)
    )
  where
    nolongopt = "no-" ++ longopt


opts :: Parser Options
opts =
  Options
    <$> invertableSwitch "verbose" 'v' False (help "Enable verbosity (default: disabled)")
    <*> invertableSwitch "cache" 'c' False (help "Cache downloads in ~/.ghcup/cache (default: disabled)")
    <*> (optional
          (option
            (eitherReader parseUri)
            (  short 's'
            <> long "url-source"
            <> metavar "URL"
            <> help "Alternative ghcup download info url"
            <> internal
            )
          )
        )
    <*> (fmap . fmap) not (invertableSwitch "verify" 'n' True (help "Disable tarball checksum verification (default: enabled)"))
    <*> optional (option
          (eitherReader keepOnParser)
          (  long "keep"
          <> metavar "<always|errors|never>"
          <> help
               "Keep build directories? (default: errors)"
          <> hidden
          ))
    <*> optional (option
          (eitherReader downloaderParser)
          (  long "downloader"
#if defined(INTERNAL_DOWNLOADER)
          <> metavar "<internal|curl|wget>"
          <> help
          "Downloader to use (default: internal)"
#else
          <> metavar "<curl|wget>"
          <> help
          "Downloader to use (default: curl)"
#endif
          <> hidden
          ))
    <*> invertableSwitch "offline" 'o' False (help "Don't do any network calls, trying cached assets and failing if missing.")
    <*> com
 where
  parseUri s' =
    first show $ parseURI strictURIParserOptions (UTF8.fromString s')


com :: Parser Command
com =
  subparser
#if defined(BRICK)
      (  command
          "tui"
          (   (\_ -> Interactive)
          <$> (info
                helper
                (  progDesc "Start the interactive GHCup UI"
                )
              )
          )
      <>  command
#else
      (  command
#endif
          "install"
          (   Install
          <$> info
                (installParser <**> helper)
                (  progDesc "Install or update GHC/cabal/HLS"
                <> footerDoc (Just $ text installToolFooter)
                )
          )
      <> command
           "set"
           (info
             (Set <$> setParser <**> helper)
             (  progDesc "Set currently active GHC/cabal version"
             <> footerDoc (Just $ text setFooter)
             )
           )
      <> command
           "rm"
           (info
             (Rm <$> rmParser <**> helper)
             (  progDesc "Remove a GHC/cabal/HLS version"
             <> footerDoc (Just $ text rmFooter)
             )
           )

      <> command
           "list"
           (info (List <$> listOpts <**> helper)
                 (progDesc "Show available GHCs and other tools")
           )
      <> command
           "upgrade"
           (info
             (    (Upgrade <$> upgradeOptsP <*> switch
                    (short 'f' <> long "force" <> help "Force update")
                  )
             <**> helper
             )
             (progDesc "Upgrade ghcup")
           )
      <> command
           "compile"
           (   Compile
           <$> info (compileP <**> helper)
                    (progDesc "Compile a tool from source")
           )
      <> command
           "whereis"
            (info
             (   (Whereis
                     <$> (WhereisOptions <$> switch (short 'd' <> long "directory" <> help "return directory of the binary instead of the binary location"))
                     <*> whereisP
                 ) <**> helper
             )
             (progDesc "Find a tools location"
             <> footerDoc ( Just $ text whereisFooter ))
           )
      <> command
           "prefetch"
            (info
             (   (Prefetch
                     <$> prefetchP
                 ) <**> helper
             )
             (progDesc "Prefetch assets"
             <> footerDoc ( Just $ text prefetchFooter ))
           )
      <> commandGroup "Main commands:"
      )
    <|> subparser
          (  command
              "debug-info"
              ((\_ -> DInfo) <$> info helper (progDesc "Show debug info"))
          <> command
               "tool-requirements"
               (   (\_ -> ToolRequirements)
               <$> info helper
                        (progDesc "Show the requirements for ghc/cabal")
               )
          <> command
               "changelog"
               (info
                  (fmap ChangeLog changelogP <**> helper)
                  (  progDesc "Find/show changelog"
                  <> footerDoc (Just $ text changeLogFooter)
                  )
               )
          <> command
               "config"
               (   Config
               <$> info (configP <**> helper)
                        (progDesc "Show or set config" <> footerDoc (Just $ text configFooter))
               )
          <> commandGroup "Other commands:"
          <> hidden
          )
    <|> subparser
          (  command
              "install-cabal"
              (info
                 ((InstallCabalLegacy <$> installOpts (Just Cabal)) <**> helper)
                 (  progDesc "Install or update cabal"
                 <> footerDoc (Just $ text installCabalFooter)
                 )
              )
          <> internal
          )
     <|> subparser
          (command
              "nuke"
               (info (pure Nuke <**> helper)
                     (progDesc "Completely remove ghcup from your system"))
           <> commandGroup "Nuclear Commands:"
          )

 where
  installToolFooter :: String
  installToolFooter = [s|Discussion:
  Installs GHC or cabal. When no command is given, installs GHC
  with the specified version/tag.
  It is recommended to always specify a subcommand (ghc/cabal/hls).|]

  setFooter :: String
  setFooter = [s|Discussion:
  Sets the currently active GHC or cabal version. When no command is given,
  defaults to setting GHC with the specified version/tag (if no tag
  is given, sets GHC to 'recommended' version).
  It is recommended to always specify a subcommand (ghc/cabal/hls).|]

  rmFooter :: String
  rmFooter = [s|Discussion:
  Remove the given GHC or cabal version. When no command is given,
  defaults to removing GHC with the specified version.
  It is recommended to always specify a subcommand (ghc/cabal/hls).|]

  changeLogFooter :: String
  changeLogFooter = [s|Discussion:
  By default returns the URI of the ChangeLog of the latest GHC release.
  Pass '-o' to automatically open via xdg-open.|]

  whereisFooter :: String
  whereisFooter = [s|Discussion:
  Finds the location of a tool. For GHC, this is the ghc binary, that
  usually resides in a self-contained "~/.ghcup/ghc/<ghcver>" directory.
  For cabal/stack/hls this the binary usually at "~/.ghcup/bin/<tool>-<ver>".

Examples:
  # outputs ~/.ghcup/ghc/8.10.5/bin/ghc.exe
  ghcup whereis ghc 8.10.5
  # outputs ~/.ghcup/ghc/8.10.5/bin/
  ghcup whereis --directory ghc 8.10.5
  # outputs ~/.ghcup/bin/cabal-3.4.0.0
  ghcup whereis cabal 3.4.0.0
  # outputs ~/.ghcup/bin/
  ghcup whereis --directory cabal 3.4.0.0|]

  prefetchFooter :: String
  prefetchFooter = [s|Discussion:
  Prefetches tools or assets into "~/.ghcup/cache" directory. This can
  be then combined later with '--offline' flag, ensuring all assets that
  are required for offline use have been prefetched.

Examples:
  ghcup prefetch metadata
  ghcup prefetch ghc 8.10.5
  ghcup --offline install ghc 8.10.5|]

configFooter :: String
configFooter = [s|Examples:

# show current config
ghcup config

# initialize config
ghcup config init

# set <key> <value> configuration pair
ghcup config <key> <value>|]

installCabalFooter :: String
installCabalFooter = [s|Discussion:
  Installs the specified cabal-install version (or a recommended default one)
  into "~/.ghcup/bin", so it can be overwritten by later
  "cabal install cabal-install", which installs into "~/.cabal/bin" by
  default. Make sure to set up your PATH appropriately, so the cabal
  installation takes precedence.|]


installParser :: Parser (Either InstallCommand InstallOptions)
installParser =
  (Left <$> subparser
      (  command
          "ghc"
          (   InstallGHC
          <$> info
                (installOpts (Just GHC) <**> helper)
                (  progDesc "Install GHC"
                <> footerDoc (Just $ text installGHCFooter)
                )
          )
      <> command
           "cabal"
           (   InstallCabal
           <$> info
                 (installOpts (Just Cabal) <**> helper)
                 (  progDesc "Install Cabal"
                 <> footerDoc (Just $ text installCabalFooter)
                 )
           )
      <> command
           "hls"
           (   InstallHLS
           <$> info
                 (installOpts (Just HLS) <**> helper)
                 (  progDesc "Install haskell-languge-server"
                 <> footerDoc (Just $ text installHLSFooter)
                 )
           )
      <> command
           "stack"
           (   InstallStack
           <$> info
                 (installOpts (Just Stack) <**> helper)
                 (  progDesc "Install stack"
                 <> footerDoc (Just $ text installStackFooter)
                 )
           )
      )
    )
    <|> (Right <$> installOpts Nothing)
 where
  installHLSFooter :: String
  installHLSFooter = [s|Discussion:
  Installs haskell-language-server binaries and wrapper
  into "~/.ghcup/bin"

Examples:
  # install recommended HLS
  ghcup install hls|]

  installStackFooter :: String
  installStackFooter = [s|Discussion:
  Installs stack binaries into "~/.ghcup/bin"

Examples:
  # install recommended Stack
  ghcup install stack|]

  installGHCFooter :: String
  installGHCFooter = [s|Discussion:
  Installs the specified GHC version (or a recommended default one) into
  a self-contained "~/.ghcup/ghc/<ghcver>" directory
  and symlinks the ghc binaries to "~/.ghcup/bin/<binary>-<ghcver>".

Examples:
  # install recommended GHC
  ghcup install ghc

  # install latest GHC
  ghcup install ghc latest

  # install GHC 8.10.2
  ghcup install ghc 8.10.2

  # install GHC head fedora bindist
  ghcup install ghc -u https://gitlab.haskell.org/api/v4/projects/1/jobs/artifacts/master/raw/ghc-x86_64-fedora27-linux.tar.xz?job=validate-x86_64-linux-fedora27 head|]


installOpts :: Maybe Tool -> Parser InstallOptions
installOpts tool =
  (\p (u, v) b is -> InstallOptions v p u b is)
    <$> optional
          (option
            (eitherReader platformParser)
            (  short 'p'
            <> long "platform"
            <> metavar "PLATFORM"
            <> help
                 "Override for platform (triple matching ghc tarball names), e.g. x86_64-fedora27-linux"
            )
          )
    <*> (   (   (,)
            <$> optional
                  (option
                    (eitherReader bindistParser)
                    (short 'u' <> long "url" <> metavar "BINDIST_URL" <> help
                      "Install the specified version from this bindist"
                    )
                  )
            <*> (Just <$> toolVersionArgument Nothing tool)
            )
        <|> pure (Nothing, Nothing)
        )
    <*> flag
          False
          True
          (long "set" <> help
            "Set as active version after install"
          )
    <*> optional
          (option
           (eitherReader isolateParser)
           (  short 'i'
           <> long "isolate"
           <> metavar "DIR"
           <> help "install in an isolated dir instead of the default one"
           )
          )


setParser :: Parser (Either SetCommand SetOptions)
setParser =
  (Left <$> subparser
      (  command
          "ghc"
          (   SetGHC
          <$> info
                (setOpts (Just GHC) <**> helper)
                (  progDesc "Set GHC version"
                <> footerDoc (Just $ text setGHCFooter)
                )
          )
      <> command
           "cabal"
           (   SetCabal
           <$> info
                 (setOpts (Just Cabal) <**> helper)
                 (  progDesc "Set Cabal version"
                 <> footerDoc (Just $ text setCabalFooter)
                 )
           )
      <> command
           "hls"
           (   SetHLS
           <$> info
                 (setOpts (Just HLS) <**> helper)
                 (  progDesc "Set haskell-language-server version"
                 <> footerDoc (Just $ text setHLSFooter)
                 )
           )
      <> command
           "stack"
           (   SetStack
           <$> info
                 (setOpts (Just Stack) <**> helper)
                 (  progDesc "Set stack version"
                 <> footerDoc (Just $ text setStackFooter)
                 )
           )
      )
    )
    <|> (Right <$> setOpts Nothing)
 where
  setGHCFooter :: String
  setGHCFooter = [s|Discussion:
    Sets the the current GHC version by creating non-versioned
    symlinks for all ghc binaries of the specified version in
    "~/.ghcup/bin/<binary>".|]

  setCabalFooter :: String
  setCabalFooter = [s|Discussion:
    Sets the the current Cabal version.|]

  setStackFooter :: String
  setStackFooter = [s|Discussion:
    Sets the the current Stack version.|]

  setHLSFooter :: String
  setHLSFooter = [s|Discussion:
    Sets the the current haskell-language-server version.|]


setOpts :: Maybe Tool -> Parser SetOptions
setOpts tool = SetOptions <$>
    (fromMaybe SetRecommended <$>
      optional (setVersionArgument (Just ListInstalled) tool))

listOpts :: Parser ListOptions
listOpts =
  ListOptions
    <$> optional
          (option
            (eitherReader toolParser)
            (short 't' <> long "tool" <> metavar "<ghc|cabal>" <> help
              "Tool to list versions for. Default is all"
            )
          )
    <*> optional
          (option
            (eitherReader criteriaParser)
            (  short 'c'
            <> long "show-criteria"
            <> metavar "<installed|set>"
            <> help "Show only installed or set tool versions"
            )
          )
    <*> switch
          (short 'r' <> long "raw-format" <> help "More machine-parsable format"
          )


rmParser :: Parser (Either RmCommand RmOptions)
rmParser =
  (Left <$> subparser
      (  command
          "ghc"
          (RmGHC <$> info (rmOpts (Just GHC) <**> helper) (progDesc "Remove GHC version"))
      <> command
           "cabal"
           (   RmCabal
           <$> info (versionParser' (Just ListInstalled) (Just Cabal) <**> helper)
                    (progDesc "Remove Cabal version")
           )
      <> command
           "hls"
           (   RmHLS
           <$> info (versionParser' (Just ListInstalled) (Just HLS) <**> helper)
                    (progDesc "Remove haskell-language-server version")
           )
      <> command
           "stack"
           (   RmStack
           <$> info (versionParser' (Just ListInstalled) (Just Stack) <**> helper)
                    (progDesc "Remove stack version")
           )
      )
    )
    <|> (Right <$> rmOpts Nothing)



rmOpts :: Maybe Tool -> Parser RmOptions
rmOpts tool = RmOptions <$> versionArgument (Just ListInstalled) tool


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

compileP :: Parser CompileCommand
compileP = subparser
  (  command
      "ghc"
      (   CompileGHC
      <$> info
            (ghcCompileOpts <**> helper)
            (  progDesc "Compile GHC from source"
            <> footerDoc (Just $ text compileFooter)
            )
      )
  )
 where
  compileFooter = [s|Discussion:
  Compiles and installs the specified GHC version into
  a self-contained "~/.ghcup/ghc/<ghcver>" directory
  and symlinks the ghc binaries to "~/.ghcup/bin/<binary>-<ghcver>".

  This also allows building a cross-compiler. Consult the documentation
  first: <https://gitlab.haskell.org/ghc/ghc/-/wikis/building/cross-compiling#configuring-the-build>

ENV variables:
  Various toolchain variables will be passed onto the ghc build system,
  such as: CC, LD, OBJDUMP, NM, AR, RANLIB.

Examples:
  # compile from known version
  ghcup compile ghc -j 4 -v 8.4.2 -b 8.2.2
  # compile from git commit/reference
  ghcup compile ghc -j 4 -g master -b 8.2.2
  # specify path to bootstrap ghc
  ghcup compile ghc -j 4 -v 8.4.2 -b /usr/bin/ghc-8.2.2
  # build cross compiler
  ghcup compile ghc -j 4 -v 8.4.2 -b 8.2.2 -x armv7-unknown-linux-gnueabihf --config $(pwd)/build.mk -- --enable-unregisterised|]

configP :: Parser ConfigCommand
configP = subparser
      (  command "init" initP
      <> command "set"  setP -- [set] KEY VALUE at help lhs
      <> command "show" showP
      )
    <|> argsP -- add show for a single option
    <|> pure ShowConfig
 where
  initP = info (pure InitConfig) (progDesc "Write default config to ~/.ghcup/config.yaml")
  showP = info (pure ShowConfig) (progDesc "Show current config (default)")
  setP  = info argsP (progDesc "Set config KEY to VALUE")
  argsP = SetConfig <$> argument str (metavar "KEY") <*> argument str (metavar "VALUE")

whereisP :: Parser WhereisCommand
whereisP = subparser
  (  command
      "ghc"
      (WhereisTool GHC <$> info
        ( optional (toolVersionArgument Nothing (Just GHC)) <**> helper )
        ( progDesc "Get GHC location"
        <> footerDoc (Just $ text whereisGHCFooter ))
      )
      <>
     command
      "cabal"
      (WhereisTool Cabal <$> info
        ( optional (toolVersionArgument Nothing (Just Cabal)) <**> helper )
        ( progDesc "Get cabal location"
        <> footerDoc (Just $ text whereisCabalFooter ))
      )
      <>
     command
      "hls"
      (WhereisTool HLS <$> info
        ( optional (toolVersionArgument Nothing (Just HLS)) <**> helper )
        ( progDesc "Get HLS location"
        <> footerDoc (Just $ text whereisHLSFooter ))
      )
      <>
     command
      "stack"
      (WhereisTool Stack <$> info
        ( optional (toolVersionArgument Nothing (Just Stack)) <**> helper )
        ( progDesc "Get stack location"
        <> footerDoc (Just $ text whereisStackFooter ))
      )
      <>
     command
      "ghcup"
      (WhereisTool GHCup <$> info ( (pure Nothing) <**> helper ) ( progDesc "Get ghcup location" ))
  )
 where
  whereisGHCFooter = [s|Discussion:
  Finds the location of a GHC executable, which usually resides in
  a self-contained "~/.ghcup/ghc/<ghcver>" directory.

Examples:
  # outputs ~/.ghcup/ghc/8.10.5/bin/ghc.exe
  ghcup whereis ghc 8.10.5
  # outputs ~/.ghcup/ghc/8.10.5/bin/
  ghcup whereis --directory ghc 8.10.5 |]

  whereisCabalFooter = [s|Discussion:
  Finds the location of a Cabal executable, which usually resides in
  "~/.ghcup/bin/".

Examples:
  # outputs ~/.ghcup/bin/cabal-3.4.0.0
  ghcup whereis cabal 3.4.0.0
  # outputs ~/.ghcup/bin
  ghcup whereis --directory cabal 3.4.0.0|]

  whereisHLSFooter = [s|Discussion:
  Finds the location of a HLS executable, which usually resides in
  "~/.ghcup/bin/".

Examples:
  # outputs ~/.ghcup/bin/haskell-language-server-wrapper-1.2.0
  ghcup whereis hls 1.2.0
  # outputs ~/.ghcup/bin/
  ghcup whereis --directory hls 1.2.0|]

  whereisStackFooter = [s|Discussion:
  Finds the location of a stack executable, which usually resides in
  "~/.ghcup/bin/".

Examples:
  # outputs ~/.ghcup/bin/stack-2.7.1
  ghcup whereis stack 2.7.1
  # outputs ~/.ghcup/bin/
  ghcup whereis --directory stack 2.7.1|]


prefetchP :: Parser PrefetchCommand
prefetchP = subparser
  (  command
      "ghc"
      (info 
        (PrefetchGHC
          <$> (PrefetchGHCOptions
                <$> ( switch (short 's' <> long "source" <> help "Download source tarball instead of bindist") <**> helper )
                <*> optional (option str (short 'd' <> long "directory" <> help "directory to download into (default: ~/.ghcup/cache/)")))
          <*> ( optional (toolVersionArgument Nothing (Just GHC)) ))
        ( progDesc "Download GHC assets for installation")
      )
      <>
     command
      "cabal"
      (info 
        (PrefetchCabal
          <$> fmap PrefetchOptions (optional (option str (short 'd' <> long "directory" <> help "directory to download into (default: ~/.ghcup/cache/)")))
          <*> ( optional (toolVersionArgument Nothing (Just Cabal)) <**> helper ))
        ( progDesc "Download cabal assets for installation")
      )
      <>
     command
      "hls"
      (info 
        (PrefetchHLS
          <$> fmap PrefetchOptions (optional (option str (short 'd' <> long "directory" <> help "directory to download into (default: ~/.ghcup/cache/)")))
          <*> ( optional (toolVersionArgument Nothing (Just HLS)) <**> helper ))
        ( progDesc "Download HLS assets for installation")
      )
      <>
     command
      "stack"
      (info 
        (PrefetchStack
          <$> fmap PrefetchOptions (optional (option str (short 'd' <> long "directory" <> help "directory to download into (default: ~/.ghcup/cache/)")))
          <*> ( optional (toolVersionArgument Nothing (Just Stack)) <**> helper ))
        ( progDesc "Download stack assets for installation")
      )
      <>
     command
      "metadata"
      (const PrefetchMetadata <$> info
        helper
        ( progDesc "Download ghcup's metadata, needed for various operations")
      )
  )


ghcCompileOpts :: Parser GHCCompileOptions
ghcCompileOpts =
  GHCCompileOptions
    <$> ((Left <$> option
          (eitherReader
            (first (const "Not a valid version") . version . T.pack)
          )
          (short 'v' <> long "version" <> metavar "VERSION" <> help
            "The tool version to compile"
          )
          ) <|>
          (Right <$> (GitBranch <$> option
          str
          (short 'g' <> long "git-ref" <> metavar "GIT_REFERENCE" <> help
            "The git commit/branch/ref to build from"
          ) <*>
          optional (option str (short 'r' <> long "repository" <> metavar "GIT_REPOSITORY" <> help "The git repository to build from (defaults to GHC upstream)"))
          )))
    <*> option
          (eitherReader
            (\x ->
              (bimap (const "Not a valid version") Left . version . T.pack $ x) <|> (if isPathSeparator (head x) then pure $ Right x else Left "Not an absolute Path")
            )
          )
          (  short 'b'
          <> long "bootstrap-ghc"
          <> metavar "BOOTSTRAP_GHC"
          <> help
               "The GHC version (or full path) to bootstrap with (must be installed)"
          )
    <*> optional
          (option
            (eitherReader (readEither @Int))
            (short 'j' <> long "jobs" <> metavar "JOBS" <> help
              "How many jobs to use for make"
            )
          )
    <*> optional
          (option
            str
            (short 'c' <> long "config" <> metavar "CONFIG" <> help
              "Absolute path to build config file"
            )
          )
    <*> optional
          (option
            str
            (short 'p' <> long "patchdir" <> metavar "PATCH_DIR" <> help
              "Absolute path to patch directory (applied in order, uses -p1)"
            )
          )
    <*> optional
          (option
            str
            (short 'x' <> long "cross-target" <> metavar "CROSS_TARGET" <> help
              "Build cross-compiler for this platform"
            )
          )
    <*> many (argument str (metavar "CONFIGURE_ARGS" <> help "Additional arguments to configure, prefix with '-- ' (longopts)"))
    <*> flag
          False
          True
          (long "set" <> help
            "Set as active version after install"
          )
    <*> optional
          (option
            (eitherReader
              (first (const "Not a valid version") . version . T.pack)
            )
            (short 'o' <> long "overwrite-version" <> metavar "OVERWRITE_VERSION" <> help
              "Allows to overwrite the finally installed VERSION with a different one, e.g. when you build 8.10.4 with your own patches, you might want to set this to '8.10.4-p1'"
            )
          )
    <*> optional
          (option
            str
            (short 'f' <> long "flavour" <> metavar "BUILD_FLAVOUR" <> help
              "Set the compile build flavour (this value depends on the build system type: 'make' vs 'hadrian')"
            )
          )
    <*> switch
          (long "hadrian" <> help "Use the hadrian build system instead of make (only git versions seem to be properly supported atm)"
          )
    <*> optional
          (option
            (eitherReader isolateParser)
            (  short 'i'
            <> long "isolate"
            <> metavar "DIR"
            <> help "install in an isolated directory instead of the default one, no symlinks to this installation will be made"
            )
           )


toolVersionParser :: Parser ToolVersion
toolVersionParser = verP' <|> toolP
 where
  verP' = ToolVersion <$> versionParser
  toolP =
    ToolTag
      <$> option
            (eitherReader tagEither)
            (short 't' <> long "tag" <> metavar "TAG" <> help "The target tag")

-- | same as toolVersionParser, except as an argument.
toolVersionArgument :: Maybe ListCriteria -> Maybe Tool -> Parser ToolVersion
toolVersionArgument criteria tool =
  argument (eitherReader toolVersionEither)
    (metavar "VERSION|TAG"
    <> completer (tagCompleter (fromMaybe GHC tool) [])
    <> foldMap (completer . versionCompleter criteria) tool)


setVersionArgument :: Maybe ListCriteria -> Maybe Tool -> Parser SetToolVersion
setVersionArgument criteria tool =
  argument (eitherReader setEither)
    (metavar "VERSION|TAG|next"
    <> completer (tagCompleter (fromMaybe GHC tool) ["next"])
    <> foldMap (completer . versionCompleter criteria) tool)
 where
  setEither s' =
        parseSet s'
    <|> second SetToolTag (tagEither s')
    <|> second SetToolVersion (tVersionEither s')
  parseSet s' = case fmap toLower s' of
                  "next" -> Right SetNext
                  other  -> Left $ "Unknown tag/version " <> other


versionArgument :: Maybe ListCriteria -> Maybe Tool -> Parser GHCTargetVersion
versionArgument criteria tool = argument (eitherReader tVersionEither) (metavar "VERSION" <> foldMap (completer . versionCompleter criteria) tool)


tagCompleter :: Tool -> [String] -> Completer
tagCompleter tool add = listIOCompleter $ do
  dirs' <- liftIO getAllDirs
  let appState = LeanAppState
        (Settings True False Never Curl False GHCupURL True)
        dirs'
        defaultKeyBindings

  let loggerConfig = LoggerConfig
        { lcPrintDebug = False
        , colorOutter  = mempty
        , rawOutter    = mempty
        }
  let runLogger = myLoggerT loggerConfig

  mGhcUpInfo <- runLogger . flip runReaderT appState . runE $ getDownloadsF
  case mGhcUpInfo of
    VRight ghcupInfo -> do
      let allTags = filter (\t -> t /= Old)
            $ join
            $ fmap _viTags
            $ M.elems
            $ availableToolVersions (_ghcupDownloads ghcupInfo) tool
      pure $ nub $ (add ++) $ fmap tagToString allTags
    VLeft _ -> pure  (nub $ ["recommended", "latest"] ++ add)


versionCompleter :: Maybe ListCriteria -> Tool -> Completer
versionCompleter criteria tool = listIOCompleter $ do
  dirs' <- liftIO getAllDirs
  let loggerConfig = LoggerConfig
        { lcPrintDebug = False
        , colorOutter  = mempty
        , rawOutter    = mempty
        }
  let runLogger = myLoggerT loggerConfig
      settings = Settings True False Never Curl False GHCupURL True
  let leanAppState = LeanAppState
                   settings
                   dirs'
                   defaultKeyBindings
  mpFreq <- runLogger . flip runReaderT leanAppState . runE $ platformRequest
  mGhcUpInfo <- runLogger . flip runReaderT leanAppState . runE $ getDownloadsF
  forFold mpFreq $ \pfreq -> do
    forFold mGhcUpInfo $ \ghcupInfo -> do
      let appState = AppState
            settings
            dirs'
            defaultKeyBindings
            ghcupInfo
            pfreq

          runEnv = runLogger . flip runReaderT appState

      installedVersions <- runEnv $ listVersions (Just tool) criteria
      return $ T.unpack . prettyVer . lVer <$> installedVersions


versionParser :: Parser GHCTargetVersion
versionParser = option
  (eitherReader tVersionEither)
  (short 'v' <> long "version" <> metavar "VERSION" <> help "The target version"
  )

versionParser' :: Maybe ListCriteria -> Maybe Tool -> Parser Version
versionParser' criteria tool = argument
  (eitherReader (first show . version . T.pack))
  (metavar "VERSION"  <> foldMap (completer . versionCompleter criteria) tool)


tagEither :: String -> Either String Tag
tagEither s' = case fmap toLower s' of
  "recommended" -> Right Recommended
  "latest"      -> Right Latest
  ('b':'a':'s':'e':'-':ver') -> case pvp (T.pack ver') of
                                  Right x -> Right (Base x)
                                  Left  _ -> Left $ "Invalid PVP version for base " <> ver'
  other         -> Left $ "Unknown tag " <> other


tVersionEither :: String -> Either String GHCTargetVersion
tVersionEither =
  first (const "Not a valid version") . MP.parse ghcTargetVerP "" . T.pack


toolVersionEither :: String -> Either String ToolVersion
toolVersionEither s' =
  second ToolTag (tagEither s') <|> second ToolVersion (tVersionEither s')


toolParser :: String -> Either String Tool
toolParser s' | t == T.pack "ghc"   = Right GHC
              | t == T.pack "cabal" = Right Cabal
              | otherwise           = Left ("Unknown tool: " <> s')
  where t = T.toLower (T.pack s')


criteriaParser :: String -> Either String ListCriteria
criteriaParser s' | t == T.pack "installed" = Right ListInstalled
                  | t == T.pack "set"       = Right ListSet
                  | otherwise               = Left ("Unknown criteria: " <> s')
  where t = T.toLower (T.pack s')


keepOnParser :: String -> Either String KeepDirs
keepOnParser s' | t == T.pack "always" = Right Always
                | t == T.pack "errors" = Right Errors
                | t == T.pack "never"  = Right Never
                | otherwise            = Left ("Unknown keep value: " <> s')
  where t = T.toLower (T.pack s')


downloaderParser :: String -> Either String Downloader
downloaderParser s' | t == T.pack "curl"     = Right Curl
                    | t == T.pack "wget"     = Right Wget
#if defined(INTERNAL_DOWNLOADER)
                    | t == T.pack "internal" = Right Internal
#endif
                    | otherwise = Left ("Unknown downloader value: " <> s')
  where t = T.toLower (T.pack s')


platformParser :: String -> Either String PlatformRequest
platformParser s' = case MP.parse (platformP <* MP.eof) "" (T.pack s') of
  Right r -> pure r
  Left  e -> Left $ errorBundlePretty e
 where
  archP :: MP.Parsec Void Text Architecture
  archP = MP.try (MP.chunk "x86_64" $> A_64) <|> (MP.chunk "i386" $> A_32)
  platformP :: MP.Parsec Void Text PlatformRequest
  platformP = choice'
    [ (\a mv -> PlatformRequest a FreeBSD mv)
    <$> (archP <* MP.chunk "-")
    <*> (  MP.chunk "portbld"
        *> (   MP.try (Just <$> verP (MP.chunk "-freebsd" <* MP.eof))
           <|> pure Nothing
           )
        <* MP.chunk "-freebsd"
        )
    , (\a mv -> PlatformRequest a Darwin mv)
    <$> (archP <* MP.chunk "-")
    <*> (  MP.chunk "apple"
        *> (   MP.try (Just <$> verP (MP.chunk "-darwin" <* MP.eof))
           <|> pure Nothing
           )
        <* MP.chunk "-darwin"
        )
    , (\a d mv -> PlatformRequest a (Linux d) mv)
    <$> (archP <* MP.chunk "-")
    <*> distroP
    <*> ((MP.try (Just <$> verP (MP.chunk "-linux" <* MP.eof)) <|> pure Nothing
         )
        <* MP.chunk "-linux"
        )
    ]
  distroP :: MP.Parsec Void Text LinuxDistro
  distroP = choice'
    [ MP.chunk "debian" $> Debian
    , MP.chunk "deb" $> Debian
    , MP.chunk "ubuntu" $> Ubuntu
    , MP.chunk "mint" $> Mint
    , MP.chunk "fedora" $> Fedora
    , MP.chunk "centos" $> CentOS
    , MP.chunk "redhat" $> RedHat
    , MP.chunk "alpine" $> Alpine
    , MP.chunk "gentoo" $> Gentoo
    , MP.chunk "exherbo" $> Exherbo
    , MP.chunk "unknown" $> UnknownLinux
    ]


bindistParser :: String -> Either String URI
bindistParser = first show . parseURI strictURIParserOptions . UTF8.fromString

isolateParser :: FilePath -> Either String FilePath
isolateParser f = case isValid f of
              True -> Right $ normalise f
              False -> Left "Please enter a valid filepath for isolate dir."

toSettings :: Options -> IO (Settings, KeyBindings)
toSettings options = do
  userConf <- runE @'[ JSONError ] ghcupConfigFile >>= \case
    VRight r -> pure r
    VLeft (V (JSONDecodeError e)) -> do
      B.hPut stderr ("Error decoding config file: " <> (E.encodeUtf8 . T.pack . show $ e))
      pure defaultUserSettings
    _ -> do
      die "Unexpected error!"
  pure $ mergeConf options userConf
 where
   mergeConf :: Options -> UserSettings -> (Settings, KeyBindings)
   mergeConf Options{..} UserSettings{..} =
     let cache       = fromMaybe (fromMaybe False uCache) optCache
         noVerify    = fromMaybe (fromMaybe False uNoVerify) optNoVerify
         verbose     = fromMaybe (fromMaybe False uVerbose) optVerbose
         keepDirs    = fromMaybe (fromMaybe Errors uKeepDirs) optKeepDirs
         downloader  = fromMaybe (fromMaybe defaultDownloader uDownloader) optsDownloader
         keyBindings = maybe defaultKeyBindings mergeKeys uKeyBindings
         urlSource   = maybe (fromMaybe GHCupURL uUrlSource) OwnSource optUrlSource
         noNetwork   = fromMaybe (fromMaybe False uNoNetwork) optNoNetwork
     in (Settings {..}, keyBindings)
#if defined(INTERNAL_DOWNLOADER)
   defaultDownloader = Internal
#else
   defaultDownloader = Curl
#endif
   mergeKeys :: UserKeyBindings -> KeyBindings
   mergeKeys UserKeyBindings {..} =
     let KeyBindings {..} = defaultKeyBindings
     in KeyBindings {
           bUp = fromMaybe bUp kUp
         , bDown = fromMaybe bDown kDown
         , bQuit = fromMaybe bQuit kQuit
         , bInstall = fromMaybe bInstall kInstall
         , bUninstall = fromMaybe bUninstall kUninstall
         , bSet = fromMaybe bSet kSet
         , bChangelog = fromMaybe bChangelog kChangelog
         , bShowAllVersions = fromMaybe bShowAllVersions kShowAll
         , bShowAllTools = fromMaybe bShowAllTools kShowAllTools
         }

updateSettings :: Monad m => UTF8.ByteString -> Settings -> Excepts '[JSONError] m Settings
updateSettings config settings = do
  settings' <- lE' JSONDecodeError . first show . Y.decodeEither' $ config
  pure $ mergeConf settings' settings
  where
   mergeConf :: UserSettings -> Settings -> Settings
   mergeConf UserSettings{..} Settings{..} =
     let cache'      = fromMaybe cache uCache
         noVerify'   = fromMaybe noVerify uNoVerify
         keepDirs'   = fromMaybe keepDirs uKeepDirs
         downloader' = fromMaybe downloader uDownloader
         verbose'    = fromMaybe verbose uVerbose
         urlSource'  = fromMaybe urlSource uUrlSource
         noNetwork'  = fromMaybe noNetwork uNoNetwork
     in Settings cache' noVerify' keepDirs' downloader' verbose' urlSource' noNetwork'

upgradeOptsP :: Parser UpgradeOpts
upgradeOptsP =
  flag'
      UpgradeInplace
      (short 'i' <> long "inplace" <> help
        "Upgrade ghcup in-place (wherever it's at)"
      )
    <|> (   UpgradeAt
        <$> option
              str
              (short 't' <> long "target" <> metavar "TARGET_DIR" <> help
                "Absolute filepath to write ghcup into"
              )
        )
    <|> pure UpgradeGHCupDir



describe_result :: String
describe_result = $( LitE . StringL <$>
                     runIO (do
                             CapturedProcess{..} <-  do
                              dirs <- liftIO getAllDirs
                              let settings = AppState (Settings True False Never Curl False GHCupURL False)
                                               dirs
                                               defaultKeyBindings
                              flip runReaderT settings $ executeOut "git" ["describe"] Nothing
                             case _exitCode of
                               ExitSuccess   -> pure . T.unpack . decUTF8Safe' $ _stdOut
                               ExitFailure _ -> pure numericVer
                     )
                   )

formatConfig :: UserSettings -> String
formatConfig settings
  = UTF8.toString . YP.encodePretty yamlConfig $ settings
 where
  yamlConfig = YP.setConfCompare compare YP.defConfig

main :: IO ()
main = do
  -- https://gitlab.haskell.org/ghc/ghc/issues/8118
  setLocaleEncoding utf8

  void enableAnsiSupport

  let versionHelp = infoOption
        ( ("The GHCup Haskell installer, version " <>)
          (head . lines $ describe_result)
        )
        (long "version" <> help "Show version" <> hidden)
  let numericVersionHelp = infoOption
        numericVer
        (  long "numeric-version"
        <> help "Show the numeric version (for use in scripts)"
        <> hidden
        )
  let listCommands = infoOption
        "install set rm install-cabal list upgrade compile debug-info tool-requirements changelog"
        (  long "list-commands"
        <> help "List available commands for shell completion"
        <> internal
        )

  let main_footer = [s|Discussion:
  ghcup installs the Glasgow Haskell Compiler from the official
  release channels, enabling you to easily switch between different
  versions. It maintains a self-contained ~/.ghcup directory.

ENV variables:
  * TMPDIR: where ghcup does the work (unpacking, building, ...)
  * GHCUP_INSTALL_BASE_PREFIX: the base of ghcup (default: $HOME)
  * GHCUP_USE_XDG_DIRS: set to anything to use XDG style directories

Report bugs at <https://gitlab.haskell.org/haskell/ghcup-hs/issues>|]

  customExecParser
      (prefs showHelpOnError)
      (info (opts <**> helper <**> versionHelp <**> numericVersionHelp <**> listCommands)
            (footerDoc (Just $ text main_footer))
      )
    >>= \opt@Options {..} -> do
          dirs@Dirs{..} <- getAllDirs

          -- create ~/.ghcup dir
          ensureDirectories dirs

          (settings, keybindings) <- toSettings opt

          -- logger interpreter
          logfile <- flip runReaderT dirs $ initGHCupFileLogging
          let loggerConfig = LoggerConfig
                { lcPrintDebug = verbose settings
                , colorOutter  = B.hPut stderr
                , rawOutter    =
                    case optCommand of
                      Nuke -> \_ -> pure ()
                      _ -> B.appendFile logfile
                }
          let runLogger = myLoggerT loggerConfig
          let siletRunLogger = myLoggerT loggerConfig { colorOutter = \_ -> pure () }


          -------------------------
          -- Setting up appstate --
          -------------------------


          let leanAppstate = LeanAppState settings dirs keybindings
              appState = do
                pfreq <- (
                  runLogger . runE @'[NoCompatiblePlatform, NoCompatibleArch, DistroNotFound] . liftE $ platformRequest
                  ) >>= \case
                          VRight r -> pure r
                          VLeft e -> do
                            runLogger
                              ($(logError) $ T.pack $ prettyShow e)
                            exitWith (ExitFailure 2)

                ghcupInfo <-
                  ( runLogger
                    . flip runReaderT leanAppstate
                    . runE @'[JSONError , DownloadFailed, FileDoesNotExistError]
                    $ liftE
                    $ getDownloadsF
                    )
                    >>= \case
                          VRight r -> pure r
                          VLeft  e -> do
                            runLogger
                              ($(logError) $ T.pack $ prettyShow e)
                            exitWith (ExitFailure 2)
                let s' = AppState settings dirs keybindings ghcupInfo pfreq

                race_ (liftIO $ runLogger $ flip runReaderT dirs $ cleanupTrash)
                      (threadDelay 5000000 >> runLogger ($(logWarn) $ "Killing cleanup thread (exceeded 5s timeout)... please remove leftover files in " <> T.pack recycleDir <> " manually"))

                case optCommand of
                  Nuke -> pure ()
                  Whereis _ _ -> pure ()
                  DInfo -> pure ()
                  ToolRequirements -> pure ()
                  ChangeLog _ -> pure ()
#if defined(BRICK)
                  Interactive -> pure ()
#endif
                  _ -> lookupEnv "GHCUP_SKIP_UPDATE_CHECK" >>= \case
                         Nothing -> runLogger $ flip runReaderT s' $ checkForUpdates
                         Just _ -> pure ()

                -- TODO: always run for windows
                (siletRunLogger $ flip runReaderT s' $ runE ensureGlobalTools) >>= \case
                  VRight _ -> pure ()
                  VLeft e -> do
                    runLogger
                      ($(logError) $ T.pack $ prettyShow e)
                    exitWith (ExitFailure 30)
                pure s'


#if defined(IS_WINDOWS)
              -- FIXME: windows needs 'ensureGlobalTools', which requires
              -- full appstate
              runLeanAppState = runAppState
#else
              runLeanAppState = flip runReaderT leanAppstate
#endif
              runAppState action' = do
                s' <- liftIO appState
                flip runReaderT s' action'
                  



          -------------------------
          -- Effect interpreters --
          -------------------------


          let runInstTool' appstate' mInstPlatform =
                runLogger
                  . flip runReaderT (maybe appstate' (\x -> appstate'{ pfreq = x } :: AppState) mInstPlatform)
                  . runResourceT
                  . runE
                    @'[ AlreadyInstalled
                      , UnknownArchive
                      , ArchiveResult
                      , FileDoesNotExistError
                      , CopyError
                      , NotInstalled
                      , DirNotEmpty
                      , NoDownload
                      , NotInstalled
                      , BuildFailed
                      , TagNotFound
                      , DigestError
                      , DownloadFailed
                      , TarDirDoesNotExist
                      , NextVerNotFound
                      , NoToolVersionSet
                      , FileAlreadyExistsError
                      ]

          let runInstTool mInstPlatform action' = do
                s' <- liftIO appState
                runInstTool' s' mInstPlatform action'

          let
            runLeanSetGHC =
              runLogger
                . runLeanAppState
                . runE
                  @'[ FileDoesNotExistError
                    , NotInstalled
                    , TagNotFound
                    , NextVerNotFound
                    , NoToolVersionSet
                    ]

            runSetGHC =
              runLogger
                . runAppState
                . runE
                  @'[ FileDoesNotExistError
                    , NotInstalled
                    , TagNotFound
                    , NextVerNotFound
                    , NoToolVersionSet
                    ]

          let
            runLeanSetCabal =
              runLogger
                . runLeanAppState
                . runE
                  @'[ NotInstalled
                    , TagNotFound
                    , NextVerNotFound
                    , NoToolVersionSet
                    ]

            runSetCabal =
              runLogger
                . runAppState
                . runE
                  @'[ NotInstalled
                    , TagNotFound
                    , NextVerNotFound
                    , NoToolVersionSet
                    ]

          let
            runSetHLS =
              runLogger
                . runAppState
                . runE
                  @'[ NotInstalled
                    , TagNotFound
                    , NextVerNotFound
                    , NoToolVersionSet
                    ]

            runLeanSetHLS =
              runLogger
                . runLeanAppState
                . runE
                  @'[ NotInstalled
                    , TagNotFound
                    , NextVerNotFound
                    , NoToolVersionSet
                    ]

          let runListGHC = runLogger . runAppState

          let runRm =
                runLogger . runAppState . runE @'[NotInstalled]

          let runNuke s' =
                runLogger . flip runReaderT s' . runE @'[NotInstalled]

          let runDebugInfo =
                runLogger
                  . runAppState
                  . runE
                    @'[NoCompatiblePlatform , NoCompatibleArch , DistroNotFound]

          let runCompileGHC =
                runLogger
                  . runAppState
                  . runResourceT
                  . runE
                    @'[ AlreadyInstalled
                      , BuildFailed
                      , DigestError
                      , DownloadFailed
                      , GHCupSetError
                      , NoDownload
                      , NotFoundInPATH
                      , PatchFailed
                      , UnknownArchive
                      , TarDirDoesNotExist
                      , NotInstalled
                      , DirNotEmpty
                      , ArchiveResult
                      ]

          let
            runLeanWhereIs =
              runLogger
                -- Don't use runLeanAppState here, which is disabled on windows.
                -- This is the only command on all platforms that doesn't need full appstate.
                . flip runReaderT leanAppstate
                . runE
                  @'[ NotInstalled
                    , NoToolVersionSet
                    , NextVerNotFound
                    , TagNotFound
                    ]

            runWhereIs =
              runLogger
                . runAppState
                . runE
                  @'[ NotInstalled
                    , NoToolVersionSet
                    , NextVerNotFound
                    , TagNotFound
                    ]

          let runUpgrade =
                runLogger
                  . runAppState
                  . runResourceT
                  . runE
                    @'[ DigestError
                      , NoDownload
                      , NoUpdate
                      , FileDoesNotExistError
                      , CopyError
                      , DownloadFailed
                      ]

          let runPrefetch =
                runLogger
                  . runAppState
                  . runResourceT
                  . runE
                    @'[ TagNotFound
                      , NextVerNotFound
                      , NoToolVersionSet
                      , NoDownload
                      , DigestError
                      , DownloadFailed
                      , JSONError
                      , FileDoesNotExistError
                      ]


          -----------------------
          -- Command functions --
          -----------------------

          let installGHC InstallOptions{..} =
                (case instBindist of
                   Nothing -> runInstTool instPlatform $ do
                     (v, vi) <- liftE $ fromVersion instVer GHC
                     liftE $ installGHCBin (_tvVersion v) isolateDir
                     when instSet $ void $ liftE $ setGHC v SetGHCOnly
                     pure vi
                   Just uri -> do
                     s' <- liftIO appState
                     runInstTool' s'{ settings = settings {noVerify = True}} instPlatform $ do
                       (v, vi) <- liftE $ fromVersion instVer GHC
                       liftE $ installGHCBindist
                         (DownloadInfo uri (Just $ RegexDir "ghc-.*") "")
                         (_tvVersion v)
                         isolateDir
                       when instSet $ void $ liftE $ setGHC v SetGHCOnly
                       pure vi
                  )
                    >>= \case
                          VRight vi -> do
                            runLogger $ $(logInfo) "GHC installation successful"
                            forM_ (_viPostInstall =<< vi) $ \msg ->
                              runLogger $ $(logInfo) msg
                            pure ExitSuccess
                          VLeft (V (AlreadyInstalled _ v)) -> do
                            runLogger $ $(logWarn) $
                              "GHC ver " <> prettyVer v <> " already installed; if you really want to reinstall it, you may want to run 'ghcup rm ghc " <> prettyVer v <> "' first"
                            pure ExitSuccess
                          VLeft err@(V (BuildFailed tmpdir _)) -> do
                            case keepDirs settings of
                              Never -> myLoggerT loggerConfig $ ($(logError) $ T.pack $ prettyShow err)
                              _ -> myLoggerT loggerConfig $ ($(logError) $ T.pack (prettyShow err) <> "\n" <>
                                "Check the logs at " <> T.pack logsDir <> " and the build directory " <> T.pack tmpdir <> " for more clues." <> "\n" <>
                                "Make sure to clean up " <> T.pack tmpdir <> " afterwards.")
                            pure $ ExitFailure 3
                          VLeft e -> do
                            runLogger $ do
                              $(logError) $ T.pack $ prettyShow e
                              $(logError) $ "Also check the logs in " <> T.pack logsDir
                            pure $ ExitFailure 3


          let installCabal InstallOptions{..} =
                (case instBindist of
                   Nothing -> runInstTool instPlatform $ do
                     (v, vi) <- liftE $ fromVersion instVer Cabal
                     liftE $ installCabalBin (_tvVersion v) isolateDir
                     pure vi
                   Just uri -> do
                     s' <- appState
                     runInstTool' s'{ settings = settings { noVerify = True}} instPlatform $ do
                       (v, vi) <- liftE $ fromVersion instVer Cabal
                       liftE $ installCabalBindist
                           (DownloadInfo uri Nothing "")
                           (_tvVersion v)
                           isolateDir
                       pure vi
                  )
                  >>= \case
                        VRight vi -> do
                          runLogger $ $(logInfo) "Cabal installation successful"
                          forM_ (_viPostInstall =<< vi) $ \msg ->
                            runLogger $ $(logInfo) msg
                          pure ExitSuccess
                        VLeft (V (AlreadyInstalled _ v)) -> do
                          runLogger $ $(logWarn) $
                            "Cabal ver " <> prettyVer v <> " already installed; if you really want to reinstall it, you may want to run 'ghcup rm cabal " <> prettyVer v <> "' first"
                          pure ExitSuccess
                        VLeft e -> do
                          runLogger $ do
                            $(logError) $ T.pack $ prettyShow e
                            $(logError) $ "Also check the logs in " <> T.pack logsDir
                          pure $ ExitFailure 4

          let installHLS InstallOptions{..} =
                 (case instBindist of
                   Nothing -> runInstTool instPlatform $ do
                     (v, vi) <- liftE $ fromVersion instVer HLS
                     liftE $ installHLSBin (_tvVersion v) isolateDir
                     pure vi
                   Just uri -> do
                     s' <- appState
                     runInstTool' s'{ settings = settings { noVerify = True}} instPlatform $ do
                       (v, vi) <- liftE $ fromVersion instVer HLS
                       liftE $ installHLSBindist
                           (DownloadInfo uri Nothing "")
                           (_tvVersion v)
                           isolateDir
                       pure vi
                  )
                  >>= \case
                        VRight vi -> do
                          runLogger $ $(logInfo) "HLS installation successful"
                          forM_ (_viPostInstall =<< vi) $ \msg ->
                            runLogger $ $(logInfo) msg
                          pure ExitSuccess
                        VLeft (V (AlreadyInstalled _ v)) -> do
                          runLogger $ $(logWarn) $
                              "HLS ver "
                            <> prettyVer v
                            <> " already installed; if you really want to reinstall it, you may want to run 'ghcup rm hls "
                            <> prettyVer v
                            <> "' first"
                          pure ExitSuccess
                        VLeft e -> do
                          runLogger $ do
                            $(logError) $ T.pack $ prettyShow e
                            $(logError) $ "Also check the logs in " <> T.pack logsDir
                          pure $ ExitFailure 4

          let installStack InstallOptions{..} =
                 (case instBindist of
                    Nothing -> runInstTool instPlatform $ do
                      (v, vi) <- liftE $ fromVersion instVer Stack
                      liftE $ installStackBin (_tvVersion v) isolateDir
                      pure vi
                    Just uri -> do
                      s' <- appState
                      runInstTool' s'{ settings = settings { noVerify = True}} instPlatform $ do
                        (v, vi) <- liftE $ fromVersion instVer Stack
                        liftE $ installStackBindist
                            (DownloadInfo uri Nothing "")
                            (_tvVersion v)
                            isolateDir
                        pure vi
                  )
                  >>= \case
                        VRight vi -> do
                          runLogger $ $(logInfo) "Stack installation successful"
                          forM_ (_viPostInstall =<< vi) $ \msg ->
                            runLogger $ $(logInfo) msg
                          pure ExitSuccess
                        VLeft (V (AlreadyInstalled _ v)) -> do
                          runLogger $ $(logWarn) $
                            "Stack ver " <> prettyVer v <> " already installed; if you really want to reinstall it, you may want to run 'ghcup rm stack " <> prettyVer v <> "' first"
                          pure ExitSuccess
                        VLeft e -> do
                          runLogger $ do
                            $(logError) $ T.pack $ prettyShow e
                            $(logError) $ "Also check the logs in " <> T.pack logsDir
                          pure $ ExitFailure 4


          let setGHC' SetOptions{ sToolVer } =
                case sToolVer of
                  (SetToolVersion v) -> runLeanSetGHC (liftE $ setGHC v SetGHCOnly >> pure v)
                  _ -> runSetGHC (do
                      v <- liftE $ fst <$> fromVersion' sToolVer GHC
                      liftE $ setGHC v SetGHCOnly
                    )
                  >>= \case
                        VRight GHCTargetVersion{..} -> do
                          runLogger
                            $ $(logInfo) $
                                "GHC " <> prettyVer _tvVersion <> " successfully set as default version" <> maybe "" (" for cross target " <>) _tvTarget
                          pure ExitSuccess
                        VLeft e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 5

          let setCabal' SetOptions{ sToolVer } =
                case sToolVer of
                  (SetToolVersion v) -> runLeanSetCabal (liftE $ setCabal (_tvVersion v) >> pure v)
                  _ -> runSetCabal (do
                      v <- liftE $ fst <$> fromVersion' sToolVer Cabal
                      liftE $ setCabal (_tvVersion v)
                      pure v
                    )
                  >>= \case
                        VRight GHCTargetVersion{..} -> do
                          runLogger
                            $ $(logInfo) $
                                "Cabal " <> prettyVer _tvVersion <> " successfully set as default version"
                          pure ExitSuccess
                        VLeft  e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 14

          let setHLS' SetOptions{ sToolVer } =
                case sToolVer of
                  (SetToolVersion v) -> runLeanSetHLS (liftE $ setHLS (_tvVersion v) >> pure v)
                  _ -> runSetHLS (do
                      v <- liftE $ fst <$> fromVersion' sToolVer HLS
                      liftE $ setHLS (_tvVersion v)
                      pure v
                    )
                  >>= \case
                        VRight GHCTargetVersion{..} -> do
                          runLogger
                            $ $(logInfo) $
                                "HLS " <> prettyVer _tvVersion <> " successfully set as default version"
                          pure ExitSuccess
                        VLeft  e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 14

          let setStack' SetOptions{ sToolVer } =
                case sToolVer of
                  (SetToolVersion v) -> runSetCabal (liftE $ setStack (_tvVersion v) >> pure v)
                  _ -> runSetCabal (do
                        v <- liftE $ fst <$> fromVersion' sToolVer Stack
                        liftE $ setStack (_tvVersion v)
                        pure v
                      )
                  >>= \case
                        VRight GHCTargetVersion{..} -> do
                          runLogger
                            $ $(logInfo) $
                                "Stack " <> prettyVer _tvVersion <> " successfully set as default version"
                          pure ExitSuccess
                        VLeft  e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 14

          let rmGHC' RmOptions{..} =
                runRm (do
                    liftE $
                      rmGHCVer ghcVer
                    GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
                    pure (getVersionInfo (_tvVersion ghcVer) GHC dls)
                  )
                  >>= \case
                        VRight vi -> do
                          forM_ (_viPostRemove =<< vi) $ \msg ->
                            runLogger $ $(logInfo) msg
                          pure ExitSuccess
                        VLeft  e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 7

          let rmCabal' tv =
                runRm (do
                    liftE $
                      rmCabalVer tv
                    GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
                    pure (getVersionInfo tv Cabal dls)
                  )
                  >>= \case
                        VRight vi -> do
                          forM_ (_viPostRemove =<< vi) $ \msg ->
                            runLogger $ $(logInfo) msg
                          pure ExitSuccess
                        VLeft  e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 15

          let rmHLS' tv =
                runRm (do
                    liftE $
                      rmHLSVer tv
                    GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
                    pure (getVersionInfo tv HLS dls)
                  )
                  >>= \case
                        VRight vi -> do
                          forM_ (_viPostRemove =<< vi) $ \msg ->
                            runLogger $ $(logInfo) msg
                          pure ExitSuccess
                        VLeft  e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 15

          let rmStack' tv =
                runRm (do
                    liftE $
                      rmStackVer tv
                    GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
                    pure (getVersionInfo tv Stack dls)
                  )
                  >>= \case
                        VRight vi -> do
                          forM_ (_viPostRemove =<< vi) $ \msg ->
                            runLogger $ $(logInfo) msg
                          pure ExitSuccess
                        VLeft  e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 15

          res <- case optCommand of
#if defined(BRICK)
            Interactive -> do
              s' <- appState
              liftIO $ brickMain s' loggerConfig >> pure ExitSuccess
#endif
            Install (Right iopts) -> do
              runLogger ($(logWarn) "This is an old-style command for installing GHC. Use 'ghcup install ghc' instead.")
              installGHC iopts
            Install (Left (InstallGHC iopts)) -> installGHC iopts
            Install (Left (InstallCabal iopts)) -> installCabal iopts
            Install (Left (InstallHLS iopts)) -> installHLS iopts
            Install (Left (InstallStack iopts)) -> installStack iopts
            InstallCabalLegacy iopts -> do
              runLogger ($(logWarn) "This is an old-style command for installing cabal. Use 'ghcup install cabal' instead.")
              installCabal iopts

            Set (Right sopts) -> do
              runLogger ($(logWarn) "This is an old-style command for setting GHC. Use 'ghcup set ghc' instead.")
              setGHC' sopts
            Set (Left (SetGHC sopts)) -> setGHC' sopts
            Set (Left (SetCabal sopts)) -> setCabal' sopts
            Set (Left (SetHLS sopts)) -> setHLS' sopts
            Set (Left (SetStack sopts)) -> setStack' sopts

            List ListOptions {..} ->
              runListGHC (do
                  l <- listVersions loTool lCriteria
                  liftIO $ printListResult lRawFormat l
                  pure ExitSuccess
                )

            Rm (Right rmopts) -> do
              runLogger ($(logWarn) "This is an old-style command for removing GHC. Use 'ghcup rm ghc' instead.")
              rmGHC' rmopts
            Rm (Left (RmGHC rmopts)) -> rmGHC' rmopts
            Rm (Left (RmCabal rmopts)) -> rmCabal' rmopts
            Rm (Left (RmHLS rmopts)) -> rmHLS' rmopts
            Rm (Left (RmStack rmopts)) -> rmStack' rmopts

            DInfo ->
              do runDebugInfo $ liftE getDebugInfo
                >>= \case
                      VRight dinfo -> do
                        putStrLn $ prettyDebugInfo dinfo
                        pure ExitSuccess
                      VLeft e -> do
                        runLogger $ $(logError) $ T.pack $ prettyShow e
                        pure $ ExitFailure 8

            Compile (CompileGHC GHCCompileOptions { hadrian = True, crossTarget = Just _ }) -> do
              runLogger $ $(logError) "Hadrian cross compile support is not yet implemented!"
              pure $ ExitFailure 9
            Compile (CompileGHC GHCCompileOptions {..}) ->
              runCompileGHC (do
                case targetGhc of
                  Left targetVer -> do
                    GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
                    let vi = getVersionInfo targetVer GHC dls
                    forM_ (_viPreCompile =<< vi) $ \msg -> do
                      lift $ $(logInfo) msg
                      lift $ $(logInfo)
                        "...waiting for 5 seconds, you can still abort..."
                      liftIO $ threadDelay 5000000 -- for compilation, give the user a sec to intervene
                  Right _ -> pure ()
                targetVer <- liftE $ compileGHC
                            (first (GHCTargetVersion crossTarget) targetGhc)
                            ovewrwiteVer
                            bootstrapGhc
                            jobs
                            buildConfig
                            patchDir
                            addConfArgs
                            buildFlavour
                            hadrian
                            isolateDir
                GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
                let vi = getVersionInfo (_tvVersion targetVer) GHC dls
                when setCompile $ void $ liftE $
                  setGHC targetVer SetGHCOnly
                pure (vi, targetVer)
                )
                >>= \case
                      VRight (vi, tv) -> do
                        runLogger $ $(logInfo)
                          "GHC successfully compiled and installed"
                        forM_ (_viPostInstall =<< vi) $ \msg ->
                          runLogger $ $(logInfo) msg
                        putStr (T.unpack $ tVerToText tv)
                        pure ExitSuccess
                      VLeft (V (AlreadyInstalled _ v)) -> do
                        runLogger $ $(logWarn) $
                          "GHC ver " <> prettyVer v <> " already installed; if you really want to reinstall it, you may want to run 'ghcup rm ghc " <> prettyVer v <> "' first"
                        pure ExitSuccess
                      VLeft err@(V (BuildFailed tmpdir _)) -> do
                        case keepDirs settings of
                          Never -> myLoggerT loggerConfig $ $(logError) $ T.pack $ prettyShow err
                          _ -> myLoggerT loggerConfig $ ($(logError) $ T.pack (prettyShow err) <> "\n" <>
                                "Check the logs at " <> T.pack logsDir <> " and the build directory "
                                <> T.pack tmpdir <> " for more clues." <> "\n" <>
                                "Make sure to clean up " <> T.pack tmpdir <> " afterwards.")
                        pure $ ExitFailure 9
                      VLeft e -> do
                        runLogger $ $(logError) $ T.pack $ prettyShow e
                        pure $ ExitFailure 9

            Config InitConfig -> do
              path <- getConfigFilePath
              writeFile path $ formatConfig $ fromSettings settings (Just keybindings)
              runLogger $ $(logDebug) $ "config.yaml initialized at " <> T.pack path
              pure ExitSuccess

            Config ShowConfig -> do
              putStrLn $ formatConfig $ fromSettings settings (Just keybindings)
              pure ExitSuccess

            Config (SetConfig k v) -> do
              case v of
                "" -> do
                  runLogger $ $(logError) "Empty values are not allowed"
                  pure $ ExitFailure 55
                _  -> do
                  r <- runE @'[JSONError] $ do
                    settings' <- updateSettings (UTF8.fromString (k <> ": " <> v <> "\n")) settings
                    path <- liftIO getConfigFilePath
                    liftIO $ writeFile path $ formatConfig $ fromSettings settings' (Just keybindings)
                    runLogger $ $(logDebug) $ T.pack $ show settings'
                    pure ()

                  case r of
                      VRight _ -> pure ExitSuccess
                      VLeft (V (JSONDecodeError e)) -> do
                        runLogger $ $(logError) $ "Error decoding config: " <> T.pack e
                        pure $ ExitFailure 65
                      VLeft _ -> pure $ ExitFailure 65

            Whereis WhereisOptions{..} (WhereisTool tool (Just (ToolVersion v))) ->
              runLeanWhereIs (do
                loc <- liftE $ whereIsTool tool v
                if directory
                then pure $ takeDirectory loc
                else pure loc
                )
                >>= \case
                      VRight r -> do
                        putStr r
                        pure ExitSuccess
                      VLeft e -> do
                        runLogger $ $(logError) $ T.pack $ prettyShow e
                        pure $ ExitFailure 30

            Whereis WhereisOptions{..} (WhereisTool tool whereVer) ->
              runWhereIs (do
                (v, _) <- liftE $ fromVersion whereVer tool
                loc <- liftE $ whereIsTool tool v
                if directory
                then pure $ takeDirectory loc
                else pure loc
                )
                >>= \case
                      VRight r -> do
                        putStr r
                        pure ExitSuccess
                      VLeft e -> do
                        runLogger $ $(logError) $ T.pack $ prettyShow e
                        pure $ ExitFailure 30

            Upgrade uOpts force' -> do
              target <- case uOpts of
                UpgradeInplace  -> Just <$> liftIO getExecutablePath
                (UpgradeAt p)   -> pure $ Just p
                UpgradeGHCupDir -> pure (Just (binDir </> "ghcup" <> exeExt))

              runUpgrade (do
                v' <- liftE $ upgradeGHCup target force'
                GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
                pure (v', dls)
                ) >>= \case
                  VRight (v', dls) -> do
                    let pretty_v = prettyVer v'
                    let vi = fromJust $ snd <$> getLatest dls GHCup
                    runLogger $ $(logInfo) $
                      "Successfully upgraded GHCup to version " <> pretty_v
                    forM_ (_viPostInstall vi) $ \msg ->
                      runLogger $ $(logInfo) msg
                    pure ExitSuccess
                  VLeft (V NoUpdate) -> do
                    runLogger $ $(logWarn) "No GHCup update available"
                    pure ExitSuccess
                  VLeft e -> do
                    runLogger $ $(logError) $ T.pack $ prettyShow e
                    pure $ ExitFailure 11

            ToolRequirements -> do
              s' <- appState
              flip runReaderT s'
                $ runLogger
                  (runE
                    @'[NoCompatiblePlatform , DistroNotFound , NoToolRequirements]
                  $ do
                      GHCupInfo { .. } <- lift getGHCupInfo
                      platform' <- liftE getPlatform
                      req      <- getCommonRequirements platform' _toolRequirements ?? NoToolRequirements
                      liftIO $ T.hPutStr stdout (prettyRequirements req)
                  )
                  >>= \case
                        VRight _ -> pure ExitSuccess
                        VLeft  e -> do
                          runLogger $ $(logError) $ T.pack $ prettyShow e
                          pure $ ExitFailure 12

            ChangeLog ChangeLogOptions{..} -> do
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
                    ($(logWarn) $
                      "Could not find ChangeLog for " <> T.pack (prettyShow tool) <> ", version " <> either prettyVer (T.pack . show) ver'
                    )
                  pure ExitSuccess
                Just uri -> do
                  s' <- appState
                  pfreq <- flip runReaderT s' getPlatformReq
                  let uri' = T.unpack . decUTF8Safe . serializeURIRef' $ uri
                      cmd = case _rPlatform pfreq of
                              Darwin  -> "open"
                              Linux _ -> "xdg-open"
                              FreeBSD -> "xdg-open"
                              Windows -> "start"

                  if clOpen
                    then do
                      flip runReaderT s' $
                        exec cmd
                             [T.unpack $ decUTF8Safe $ serializeURIRef' uri]
                             Nothing
                             Nothing
                          >>= \case
                                Right _ -> pure ExitSuccess
                                Left  e -> runLogger ($(logError) (T.pack $ prettyShow e))
                                  >> pure (ExitFailure 13)
                    else putStrLn uri' >> pure ExitSuccess

            Nuke -> do
              s' <- liftIO appState
              void $ liftIO $ evaluate $ force s'
              runNuke s' (do
                   lift $ $logWarn "WARNING: This will remove GHCup and all installed components from your system."
                   lift $ $logWarn "Waiting 10 seconds before commencing, if you want to cancel it, now would be the time."
                   liftIO $ threadDelay 10000000  -- wait 10s

                   lift $ $logInfo "Initiating Nuclear Sequence 🚀🚀🚀"
                   lift $ $logInfo "Nuking in 3...2...1"
              
                   lInstalled <- lift $ listVersions Nothing (Just ListInstalled)

                   forM_ lInstalled (liftE . rmTool)

                   lift rmGhcupDirs

                   ) >>= \case
                            VRight leftOverFiles
                              | null leftOverFiles -> do
                                  runLogger $ $logInfo "Nuclear Annihilation complete!"
                                  pure ExitSuccess
                              | otherwise -> do
                                  runLogger $ $logError "These Files have survived Nuclear Annihilation, you may remove them manually."
                                  forM_ leftOverFiles putStrLn
                                  pure ExitSuccess

                            VLeft e -> do
                              runLogger $ $(logError) $ T.pack $ prettyShow e
                              pure $ ExitFailure 15
            Prefetch pfCom ->
              runPrefetch (do
                case pfCom of
                  PrefetchGHC
                    (PrefetchGHCOptions pfGHCSrc pfCacheDir) mt -> do
                      forM_ pfCacheDir (liftIO . createDirRecursive')
                      (v, _) <- liftE $ fromVersion mt GHC
                      if pfGHCSrc
                      then liftE $ fetchGHCSrc (_tvVersion v) pfCacheDir
                      else liftE $ fetchToolBindist (_tvVersion v) GHC pfCacheDir
                  PrefetchCabal (PrefetchOptions {pfCacheDir}) mt   -> do
                    forM_ pfCacheDir (liftIO . createDirRecursive')
                    (v, _) <- liftE $ fromVersion mt Cabal
                    liftE $ fetchToolBindist (_tvVersion v) Cabal pfCacheDir
                  PrefetchHLS (PrefetchOptions {pfCacheDir}) mt   -> do
                    forM_ pfCacheDir (liftIO . createDirRecursive')
                    (v, _) <- liftE $ fromVersion mt HLS
                    liftE $ fetchToolBindist (_tvVersion v) HLS pfCacheDir
                  PrefetchStack (PrefetchOptions {pfCacheDir}) mt   -> do
                    forM_ pfCacheDir (liftIO . createDirRecursive')
                    (v, _) <- liftE $ fromVersion mt Stack
                    liftE $ fetchToolBindist (_tvVersion v) Stack pfCacheDir
                  PrefetchMetadata -> do
                    _ <- liftE $ getDownloadsF
                    pure ""
                   ) >>= \case
                            VRight _ -> do
                                  pure ExitSuccess
                            VLeft e -> do
                              runLogger $ $(logError) $ T.pack $ prettyShow e
                              pure $ ExitFailure 15


          case res of
            ExitSuccess        -> pure ()
            ef@(ExitFailure _) -> exitWith ef


  pure ()

fromVersion :: ( MonadLogger m
               , MonadFail m
               , MonadReader env m
               , HasGHCupInfo env
               , HasDirs env
               , MonadThrow m
               , MonadIO m
               , MonadCatch m
               )
            => Maybe ToolVersion
            -> Tool
            -> Excepts
                 '[ TagNotFound
                  , NextVerNotFound
                  , NoToolVersionSet
                  ] m (GHCTargetVersion, Maybe VersionInfo)
fromVersion tv = fromVersion' (toSetToolVer tv)

fromVersion' :: ( MonadLogger m
                , MonadFail m
                , MonadReader env m
                , HasGHCupInfo env
                , HasDirs env
                , MonadThrow m
                , MonadIO m
                , MonadCatch m
                )
             => SetToolVersion
             -> Tool
             -> Excepts
                  '[ TagNotFound
                   , NextVerNotFound
                   , NoToolVersionSet
                   ] m (GHCTargetVersion, Maybe VersionInfo)
fromVersion' SetRecommended tool = do
  GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
  (\(x, y) -> (mkTVer x, Just y)) <$> getRecommended dls tool
    ?? TagNotFound Recommended tool
fromVersion' (SetToolVersion v) tool = do
  GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
  let vi = getVersionInfo (_tvVersion v) tool dls
  case pvp $ prettyVer (_tvVersion v) of
    Left _ -> pure (v, vi)
    Right (PVP (major' :|[minor'])) ->
      case getLatestGHCFor (fromIntegral major') (fromIntegral minor') dls of
        Just (v', vi') -> pure (GHCTargetVersion (_tvTarget v) v', Just vi')
        Nothing -> pure (v, vi)
    Right _ -> pure (v, vi)
fromVersion' (SetToolTag Latest) tool = do
  GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
  (\(x, y) -> (mkTVer x, Just y)) <$> getLatest dls tool ?? TagNotFound Latest tool
fromVersion' (SetToolTag Recommended) tool = do
  GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
  (\(x, y) -> (mkTVer x, Just y)) <$> getRecommended dls tool ?? TagNotFound Recommended tool
fromVersion' (SetToolTag (Base pvp'')) GHC = do
  GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
  (\(x, y) -> (mkTVer x, Just y)) <$> getLatestBaseVersion dls pvp'' ?? TagNotFound (Base pvp'') GHC
fromVersion' SetNext tool = do
  GHCupInfo { _ghcupDownloads = dls } <- lift getGHCupInfo
  next <- case tool of
    GHC -> do
      set <- fmap _tvVersion $ ghcSet Nothing !? NoToolVersionSet tool
      ghcs <- rights <$> lift getInstalledGHCs
      (headMay
        . tail
        . dropWhile (\GHCTargetVersion {..} -> _tvVersion /= set)
        . cycle
        . sortBy (\x y -> compare (_tvVersion x) (_tvVersion y))
        . filter (\GHCTargetVersion {..} -> _tvTarget == Nothing)
        $ ghcs) ?? NoToolVersionSet tool
    Cabal -> do
      set <- cabalSet !? NoToolVersionSet tool
      cabals <- rights <$> lift getInstalledCabals
      (fmap (GHCTargetVersion Nothing)
        . headMay
        . tail
        . dropWhile (/= set)
        . cycle
        . sort
        $ cabals) ?? NoToolVersionSet tool
    HLS -> do
      set <- hlsSet !? NoToolVersionSet tool
      hlses <- rights <$> lift getInstalledHLSs
      (fmap (GHCTargetVersion Nothing)
        . headMay
        . tail
        . dropWhile (/= set)
        . cycle
        . sort
        $ hlses) ?? NoToolVersionSet tool
    Stack -> do
      set <- stackSet !? NoToolVersionSet tool
      stacks <- rights <$> lift getInstalledStacks
      (fmap (GHCTargetVersion Nothing)
        . headMay
        . tail
        . dropWhile (/= set)
        . cycle
        . sort
        $ stacks) ?? NoToolVersionSet tool
    GHCup -> fail "GHCup cannot be set"
  let vi = getVersionInfo (_tvVersion next) tool dls
  pure (next, vi)
fromVersion' (SetToolTag t') tool =
  throwE $ TagNotFound t' tool


printListResult :: Bool -> [ListResult] -> IO ()
printListResult raw lr = do
  no_color <- isJust <$> lookupEnv "NO_COLOR"

  let
    color | raw || no_color = flip const
          | otherwise       = Pretty.color

  let
    printTag Recommended        = color Green "recommended"
    printTag Latest             = color Yellow "latest"
    printTag Prerelease         = color Red "prerelease"
    printTag (Base       pvp'') = "base-" ++ T.unpack (prettyPVP pvp'')
    printTag (UnknownTag t    ) = t
    printTag Old                = ""

  let
    rows =
      (\x -> if raw
          then x
          else [color Green "", "Tool", "Version", "Tags", "Notes"] : x
        )
        . fmap
            (\ListResult {..} ->
              let marks = if
#if defined(IS_WINDOWS)
                    | lSet       -> (color Green "IS")
                    | lInstalled -> (color Green "I ")
                    | otherwise  -> (color Red "X ")
#else
                    | lSet       -> (color Green "✔✔")
                    | lInstalled -> (color Green "✓ ")
                    | otherwise  -> (color Red "✗ ")
#endif
              in
                (if raw then [] else [marks])
                  ++ [ fmap toLower . show $ lTool
                     , case lCross of
                       Nothing -> T.unpack . prettyVer $ lVer
                       Just c  -> T.unpack (c <> "-" <> prettyVer lVer)
                     , intercalate "," $ (filter (/= "") . fmap printTag $ sort lTag)
                     , intercalate ","
                     $  (if hlsPowered
                          then [color Green "hls-powered"]
                          else mempty
                        )
                     ++ (if fromSrc then [color Blue "compiled"] else mempty)
                     ++ (if lStray then [color Yellow "stray"] else mempty)
                     ++ (if lNoBindist
                          then [color Red "no-bindist"]
                          else mempty
                        )
                     ]
            )
        $ lr
  let cols =
        foldr (\xs ys -> zipWith (:) xs ys) (replicate (length rows) []) rows
      lengths = fmap maximum . (fmap . fmap) strWidth $ cols
      padded  = fmap (\xs -> zipWith padTo xs lengths) rows

  forM_ padded $ \row -> putStrLn $ intercalate " " row
 where

  padTo str' x =
    let lstr = strWidth str'
        add' = x - lstr
    in  if add' < 0 then str' else str' ++ replicate add' ' '

  -- | Calculate the render width of a string, considering
  -- wide characters (counted as double width), ANSI escape codes
  -- (not counted), and line breaks (in a multi-line string, the longest
  -- line determines the width).
  strWidth :: String -> Int
  strWidth =
    maximum
      . (0 :)
      . map (foldr (\a b -> charWidth a + b) 0)
      . lines
      . stripAnsi

  -- | Strip ANSI escape sequences from a string.
  --
  -- >>> stripAnsi "\ESC[31m-1\ESC[m"
  -- "-1"
  stripAnsi :: String -> String
  stripAnsi s' =
    case
        MP.parseMaybe (many $ "" <$ MP.try ansi <|> pure <$> MP.anySingle) s'
      of
        Nothing -> error "Bad ansi escape"  -- PARTIAL: should not happen
        Just xs -> concat xs
   where
      -- This parses lots of invalid ANSI escape codes, but that should be fine
    ansi =
      MPC.string "\ESC[" *> digitSemicolons *> suffix MP.<?> "ansi" :: MP.Parsec
          Void
          String
          Char
    digitSemicolons = MP.takeWhileP Nothing (\c -> isDigit c || c == ';')
    suffix = MP.oneOf ['A', 'B', 'C', 'D', 'H', 'J', 'K', 'f', 'm', 's', 'u']

  -- | Get the designated render width of a character: 0 for a combining
  -- character, 1 for a regular character, 2 for a wide character.
  -- (Wide characters are rendered as exactly double width in apps and
  -- fonts that support it.) (From Pandoc.)
  charWidth :: Char -> Int
  charWidth c = case c of
    _ | c < '\x0300'                     -> 1
      | c >= '\x0300' && c <= '\x036F'   -> 0
      |  -- combining
        c >= '\x0370' && c <= '\x10FC'   -> 1
      | c >= '\x1100' && c <= '\x115F'   -> 2
      | c >= '\x1160' && c <= '\x11A2'   -> 1
      | c >= '\x11A3' && c <= '\x11A7'   -> 2
      | c >= '\x11A8' && c <= '\x11F9'   -> 1
      | c >= '\x11FA' && c <= '\x11FF'   -> 2
      | c >= '\x1200' && c <= '\x2328'   -> 1
      | c >= '\x2329' && c <= '\x232A'   -> 2
      | c >= '\x232B' && c <= '\x2E31'   -> 1
      | c >= '\x2E80' && c <= '\x303E'   -> 2
      | c == '\x303F'                    -> 1
      | c >= '\x3041' && c <= '\x3247'   -> 2
      | c >= '\x3248' && c <= '\x324F'   -> 1
      | -- ambiguous
        c >= '\x3250' && c <= '\x4DBF'   -> 2
      | c >= '\x4DC0' && c <= '\x4DFF'   -> 1
      | c >= '\x4E00' && c <= '\xA4C6'   -> 2
      | c >= '\xA4D0' && c <= '\xA95F'   -> 1
      | c >= '\xA960' && c <= '\xA97C'   -> 2
      | c >= '\xA980' && c <= '\xABF9'   -> 1
      | c >= '\xAC00' && c <= '\xD7FB'   -> 2
      | c >= '\xD800' && c <= '\xDFFF'   -> 1
      | c >= '\xE000' && c <= '\xF8FF'   -> 1
      | -- ambiguous
        c >= '\xF900' && c <= '\xFAFF'   -> 2
      | c >= '\xFB00' && c <= '\xFDFD'   -> 1
      | c >= '\xFE00' && c <= '\xFE0F'   -> 1
      | -- ambiguous
        c >= '\xFE10' && c <= '\xFE19'   -> 2
      | c >= '\xFE20' && c <= '\xFE26'   -> 1
      | c >= '\xFE30' && c <= '\xFE6B'   -> 2
      | c >= '\xFE70' && c <= '\xFEFF'   -> 1
      | c >= '\xFF01' && c <= '\xFF60'   -> 2
      | c >= '\xFF61' && c <= '\x16A38'  -> 1
      | c >= '\x1B000' && c <= '\x1B001' -> 2
      | c >= '\x1D000' && c <= '\x1F1FF' -> 1
      | c >= '\x1F200' && c <= '\x1F251' -> 2
      | c >= '\x1F300' && c <= '\x1F773' -> 1
      | c >= '\x20000' && c <= '\x3FFFD' -> 2
      | otherwise                        -> 1


checkForUpdates :: ( MonadReader env m
                   , HasGHCupInfo env
                   , HasDirs env
                   , HasPlatformReq env
                   , MonadCatch m
                   , MonadLogger m
                   , MonadThrow m
                   , MonadIO m
                   , MonadFail m
                   , MonadLogger m
                   )
                => m ()
checkForUpdates = do
  GHCupInfo { _ghcupDownloads = dls } <- getGHCupInfo
  lInstalled <- listVersions Nothing (Just ListInstalled)
  let latestInstalled tool = (fmap lVer . lastMay . filter (\lr -> lTool lr == tool)) lInstalled

  forM_ (getLatest dls GHCup) $ \(l, _) -> do
    (Right ghc_ver) <- pure $ version $ prettyPVP ghcUpVer
    when (l > ghc_ver)
      $ $(logWarn) $
          "New GHCup version available: " <> prettyVer l <> ". To upgrade, run 'ghcup upgrade'"

  forM_ (getLatest dls GHC) $ \(l, _) -> do
    let mghc_ver = latestInstalled GHC
    forM mghc_ver $ \ghc_ver ->
      when (l > ghc_ver)
        $ $(logWarn) $
          "New GHC version available: " <> prettyVer l <> ". To upgrade, run 'ghcup install ghc " <> prettyVer l <> "'"

  forM_ (getLatest dls Cabal) $ \(l, _) -> do
    let mcabal_ver = latestInstalled Cabal
    forM mcabal_ver $ \cabal_ver ->
      when (l > cabal_ver)
        $ $(logWarn) $
          "New Cabal version available: " <> prettyVer l <> ". To upgrade, run 'ghcup install cabal " <> prettyVer l <> "'"

  forM_ (getLatest dls HLS) $ \(l, _) -> do
    let mhls_ver = latestInstalled HLS
    forM mhls_ver $ \hls_ver ->
      when (l > hls_ver)
        $ $(logWarn) $
          "New HLS version available: " <> prettyVer l <> ". To upgrade, run 'ghcup install hls " <> prettyVer l <> "'"

  forM_ (getLatest dls Stack) $ \(l, _) -> do
    let mstack_ver = latestInstalled Stack
    forM mstack_ver $ \stack_ver ->
      when (l > stack_ver)
        $ $(logWarn) $
          "New Stack version available: " <> prettyVer l <> ". To upgrade, run 'ghcup install stack " <> prettyVer l <> "'"


prettyDebugInfo :: DebugInfo -> String
prettyDebugInfo DebugInfo {..} = "Debug Info" <> "\n" <>
  "==========" <> "\n" <>
  "GHCup base dir: " <> diBaseDir <> "\n" <>
  "GHCup bin dir: " <> diBinDir <> "\n" <>
  "GHCup GHC directory: " <> diGHCDir <> "\n" <>
  "GHCup cache directory: " <> diCacheDir <> "\n" <>
  "Architecture: " <> prettyShow diArch <> "\n" <>
  "Platform: " <> prettyShow diPlatform <> "\n" <>
  "Version: " <> describe_result

