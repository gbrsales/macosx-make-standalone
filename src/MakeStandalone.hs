module Main where

-------------------------------------------------------------------------
-- Imports
-------------------------------------------------------------------------

import           Data.Lens.Common
import           Data.Graph.GraphVisit
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Sequence as Seq

import           Control.Monad
import           Control.Monad.State.Strict
import           Control.Monad.Error.Class

import qualified Control.Exception as CE

import           System.Console.GetOpt
import           System.Environment
import           System.IO
import           System.Exit
import           System.FilePath
import           System.Directory hiding (isSymbolicLink)
import           System.Posix.Process
import           System.Posix.Files

import           Opts
import           State
import           Cmds
import           LibDepGraph
import           Plan

-------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  progName <- getProgName

  let optsInit = optProgName ^= progName $ defaultOpts
      oo@(o,n,errs)  = getOpt Permute cmdLineOpts args
      opts           = foldr ($) optsInit o

  case (errs, opts ^. optImmediateCommands, n) of
    (es@(_:_),_       ,_    ) -> forM_ es (hPutStr stderr)
    (_       ,os@(_:_),_    ) -> forM_ os (handleImmediateCommand opts)
    (_       ,_       ,[fnm]) -> doIt opts fnm
    _                         -> do handleImmediateCommand opts ImmediateCommand_Help
                                    exitFailure

doIt :: Opts -> FilePath -> IO ()
doIt opts fnmApp = do
  pid <- getProcessID
  tmpdir <- getTemporaryDirectory
  let st  = initSt opts (RunEnv tmpdir pid fnm)
  flip evalStateT st $
    catchError (do { thework ; cleanup })
               handleerr
 where
  fnm = fpathOfExec opts fnmApp
  thework = do
    ldep <- otoolGraphVisit2LibDepGraph fnm
    when (opts ^. optDebug) (liftIO $ putStrLn (show ldep))
    let plan = seqToList $ ldepGraph2Plan opts fnmApp ldep
    when (opts ^. optDebug) (liftIO $ forM_ plan (putStrLn . show))
    forM_ plan planCmdExec
    return ()
    -- f <- srFreshTmpName
    -- liftIO $ putStrLn f
  cleanup = srRmFilesToRm
  handleerr (e :: CE.IOException) = do
    liftIO $ hPutStrLn stderr (show fnm ++ ": " ++ show e)
    cleanup

-------------------------------------------------------------------------
-- Immediate command handling
-------------------------------------------------------------------------

-- | Handle an immediate command
handleImmediateCommand :: Opts -> ImmediateCommand -> IO ()
handleImmediateCommand opts ImmediateCommand_Help = putStrLn (usageInfo ("Usage: " ++ opts ^. optProgName ++ " [options] <mac app>\n\noptions:") cmdLineOpts)

-------------------------------------------------------------------------
-- Graph walk over the results provided by otool, gathering the library dependency graph
-------------------------------------------------------------------------

otoolGraphVisit2LibDepGraph :: FilePath -> StRun LibDepGraph
otoolGraphVisit2LibDepGraph f = fmap fst $ graphVisitM visit (Set.singleton f) () (initLibDepGraph f)
  where visit t _ fnm = do
          o <- cmdOTool fnm
          (fnm', links) <- liftIO $ symlinkResolve fnm
          return
            ( ldepSymLinks ^%= Map.union (Map.fromList [ (l,fnm') | l <- links ])
              $ ldepGraph ^%= Map.insert fnm' o
              $ t
            , Set.fromList $ o ^. libUses
            )

-------------------------------------------------------------------------
-- Graph walk over the library dependency graph, constructing the modification plan
-------------------------------------------------------------------------

-- ldepGraphVisit2Plan :: LibDepGraph -> StRun Plan

-------------------------------------------------------------------------
-- Compute the modification plan
-------------------------------------------------------------------------

ldepGraph2Plan :: Opts -> FilePath -> LibDepGraph -> Plan
ldepGraph2Plan opts fnmApp ldep =
  Seq.fromList
    [ PlanCmd_CP o n | (n,((o:_),_)) <- Map.toList filesToCopy ]
  Seq.><
    foldr (Seq.><) Seq.empty
      [ Seq.fromList $ PlanCmd_IntlRename n ri : mkModfRef filesToCopy n o
      | (n,((o:_),ri)) <- Map.toList filesToCopy
      ]
  Seq.><
    foldr (Seq.><) Seq.empty
      [ Seq.fromList $ mkModfRef filesToCopy o o
      | (_,((o:_),_)) <- Map.toList filesRoot
      ]
 where
  filesToCopy = mkFilesToCopyMp (Set.delete (ldep ^. ldepRoot) $ Map.keysSet $ ldep ^. ldepGraph)
  filesRoot   = Map.fromList [ (o,([o],o)) | o <- [ldep ^. ldepRoot] ]
  mkFilesToCopyMp fs = Map.fromListWith (\(l1,r1) (l2,_) -> (l1++l2,r1))
    [ (n, ([l],r))
    | l <- Set.toList fs
    , let (n,r) = fpathOfNewLib opts fnmApp l
    ]
  mkFilesToCopyMpRev fMp = Map.fromList [ (o,r) | (n,(os,r)) <- Map.toList fMp, o <- os ]
  mkModfRef fMp n o =
    [ PlanCmd_ModfRef n u rr
    | u <- maybe [] (^. libUses) $ Map.lookup o $ ldep ^. ldepGraph
    , let u2 = ldepResolveSymlink ldep u
          rr = Map.findWithDefault u2 u2 fMpRev
    ]
    where fMpRev = mkFilesToCopyMpRev fMp

-------------------------------------------------------------------------
-- File name manipulation
-------------------------------------------------------------------------

-- | Given app bundle name, return the location of the executable
fpathOfExec :: Opts -> FilePath -> FilePath
fpathOfExec opts fnm = fnm </> opts ^. optInAppLocOfExec </> f
  where (df,e) = splitExtension fnm
        (d,f)  = splitFileName df

-- | Given app bundle name, return the location of the new lib loc plus new name as it is to be used for referring to
fpathOfNewLib :: Opts -> FilePath -> FilePath -> (FilePath,FilePath)
fpathOfNewLib opts fnmApp fnmLib =
  ( fnmApp </> opts ^. optInAppCpLocOfLibDest </> fl
  , opts ^. optInAppRenameLocOfLibDest </> fl
  )
 where
  (_,fl) = splitFileName fnmLib

-- | Normalise path, on top of normal normalise also remove ".."
fpathNormalise :: FilePath -> FilePath
fpathNormalise fnm = joinPath $ reverse $ n [] $ splitDirectories $ normalise fnm
  where n (_:acc) ("..":f) = n    acc  f
        n acc     (x   :f) = n (x:acc) f
        n acc     []       =      acc

-------------------------------------------------------------------------
-- Symbolic link resolution
-------------------------------------------------------------------------

-- | Possibly resolve symbolic link, returning the actual filename + symlinks to it
symlinkResolve :: FilePath -> IO (FilePath, [FilePath])
symlinkResolve fnm = do
  stat <- getSymbolicLinkStatus fnm
  -- putStrLn $ fnm ++ ": " ++ show (isSymbolicLink stat)
  if isSymbolicLink stat
    then do fnmLinkedTo <- fmap (fpathNormalise . (takeDirectory fnm </>)) $ readSymbolicLink fnm
            (fnm',links) <- symlinkResolve fnmLinkedTo
            return (fnm', fnm : links)
    else return (fnm, [])
