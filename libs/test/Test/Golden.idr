||| Core features required to perform Golden file testing.
|||
||| We provide the core functionality to run a *single* golden file test, or
||| a whole test tree.
||| This allows the developer freedom to use as is or design the rest of the
||| test harness to their liking.
|||
||| This was originally used as part of Idris2's own test suite and
||| the core functionality is useful for the many and not the few.
||| Please see Idris2 test harness for example usage.
|||
||| # Test Structure
|||
||| This harness works from the assumption that each individual golden test
||| comprises of a directory with the following structure:
|||
||| + `run` a *shell* script that runs the test. We expect it to:
|||   * Use `$1` as the variable standing for the idris executable to be tested
|||   * May use `${IDRIS2_TESTS_CG}` to pick a codegen that ought to work
|||   * Clean up after itself (e.g. by running `rm -rf build/`)
|||
||| + `expected` a file containting the expected output of `run`
|||
||| During testing, the test harness will generate an artefact named `output`
||| and display both outputs if there is a failure.
||| During an interactive session the following command is used to compare them
||| as they are:
|||
||| ```sh
|||  git diff --no-index --exit-code --word-diff=color expected output
||| ```
|||
||| If `git` fails then the runner will simply present the expected and 'given'
||| files side-by-side.
|||
||| Of note, it is helpful to add `output` to a local `.gitignore` instance
||| to ensure that it is not mistakenly versioned.
|||
||| # Options
|||
||| The test harness has several options that may be set:
|||
||| + `idris2`       The path of the executable we are testing.
||| + `codegen`      The backend to use for code generation.
||| + `onlyNames`    The tests to run relative to the generated executable.
||| + `onlyFile`     The file listing the tests to run relative to the generated executable.
||| + `interactive`  Whether to offer to update the expected file or not.
||| + `timing`       Whether to display time taken for each test.
||| + `threads`      The maximum numbers to use (default: number of cores).
||| + `failureFile`  The file in which to write the list of failing tests.
|||
||| We provide an options parser (`options`) that takes the list of command line
||| arguments and constructs this for you.
|||
||| # Usage
|||
||| When compiled to an executable the expected usage is:
|||
|||```sh
|||runtests <path to executable under test> [--timing] [--interactive] [--cg CODEGEN] [--threads N] [--only [NAMES]]
|||```
|||
||| assuming that the test runner is compiled to an executable named `runtests`.

module Test.Golden

import Data.Either
import Data.Maybe
import Data.List
import Data.List1
import Data.Strings

import System
import System.Clock
import System.Directory
import System.File
import System.Future
import System.Info
import System.Path

-- [ Options ]

||| Options for the test driver.
public export
record Options where
  constructor MkOptions
  ||| Name of the idris2 executable
  exeUnderTest : String
  ||| Which codegen should we use?
  codegen      : Maybe String
  ||| Should we only run some specific cases?
  onlyNames    : List String
  ||| Should we run the test suite interactively?
  interactive  : Bool
  ||| Should we time and display the tests
  timing       : Bool
  ||| How many threads should we use?
  threads      : Nat
  ||| Should we write the list of failing cases from a file?
  failureFile     : Maybe String

export
initOptions : String -> Options
initOptions exe
  = MkOptions exe
              Nothing
              []
              False
              False
              1
              Nothing

export
usage : String -> String
usage exe = unwords
  ["Usage:", exe
  , "runtests <path>"
  , "[--timing]"
  , "[--interactive]"
  , "[--cg CODEGEN]"
  , "[--threads N]"
  , "[--failure-file PATH]"
  , "[--only-file PATH]"
  , "[--only [NAMES]]"
  ]

export
fail : String -> IO a
fail err
    = do putStrLn err
         exitWith (ExitFailure 1)

||| Process the command line options.
export
options : List String -> IO (Maybe Options)
options args = case args of
    (_ :: exe :: rest) => mkOptions exe rest
    _ => pure Nothing

  where

    go : List String -> Maybe String -> Options -> Maybe (Maybe String, Options)
    go rest only opts = case rest of
      []                            => pure (only, opts)
      ("--timing" :: xs)            => go xs only (record { timing = True} opts)
      ("--interactive" :: xs)       => go xs only (record { interactive = True } opts)
      ("--cg" :: cg :: xs)          => go xs only (record { codegen = Just cg } opts)
      ("--threads" :: n :: xs)      => do let pos : Nat = !(parsePositive n)
                                          go xs only (record { threads = pos } opts)
      ("--failure-file" :: p :: xs) => go  xs only (record { failureFile = Just p } opts)
      ("--only" :: xs)              => pure (only, record { onlyNames = xs } opts)
      ("--only-file" :: p :: xs)    => go xs (Just p) opts
      _ => Nothing

    mkOptions : String -> List String -> IO (Maybe Options)
    mkOptions exe rest
      = do let Just (mfp, opts) = go rest Nothing (initOptions exe)
                 | Nothing => pure Nothing
           let Just fp = mfp
                 | Nothing => pure (Just opts)
           Right only <- readFile fp
             | Left err => fail (show err)
           pure $ Just $ record { onlyNames $= (forget (lines only) ++) } opts

