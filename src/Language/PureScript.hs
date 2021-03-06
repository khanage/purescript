-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript
-- Copyright   :  (c) 2013-14 Phil Freeman, (c) 2014 Gary Burgess, and other contributors
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
-- The main compiler module
--
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Language.PureScript
  ( module P
  , RebuildPolicy(..)
  , MakeActions(..)
  , SupplyVar()
  , Externs()
  , make
  , version
  ) where

import Data.Function (on)
import Data.List (sortBy, groupBy)
import Data.Maybe (fromMaybe)
import Data.Time.Clock
import Data.Version (Version)
import qualified Data.Map as M
import qualified Data.Set as S

import Control.Applicative
import Control.Arrow ((&&&))
import Control.Monad
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Supply.Class (fresh)

import Language.PureScript.AST as P
import Language.PureScript.Comments as P
import Language.PureScript.CodeGen.Externs (moduleToPs)
import Language.PureScript.Environment as P
import Language.PureScript.Errors as P
import Language.PureScript.Kinds as P
import Language.PureScript.Linter as P
import Language.PureScript.ModuleDependencies as P
import Language.PureScript.Names as P
import Language.PureScript.Options as P
import Language.PureScript.Parser as P
import Language.PureScript.Pretty as P
import Language.PureScript.Renamer as P
import Language.PureScript.Sugar as P
import Control.Monad.Supply as P
import Language.PureScript.TypeChecker as P
import Language.PureScript.Types as P
import qualified Language.PureScript.CoreFn as CoreFn
import qualified Language.PureScript.Constants as C

import qualified Paths_purescript as Paths

-- |
-- Actions that require implementations when running in "make" mode.
--
data MakeActions m = MakeActions {
  -- |
  -- Get the timestamp for the input file(s) for a module. If there are multiple
  -- files (.purs and foreign files, for example) the timestamp should be for
  -- the most recently modified file.
  --
    getInputTimestamp :: ModuleName -> m (Either RebuildPolicy (Maybe UTCTime))
  -- |
  -- Get the timestamp for the output files for a module. This should be the
  -- timestamp for the oldest modified file, or Nothing if any of the required
  -- output files are missing.
  --
  , getOutputTimestamp :: ModuleName -> m (Maybe UTCTime)
  -- |
  -- Read the externs file for a module as a string and also return the actual
  -- path for the file.
  , readExterns :: ModuleName -> m (FilePath, String)
  -- |
  -- Run the code generator for the module and write any required output files.
  --
  , codegen :: CoreFn.Module CoreFn.Ann -> Environment -> SupplyVar -> Externs -> m ()
  -- |
  -- Respond to a progress update.
  --
  , progress :: String -> m ()
  }

-- |
-- Generated code for an externs file.
--
type Externs = String

-- |
-- A value to be used in the Supply monad.
--
type SupplyVar = Integer

-- |
-- Determines when to rebuild a module
--
data RebuildPolicy
  -- | Never rebuild this module
  = RebuildNever
  -- | Always rebuild this module
  | RebuildAlways deriving (Show, Eq, Ord)

-- |
-- Compiles in "make" mode, compiling each module separately to a js files and an externs file
--
-- If timestamps have not changed, the externs file can be used to provide the module's types without
-- having to typecheck the module again.
--
make :: forall m. (Functor m, Applicative m, Monad m, MonadReader P.Options m, MonadError MultipleErrors m, MonadWriter MultipleErrors m)
     => MakeActions m
     -> [(Either RebuildPolicy FilePath, Module)]
     -> m Environment
