{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}

import Distribution.Simple
import Distribution.Simple.Setup
import Distribution.Simple.Utils (rawSystemExit, rawSystemExitWithEnv, installOrdinaryFile,
        installExecutableFile, copyFileVerbose, createDirectoryIfMissingVerbose,
        getDirectoryContentsRecursive, ordNub, isInfixOf)
import Distribution.Simple.LocalBuildInfo (
        LocalBuildInfo(..), InstallDirs(..), absoluteInstallDirs)
import Distribution.PackageDescription (PackageDescription(..), GenericPackageDescription(..),
        HookedBuildInfo(..), BuildInfo(..), emptyBuildInfo,
#if MIN_VERSION_Cabal(2,2,0)
        lookupFlagAssignment,
#endif
        updatePackageDescription, FlagAssignment(..))
import Distribution.Verbosity (verbose, Verbosity(..))
import Distribution.System (OS(..), Arch(..), Platform (..), buildOS, buildPlatform)
import qualified Distribution.Simple.Utils
import System.Directory
import System.FilePath
import System.Environment( getEnvironment )
import Control.Monad ( filterM )
import Data.Maybe

#if MIN_VERSION_Cabal(2,0,0)
import Distribution.Version( Version, showVersion )
import Distribution.PackageDescription (mkFlagName)
#else
import Data.Version( Version, showVersion )
import Distribution.PackageDescription (FlagName(..))
#endif

-- The abcBridge depends on the ABC library itself.  The ABC library can be
-- provided in two ways:
--
--    1. In the local abc-build subdirectory (usually populated via
--       git submodules)
--
--    2. It can already be present (e.g. as installed by system
--       package management).
--
-- This non-standard Setup will attempt to identify which of these
-- locations the ABC library can be obtained from, and prepares the
-- abcBridge build to utilize the include files and libabc.a file from
-- that location.  If the location is a local subdirectory, the cabal
-- configure will also build the libabc.a in that subdirectory (via
-- calling into the "scripts/build-abc.sh" script at the proper time).
--
-- This Setup will also dynamically modify the cabal package
-- description to include the ABC source files in the
-- `extra-source-files` specification (so `cabal sdist` works as
-- expected), and to add the ABC source tree directories to
-- `include-dirs`.  This is done by reading the files
-- `scripts/abc-sources.txt` and `scripts/abc-incl-dirs.txt`, which
-- are set up by `setupAbc` during `cabal configure`.
--
-- Finally, this Setup will also provide some information about where
-- to find the libabc.a and libabc.dll files.
--
-- The setup achieves all of this by the following:
--
--   * Using a configure hook to modify the package description read
--     from disk before returning the local build info that is used by
--     other cabal actions.
--
--   * Note that the sDistHook (postCopy) is not modified: the sdist
--     should not contain any libabc sources; those can be distributed
--     separately.
--
--   * The 'clean' action will also perform a clean of the local copy
--     of libabc.