||| Normalise strings between different OS.
|||
||| on Windows, we just ignore backslashes and slashes when comparing,
||| similarity up to that is good enough. Leave errors that depend
||| on the confusion of slashes and backslashes to unix machines.
normalize : String -> String
normalize str =
    if isWindows
      then pack $ filter (\ch => ch /= '/' && ch /= '\\') (unpack str)
      else str

||| The result of a test run
||| `Left` corresponds to a failure, and `Right` to a success
Result : Type
Result = Either String String

||| Run the specified Golden test with the supplied options.
|||
||| See the module documentation for more information.
|||
||| @testPath the directory that contains the test.
export
runTest : Options -> String -> IO (Future Result)
runTest opts testPath = forkIO $ do
  start <- clockTime Thread
  let cg = case codegen opts of
         Nothing => ""
         Just cg => "env IDRIS2_TESTS_CG=" ++ cg ++ " "
  ignore $ system $ "cd " ++ testPath ++ " && " ++
    cg ++ "sh ./run " ++ exeUnderTest opts ++ " | tr -d '\\r' > output"
  end <- clockTime Thread

  Right out <- readFile $ testPath ++ "/output"
    | Left err => do print err
                     pure (Left testPath)

  Right exp <- readFile $ testPath ++ "/expected"
    | Left FileNotFound => do
        if interactive opts
          then mayOverwrite Nothing out
          else print FileNotFound
        pure (Left testPath)
    | Left err => do print err
                     pure (Left testPath)

  let result = normalize out == normalize exp
  let time = timeDifference end start

  if result
    then printTiming (timing opts) time $ testPath ++ ": success"
    else do
      printTiming (timing opts) time $ testPath ++ ": FAILURE"
      if interactive opts
        then mayOverwrite (Just exp) out
        else putStrLn . unlines $ expVsOut exp out

  pure $ if result then Right testPath else Left testPath

  where
    getAnswer : IO Bool
    getAnswer = do
      str <- getLine
      case str of
        "y" => pure True
        "n" => pure False
        _   => do putStrLn "Invalid Answer."
                  getAnswer

    expVsOut : String -> String -> List String
    expVsOut exp out = ["Expected:", exp, "Given:", out]

    mayOverwrite : Maybe String -> String -> IO ()
    mayOverwrite mexp out = do
      case mexp of
        Nothing => putStr $ unlines
          [ "Golden value missing. I computed the following result:"
          , out
          , "Accept new golden value? [yn]"
          ]
        Just exp => do
          code <- system $ "git diff --no-index --exit-code --word-diff=color " ++
            testPath ++ "/expected " ++ testPath ++ "/output"
          putStrLn . unlines $
            ["Golden value differs from actual value."] ++
            (if (code < 0) then expVsOut exp out else []) ++
            ["Accept actual value as new golden value? [yn]"]
      b <- getAnswer
      when b $ do Right _ <- writeFile (testPath ++ "/expected") out
                    | Left err => print err
                  pure ()

    printTiming : Bool -> Clock type -> String -> IO ()
    printTiming True  clock msg = putStrLn (unwords [msg, show clock])
    printTiming False _     msg = putStrLn msg

||| Find the first occurrence of an executable on `PATH`.
export
pathLookup : List String -> IO (Maybe String)
pathLookup names = do
  path <- getEnv "PATH"
  let extensions = if isWindows then [".exe", ".cmd", ".bat", ""] else [""]
  let pathList = forget $ split (== pathSeparator) $ fromMaybe "/usr/bin:/usr/local/bin" path
  let candidates = [p ++ "/" ++ x ++ y | p <- pathList,
                                         x <- names,
                                         y <- extensions]
  firstExists candidates


||| Some test may involve Idris' backends and have requirements.
||| We define here the ones supported by Idris
public export
data Requirement = C | Chez | Node | Racket | Gambit

export
Show Requirement where
  show C = "C"
  show Chez = "Chez"
  show Node = "node"
  show Racket = "racket"
  show Gambit = "gambit"