make MakeActions{..} ms = do
  (sorted, graph) <- sortModules $ map (importPrim . snd) ms
  mapM_ lint sorted
  toRebuild <- foldM (\s (Module _ moduleName' _ _) -> do
    inputTimestamp <- getInputTimestamp moduleName'
    outputTimestamp <- getOutputTimestamp moduleName'
    return $ case (inputTimestamp, outputTimestamp) of
      (Right (Just t1), Just t2) | t1 < t2 -> s
      (Left RebuildNever, Just _) -> s
      _ -> S.insert moduleName' s) S.empty sorted

  marked <- rebuildIfNecessary (reverseDependencies graph) toRebuild sorted
  (desugared, nextVar) <- runSupplyT 0 $ zip (map fst marked) <$> desugar (map snd marked)
  evalSupplyT nextVar $ go initEnvironment desugared
  where

  go :: Environment -> [(Bool, Module)] -> SupplyT m Environment
  go env [] = return env
  go env ((False, m) : ms') = do
    (_, env') <- lift . runCheck' env $ typeCheckModule Nothing m
    go env' ms'
  go env ((True, m@(Module coms moduleName' _ exps)) : ms') = do
    lift $ progress $ "Compiling " ++ runModuleName moduleName'
    (Module _ _ elaborated _, env') <- lift . runCheck' env $ typeCheckModule Nothing m
    regrouped <- createBindingGroups moduleName' . collapseBindingGroups $ elaborated
    let mod' = Module coms moduleName' regrouped exps
        corefn = CoreFn.moduleToCoreFn env' mod'
        [renamed] = renameInModules [corefn]
        exts = moduleToPs mod' env'
    nextVar <- fresh
    lift $ codegen renamed env' nextVar exts
    go env' ms'

  rebuildIfNecessary :: M.Map ModuleName [ModuleName] -> S.Set ModuleName -> [Module] -> m [(Bool, Module)]
  rebuildIfNecessary _ _ [] = return []
  rebuildIfNecessary graph toRebuild (m@(Module _ moduleName' _ _) : ms') | moduleName' `S.member` toRebuild = do
    let deps = fromMaybe [] $ moduleName' `M.lookup` graph
        toRebuild' = toRebuild `S.union` S.fromList deps
    (:) (True, m) <$> rebuildIfNecessary graph toRebuild' ms'
  rebuildIfNecessary graph toRebuild (Module _ moduleName' _ _ : ms') = do
    (path, externs) <- readExterns moduleName'
    externsModules <- fmap (map snd) . alterErrors $ P.parseModulesFromFiles id [(path, externs)]
    case externsModules of
      [m'@(Module _ moduleName'' _ _)] | moduleName'' == moduleName' -> (:) (False, m') <$> rebuildIfNecessary graph toRebuild ms'
      _ -> throwError . errorMessage . InvalidExternsFile $ path
    where
    alterErrors = flip catchError $ \(MultipleErrors errs) ->
      throwError . MultipleErrors $ flip map errs $ \e -> case e of
        SimpleErrorWrapper (ErrorParsingModule err) -> SimpleErrorWrapper (ErrorParsingExterns err)
        _ -> e

reverseDependencies :: ModuleGraph -> M.Map ModuleName [ModuleName]
reverseDependencies g = combine [ (dep, mn) | (mn, deps) <- g, dep <- deps ]
  where
  combine :: (Ord a) => [(a, b)] -> M.Map a [b]
  combine = M.fromList . map ((fst . head) &&& map snd) . groupBy ((==) `on` fst) . sortBy (compare `on` fst)

-- |
-- Add an import declaration for a module if it does not already explicitly import it.
--
addDefaultImport :: ModuleName -> Module -> Module
addDefaultImport toImport m@(Module coms mn decls exps)  =
  if isExistingImport `any` decls || mn == toImport then m
  else Module coms mn (ImportDeclaration toImport Implicit Nothing : decls) exps
  where
  isExistingImport (ImportDeclaration mn' _ _) | mn' == toImport = True
  isExistingImport (PositionedDeclaration _ _ d) = isExistingImport d
  isExistingImport _ = False

importPrim :: Module -> Module
importPrim = addDefaultImport (ModuleName [ProperName C.prim])

version :: Version
version = Paths.version