main = defaultMainWithHooks simpleUserHooks
    {  confHook = \(gpkg_desc, hbi) f -> do
                    let v = fromFlag $ configVerbosity f
                    let fs = configConfigurationsFlags f
                    setupAbc v (packageDescription gpkg_desc)
                    buildAbc v fs
                    lbi <- confHook simpleUserHooks (gpkg_desc, hbi) f
                    pkg_desc' <- abcPkgDesc (localPkgDescr lbi)
                    return lbi{ localPkgDescr = pkg_desc' }

    , cleanHook = \pkg_desc unit uh cf -> do
                    let v = fromFlag $ cleanVerbosity cf
                    cleanAbc v
                    cleanHook simpleUserHooks pkg_desc unit uh cf

    , sDistHook = \pkg_desc lbi h f -> do
                    let v = fromFlag $ sDistVerbosity f
                    setupAbc v pkg_desc
                    pkg_desc' <- abcPkgDesc pkg_desc
                    sDistHook simpleUserHooks pkg_desc' lbi h f

    -- , postCopy = postCopyAbc
    }

-- This is where we stash the static compiled ABC libraries
static_dir = "dist"</>"build"

data ABCLib = LocalABC FilePath FilePath
            | SystemABC FilePath FilePath

getABCLib :: IO ABCLib
getABCLib = do
  let lclsrc = "abc-build" </> "src"
      libname = "libabc.a"
      hasABCincl p = doesFileExist $ p </> "base" </> "abc" </> "abc.h"
      chkABClib p = let f = (if take 2 p == "-L" then drop 2 p else p) </> libname
                    in doesFileExist f >>= \e -> return (if e then Just f else Nothing)
      noABCError w = error ("ABC library must be checked out as a submodule" ++
                            " or installed in the system (" ++ w ++ ").")
  lclsrcExists <- doesDirectoryExist lclsrc
  if lclsrcExists
    then return $ LocalABC lclsrc ("abc-build"</>libname)
    else do env <- getEnvironment
            case (lookup "NIX_CFLAGS_COMPILE" env, lookup "NIX_LDFLAGS" env) of
              (Just cflags, Just ldflags) ->
                do abcInclDir <- ordNub <$> filterM hasABCincl (words cflags)
                   abcLibDir <- ordNub . catMaybes <$> mapM chkABClib (words ldflags)
                   case (abcInclDir, abcLibDir) of
                     (i:[],l:[]) -> return $ SystemABC i $ l </> libname
                     ([],_) -> noABCError "a"
                     (_,[]) -> noABCError "b"
                     _ -> error $ "Multiple ABC include locations found: " ++ show abcInclDir
              _ -> noABCError "c"


-- Edit the package description to include the ABC source files,
-- ABC include directories, and static library directories.
abcPkgDesc :: PackageDescription -> IO PackageDescription
abcPkgDesc pkg_desc = do
  -- Note: assumes the script files have previously been built by setupAbc
  abcSrcFiles <- fmap lines $ readFile $ "scripts" </> "abc-sources.txt"
  abcInclDirs <- fmap lines $ readFile $ "scripts" </> "abc-incl-dirs.txt"
  (p,mkBI) <- getABCLib >>= \case
          LocalABC _ lib -> return (pkg_desc, libDirAbc lib)
          SystemABC _ lib -> let fullsrc = extraSrcFiles pkg_desc ++ abcSrcFiles
                                   in return (pkg_desc { extraSrcFiles = fullsrc }, libDirAbc lib)
  return $ updatePackageDescription (mkBI abcInclDirs) p

libDirAbc :: FilePath -> [FilePath] -> HookedBuildInfo
libDirAbc libdir abcInclDirs = (Just buildinfo, [])
    where buildinfo = emptyBuildInfo
                      { includeDirs = abcInclDirs
                      , extraLibDirs = [libdir]
                      }

onWindows :: Monad m => m () -> m ()
onWindows act = case buildPlatform of
                  Platform _ Windows -> act
                  _                  -> return ()

-- call "make clean" in the abc directory, if it exists
cleanAbc :: Verbosity -> IO ()
cleanAbc verbosity = do
    rawSystemExit verbosity "sh" ["scripts" </> "lite-clean-abc.sh"]

-- If necessary, fetch the ABC sources and prepare for building
setupAbc :: Verbosity -> PackageDescription -> IO ()
setupAbc verbosity pkg_desc = do
    putStrLn $ unwords ["Cabal library version:", showVersion Distribution.Simple.Utils.cabalVersion]
    let version = pkgVersion $ package $ pkg_desc
    let packageVersion = "PACKAGE_VERSION"

    abcSrcRoot <- getABCLib >>= \case
      LocalABC incl _ -> return incl
      SystemABC incl _ -> return incl

    allSrcFiles <- let fullpath i = abcSrcRoot </> i
                   in map fullpath <$> getDirectoryContentsRecursive abcSrcRoot

    let isIncl = (==) ".h" . takeExtension
        inclDirs = ordNub . map takeDirectory . filter isIncl

    let isVCSDir d = any (\v -> isInfixOf v d) [ ".hg", ".git" ]
        isBinary f = takeExtension f `elem` [".hgignore", ".o", ".a", ".dll", ".lib"]
        sources = filter (not . isBinary) . filter (not . isVCSDir)

    writeFile ("scripts" </> "abc-incl-dirs.txt") $ unlines $ inclDirs allSrcFiles
    writeFile ("scripts" </> "abc-sources.txt") $ unlines $ sources allSrcFiles


-- Build the ABC library and put the files in the expected places
buildAbc :: Verbosity -> FlagAssignment -> IO ()
buildAbc verbosity fs = getABCLib >>= \case
  LocalABC _ _ -> do
#if MIN_VERSION_Cabal(2,2,0)
    let pthreads = maybe "0" (\x -> if x then "1" else "0") $ lookupFlagAssignment (mkFlagName "enable-pthreads") fs
#else
    let pthreads = maybe "0" (\x -> if x then "1" else "0") $ lookup (mkFlagName "enable-pthreads") fs
#endif
    env <- getEnvironment
    rawSystemExitWithEnv verbosity "sh"
        (("scripts"</>"build-abc.sh") : (tail . words . show $ buildPlatform))
        ([("PTHREADS",pthreads)] ++ filter ((/="PTHREADS") . fst) env)
    createDirectoryIfMissingVerbose verbosity True static_dir
    copyFileVerbose verbosity ("abc-build"</>"libabc.a") (static_dir</>"libabc.a")
    --onWindows $ copyFileVerbose verbosity ("abc-build"</>"libabc.dll") (static_dir</>"abc.dll")
  _ -> return ()  -- nothing to do when supplied by the system.

{-
postCopyAbc :: Args -> CopyFlags -> PackageDescription -> LocalBuildInfo -> IO ()
postCopyAbc _ flags pkg_descr lbi = do
    let installDirs = absoluteInstallDirs pkg_descr lbi
                . fromFlag . copyDest
                $ flags
        libPref = libdir installDirs
        binPref = bindir installDirs
        verbosity = fromFlag $ copyVerbosity flags
        outDir  = libPref
        copy dest f = installOrdinaryFile verbosity (static_dir</>f) (dest</>f)
    createDirectoryIfMissingVerbose verbosity True binPref
    copy libPref "libabc.a"
    --onWindows $ copy libPref "abc.dll"
-}

#if !(MIN_VERSION_Cabal(2,0,0))
mkFlagName :: String -> FlagName
mkFlagName = FlagName
#endif