export
checkRequirement : Requirement -> IO (Maybe String)
checkRequirement req
  = if platformSupport req
      then do let (envvar, paths) = requirement req
              Just exec <- getEnv envvar | Nothing => pathLookup paths
              pure (Just exec)
      else pure Nothing
  where
    requirement : Requirement -> (String, List String)
    requirement C = ("CC", ["cc"])
    requirement Chez = ("CHEZ", ["chez", "chezscheme9.5", "scheme"])
    requirement Node = ("NODE", ["node"])
    requirement Racket = ("RACKET", ["racket"])
    requirement Gambit = ("GAMBIT", ["gsc"])
    platformSupport : Requirement -> Bool
    platformSupport C = not isWindows
    platformSupport Racket = not isWindows
    platformSupport _ = True

export
findCG : IO (Maybe String)
findCG
  = do Nothing <- getEnv "IDRIS2_TESTS_CG" | p => pure p
       Nothing <- checkRequirement Chez    | p => pure (Just "chez")
       Nothing <- checkRequirement Node    | p => pure (Just "node")
       Nothing <- checkRequirement Racket  | p => pure (Just "racket")
       Nothing <- checkRequirement Gambit  | p => pure (Just "gsc")
       Nothing <- checkRequirement C       | p => pure (Just "refc")
       pure Nothing

||| A test pool is characterised by
|||  + a list of requirement
|||  + and a list of directory paths
public export
record TestPool where
  constructor MkTestPool
  poolName : String
  constraints : List Requirement
  testCases : List String

||| Only keep the tests that have been asked for
export
filterTests : Options -> List String -> List String
filterTests opts = case onlyNames opts of
  [] => id
  xs => filter (\ name => any (`isInfixOf` name) xs)

||| The summary of a test pool run
public export
record Summary where
  constructor MkSummary
  success : List String
  failure : List String

export
initSummary : Summary
initSummary = MkSummary [] []

export
updateSummary : List Result -> Summary -> Summary
updateSummary res =
  let (ls, ws) = partitionEithers res in
  { success $= (ws ++)
  , failure $= (ls ++)
  }

export
Semigroup Summary where
  MkSummary ws1 ls1 <+> MkSummary ws2 ls2
    = MkSummary (ws1 ++ ws2) (ls1 ++ ls2)

export
Monoid Summary where
  neutral = initSummary

||| A runner for a test pool
export
poolRunner : Options -> TestPool -> IO Summary
poolRunner opts pool
  = do -- check that we indeed want to run some of these tests
       let tests = filterTests opts (testCases pool)
       let (_ :: _) = tests
             | [] => pure initSummary
       putStrLn banner
       -- if so make sure the constraints are satisfied
       cs <- for (constraints pool) $ \ req => do
          mfp <- checkRequirement req
          putStrLn $ case mfp of
            Nothing => show req ++ " not found"
            Just fp => "Found " ++ show req ++ " at " ++ fp
          pure mfp
       let Just _ = the (Maybe (List String)) (sequence cs)
             | Nothing => pure initSummary
       -- if so run them all!
       loop initSummary tests

  where

    banner : String
    banner =
      let separator = fastPack $ replicate 72 '-' in
      fastUnlines [ "", separator, pool.poolName, separator, "" ]

    loop : Summary -> List String -> IO Summary
    loop acc [] = pure acc
    loop acc tests
      = do let (now, later) = splitAt opts.threads tests
           bs <- map await <$> traverse (runTest opts) now
           loop (updateSummary bs acc) later


||| A runner for a whole test suite
export
runner : List TestPool -> IO ()
runner tests
    = do args <- getArgs
         Just opts <- options args
            | _ => do print args
                      putStrLn (usage "runtests")
         -- if no CG has been set, find a sensible default based on what is available
         opts <- case codegen opts of
                   Nothing => pure $ record { codegen = !findCG } opts
                   Just _ => pure opts
         -- run the tests
         res <- concat <$> traverse (poolRunner opts) tests

         -- report the result
         let nsucc  = length res.success
         let nfail  = length res.failure
         let ntotal = nsucc + nfail
         putStrLn (show nsucc ++ "/" ++ show ntotal ++ " tests successful")

         -- deal with failures
         let list = fastUnlines res.failure
         when (nfail > 0) $
           do putStrLn "Failing tests:"
              putStrLn list
         -- always overwrite the failure file, if it is given
         whenJust opts.failureFile $ \ path =>
           do Right _ <- writeFile path list
                | Left err => fail (show err)
              pure ()

         -- exit
         if nfail == 0
           then exitWith ExitSuccess
           else exitWith (ExitFailure 1)

-- [ EOF ]
