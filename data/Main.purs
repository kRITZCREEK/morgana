module Main where

import Prelude
import Node.Process as Process
import Ansi.Codes (Color(Blue))
import Control.Apply ((*>))
import Control.Monad (when)
import Control.Monad.Aff (attempt, runAff, launchAff, later')
import Control.Monad.Aff.AVar (AVAR)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (log, CONSOLE)
import Control.Monad.Eff.Exception (EXCEPTION)
import Control.Monad.Eff.Ref (writeRef, readRef, Ref, newRef, REF)
import Control.Monad.Reader.Class (ask)
import Control.Monad.Reader.Trans (runReaderT, ReaderT)
import Control.Monad.ST (runST)
import Data.Argonaut (Json)
import Data.Array (head, null)
import Data.Either (isRight, isLeft, Either(Left, Right), either)
import Data.Function.Eff (runEffFn2, EffFn2)
import Data.Functor (($>))
import Data.Maybe (Maybe(Just, Nothing))
import Node.ChildProcess (CHILD_PROCESS)
import Node.FS (FS)
import PscIde (sendCommandR, load, cwd, NET)
import PscIde.Command (Command(RebuildCmd), Message(Message))
import Pscid.Console (clearConsole, owl, startScreen, logColored)
import Pscid.Error (catchLog, noSourceDirectoryError)
import Pscid.Keypress (Key(Key), onKeypress, initializeKeypresses)
import Pscid.Options (PscidOptions, optionParser)
import Pscid.Process (execCommand)
import Pscid.Psa (filterWarnings, PsaError, parseErrors, psaPrinter)
import Pscid.Server (restartServer, stopServer, startServer)
import Pscid.Util (both, (∘))
import Suggest (applySuggestions)

type Pscid e a = ReaderT PscidOptions (Eff e) a

newtype State = State { errors :: Array PsaError }

emptyState :: State
emptyState = State { errors: [] }

main ∷ ∀ e. Eff ( err ∷ EXCEPTION, cp ∷ CHILD_PROCESS
                , console ∷ CONSOLE , net ∷ NET
                , avar ∷ AVAR, fs ∷ FS, process ∷ Process.PROCESS
                , ref :: REF | e) Unit
main = launchAff do
  config@{ port, sourceDirectories } ← liftEff optionParser
  when (null sourceDirectories) (liftEff noSourceDirectoryError)
  stateRef <- liftEff (newRef emptyState)
  liftEff (log "Starting psc-ide-server")
  r ← attempt (startServer "psc-ide-server" port Nothing)
  when (isLeft r) (restartServer port)
  Message directory ← later' 100 do
    load port [] []
    res ← cwd port
    case res of
      Right d → pure d
      Left err → liftEff do
        log err
        Process.exit 1
  liftEff do
    runEffFn2 gaze
      (sourceDirectories <#> \g → directory <> "/" <> g <> "/**/*.purs")
      (\d → runReaderT (triggerRebuild stateRef d) config)
    clearConsole
    initializeKeypresses
    onKeypress (\k → runReaderT (keyHandler stateRef k) config)
    log ("Watching " <> directory <> " on port " <> show port)
    startScreen

keyHandler
  ∷ ∀ e
  . Ref State
  → Key
  → Pscid ( console ∷ CONSOLE , cp ∷ CHILD_PROCESS
          , process ∷ Process.PROCESS , net ∷ NET
          , fs ∷ FS, avar ∷ AVAR, ref ∷ REF | e) Unit
keyHandler stateRef k = do
  {port, buildCommand, testCommand} ← ask
  case k of
    Key {ctrl: false, name: "b", meta: false, shift: false} →
      liftEff (execCommand "Build" buildCommand)
    Key {ctrl: false, name: "t", meta: false, shift: false} →
      liftEff (execCommand "Test" testCommand)
    Key {ctrl: false, name: "r", meta: false, shift: false} → liftEff do
      clearConsole
      catchLog "Failed to restart server" $ launchAff do
        restartServer port
        load port [] []
      log owl
    Key {ctrl: false, name: "s", meta: false, shift: false} → liftEff do
      State state ← readRef stateRef
      case head state.errors of
        Nothing →
          log "No suggestions available"
        Just e →
          catchLog "Couldn't apply suggestion." (runST (applySuggestions [e]))
    Key {ctrl: false, name: "q", meta: false, shift: false} →
      liftEff (log "Bye!" *> runAff exit exit (stopServer port))
    Key {ctrl, name, meta, shift} →
      liftEff (log name)
  where
    exit ∷ ∀ a eff. a → Eff (process ∷ Process.PROCESS | eff) Unit
    exit = const (Process.exit 0)

triggerRebuild
  ∷ ∀ e
  . Ref State
  → String
  → Pscid ( cp ∷ CHILD_PROCESS, net ∷ NET
          , console ∷ CONSOLE, fs ∷ FS
          , ref ∷ REF| e) Unit
triggerRebuild stateRef file = do
  {port, testCommand, testAfterRebuild, censorCodes} ← ask
  liftEff ∘ catchLog "We couldn't talk to the server" $ launchAff do
    result ← sendCommandR port (RebuildCmd file)
    case result of
      Left _ → liftEff (log "We couldn't talk to the server")
      Right errs → do
        parsedErrors ← liftEff (handleRebuildResult file censorCodes errs)
        liftEff (writeRef stateRef (State {errors: parsedErrors}))
        case head parsedErrors >>= _.suggestion of
          Nothing → pure unit
          Just s → liftEff (logColored Blue "Press s to automatically apply the suggestion.")
        liftEff $ when (testAfterRebuild && isRight errs)
          (execCommand "Test" testCommand)

handleRebuildResult
  ∷ ∀ e
  . String
  → Array String
  → Either Json Json
  → Eff (console ∷ CONSOLE, fs ∷ FS | e) (Array PsaError)
handleRebuildResult file censorCodes result = do
  clearConsole
  log ("Checking " <> file)
  case both parseErrors result of
    Right warnings →
      either
        (\_ → log "Failed to parse warnings" $> [])
        (\e → psaPrinter owl false e $> e)
        (filterWarnings censorCodes <$> warnings)
    Left errors →
      either
        (\_ → log "Failed to parse errors" $> [])
        (\e → psaPrinter owl true e $> e)
        errors

foreign import gaze
  ∷ ∀ eff
  . EffFn2 (fs ∷ FS | eff)
      (Array String)
      (String → Eff (fs ∷ FS | eff) Unit)
      Unit

