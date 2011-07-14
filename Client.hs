module Main where

import Control.Exception
import Control.Monad
import Data.List
import System.Directory
import System.FilePath
import System.Environment
import System.Exit
import System.IO.Error
import System.Posix.Env
import System.Process

import DepsScanner
import Plan
import Store

build :: [String] -> IO ()
build [file] = do
    store <- fmap (</> "cache.git") $ readFile (".." </> ".apters" </> "store")
    (ExitSuccess, out, "") <- readProcessWithExitCode "git" ["rev-parse", "--verify", "HEAD^{tree}"] ""
    let [tag] = lines out
    maybeResult <- evalTag store ("git/" ++ tag)
    case maybeResult of
        Just result -> do
            print result
            exportTag store result file
        Nothing -> putStrLn "Recipe didn't evaluate to a tree; can't export it."
build _ = putStrLn "Usage: apters build <output file>"

clone :: [String] -> IO ()
clone [tag] = clone [tag, tag]
clone [tag, name] = do
    reposDir <- fmap (</> "repos") $ readFile (".apters" </> "store")
    case escapeTagName tag of
        Just hash -> do
            possibleRepos <- getDirectoryContents reposDir
            let containsCommit repo = fmap (== ExitSuccess) $ rawSystem "git" ["--git-dir", reposDir </> repo ++ ".git", "rev-parse", "--quiet", "--no-revs", "--verify", hash ++ "^{commit}"]
            repos <- filterM containsCommit [repo | (repo, ".git") <- map splitExtension possibleRepos]
            ExitSuccess <- rawSystem "git" ["init", name]
            forM_ repos $ \repo -> do
                ExitSuccess <- rawSystem "git" ["--git-dir", name </> ".git", "remote", "add", "-f", repo, reposDir </> repo]
                return ()
            (ExitSuccess, out, "") <- readProcessWithExitCode "git" ["--git-dir", name </> ".git", "for-each-ref", "refs/remotes/"] ""
            let refs = [ref | [hash', "commit", refname] <- map words $ lines out, hash == hash', not $ "/HEAD" `isSuffixOf` refname, let Just ref = stripPrefix "refs/remotes/" refname]
            let args = case refs of
                    [ref] -> ["--track", ref]
                    _ -> [hash]
            (Nothing, Nothing, Nothing, h) <- createProcess (proc "git" (["checkout"] ++ args ++ ["--"])) { cwd = Just name }
            ExitSuccess <- waitForProcess h
            when (length refs > 1) $ do
                putStrLn $ "\nThe commit you've requested matches the head of several branches:"
                forM_ refs $ \ref -> putStrLn $ "  " ++ ref
                putStrLn "You might want to \"git checkout --track $branch\" on one of those branches."
            return ()
        Nothing -> do
            ExitSuccess <- rawSystem "git" ["clone", "--origin", name, reposDir </> name]
            return ()
clone _ = putStrLn "Usage: apters clone <store tag> [<directory>]"

commit :: [String] -> IO ()
commit [] = do
    (ExitSuccess, out, "") <- readProcessWithExitCode "git" ["rev-parse", "--verify", "HEAD^{commit}"] ""
    let [tag] = lines out
    child <- liftM takeFileName getCurrentDirectory
    links <- liftM readLinks $ readFileOrEmpty $ ".." </> ".apters" </> "links"
    forM_ [(parent, dep) | (parent, dep, child') <- links, child == child'] $ \ (parent, dep) -> do
        interactFile (".." </> parent </> "apters.deps") $ \ deps ->
            showDeps $ (dep, "git/" ++ tag) : [p | p@(dep', _) <- getDeps deps, dep /= dep']
commit _ = putStrLn "Usage: apters commit"

expand :: [String] -> IO ()
expand [parent, depname, child] = do
    depsStr <- readFile $ parent </> "apters.deps"
    let Just dep = lookup depname (getDeps depsStr)
    clone [dep, child]
    interactFile (".apters" </> "links") $ \ links ->
        showLinks $ (parent, depname, child) : [l | l@(parent', depname', _) <- readLinks links, not $ parent == parent' && depname == depname']
expand _ = putStrLn "Usage: apters expand <parent_dir> <dependency> <child_dir>"

newrepo :: [String] -> IO ()
newrepo [name] | '/' `notElem` name = do
    store <- readFile (".apters" </> "store")
    let path = "repos" </> name ++ ".git"
    ExitSuccess <- rawSystem "git" ["init", "--bare", store </> path]
    let alternates = store </> "cache.git" </> "objects" </> "info" </> "alternates"
    let objects = ".." </> ".." </> path </> "objects"
    interactFile alternates (unlines . (++ [objects]) . lines)
    clone [name]
newrepo _ = putStrLn "Usage: apters newrepo <name>"

newstore :: [String] -> IO ()
newstore [store] = do
    createDirectoryIfMissing True (store </> "repos")
    ExitSuccess <- rawSystem "git" ["init", "--bare", store </> "cache.git"]
    return ()
newstore _ = putStrLn "Usage: apters newstore <name>"

workspace :: [String] -> IO ()
workspace [url, dir] = do
    createDirectory dir
    let aptersDir = dir </> ".apters"
    createDirectory aptersDir
    writeFile (aptersDir </> "store") url
workspace _ = putStrLn "Usage: apters workspace <store url> <directory>"

help :: [String] -> IO ()
help [] = do
    putStrLn "Usage: apters <command> [<args>]\n\nApters commands:"
    mapM_ (putStrLn . fst) cmds
help (cmd:_) = case lookup cmd cmds of
    Just _ -> putStrLn $ "apters: no help on " ++ cmd ++ " for you!"
    Nothing -> putStrLn $ "apters: '" ++ cmd ++ "' is not an apters command. See 'apters help'."

cmds :: [(String, [String] -> IO ())]
cmds = [("build", build),
        ("clone", clone),
        ("commit", commit),
        ("expand", expand),
        ("newrepo", newrepo),
        ("newstore", newstore),
        ("workspace", workspace),
        ("help", help)]

readFileOrEmpty :: FilePath -> IO String
readFileOrEmpty = handleJust (guard . isDoesNotExistError) (const $ return "") . readFile

interactFile :: FilePath -> (String -> String) -> IO ()
interactFile file f = do
    let tmp = addExtension file "tmp"
    old <- readFileOrEmpty file
    writeFile tmp $ f old
    renameFile tmp file

showDeps :: [(String, String)] -> String
showDeps deps = unlines [key ++ "=" ++ value | (key, value) <- sort deps ]

readLinks :: String -> [(String, String, String)]
readLinks = take3s . split '\0'
    where
    take3s :: [a] -> [(a, a, a)]
    take3s [] = []
    take3s (x:y:z:xs) = (x, y, z) : take3s xs
    take3s _ = error "links file corrupt"
    split :: Eq a => a -> [a] -> [[a]]
    split _ [] = []
    split x xs = case break (== x) xs of (v, xs') -> v : split x (drop 1 xs')

showLinks :: [(String, String, String)] -> String
showLinks = intercalate "\0" . join3s
    where
    join3s :: [(a, a, a)] -> [a]
    join3s [] = []
    join3s ((x, y, z) : xs) = x:y:z:join3s xs

main :: IO ()
main = do
    args <- getArgs
    case args of
        [] -> help []
        cmd:cmdargs -> case lookup cmd cmds of
            Just f -> f cmdargs
            Nothing -> help args
