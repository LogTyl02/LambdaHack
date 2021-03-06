-- | Semantics of server commands.
-- See
-- <https://github.com/kosmikus/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Server
  ( mainSer
  ) where

import Control.Concurrent
import qualified Control.Exception as Ex hiding (handle)
import qualified Data.Text as T
import System.Environment (getArgs)

import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Animation
import Game.LambdaHack.Common.ClientCmd
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.ServerCmd
import Game.LambdaHack.Frontend
import Game.LambdaHack.Server.Action
import Game.LambdaHack.Server.Fov
import Game.LambdaHack.Server.LoopAction
import Game.LambdaHack.Server.ServerSem
import Game.LambdaHack.Server.State
import Game.LambdaHack.Utils.Thread

-- | The semantics of server commands. The resulting boolean value
-- indicates if the command took some time.
cmdSerSem :: (MonadAtomic m, MonadServer m) => CmdSer -> m Bool
cmdSerSem cmd = case cmd of
  TakeTimeSer cmd2 -> cmdSerSemTakeTime cmd2 >> return True
  GameRestartSer aid t -> gameRestartSer aid t >> return False
  GameExitSer aid -> gameExitSer aid >> return False
  GameSaveSer _ -> gameSaveSer >> return False
  CfgDumpSer aid -> cfgDumpSer aid >> return False

cmdSerSemTakeTime :: (MonadAtomic m, MonadServer m) => CmdSerTakeTime -> m ()
cmdSerSemTakeTime cmd = case cmd of
  MoveSer source target -> moveSer source target
  MeleeSer source target -> meleeSer source target
  DisplaceSer source target -> displaceSer source target
  AlterSer source tpos mfeat -> alterSer source tpos mfeat
  WaitSer aid -> waitSer aid
  PickupSer aid i k l -> pickupSer aid i k l
  DropSer aid iid -> dropSer aid iid
  ProjectSer aid p eps iid container -> projectSer aid p eps iid container
  ApplySer aid iid container -> applySer aid iid container
  TriggerSer aid mfeat -> triggerSer aid mfeat
  SetPathSer aid path -> setPathSer aid path

debugArgs :: IO DebugModeSer
debugArgs = do
  args <- getArgs
  let usage =
        [ "Configure debug options here, gameplay options in config.rules.ini."
        , "  --knowMap reveal map for all clients in the next game"
        , "  --knowEvents show all events in the next game (needs --knowMap)"
        , "  --sniffIn display all incoming commands on console "
        , "  --sniffOut display all outgoing commands on console "
        , "  --allClear let all map tiles be translucent"
        , "  --gameMode m start next game in the given mode"
        , "  --newGame start a new game, overwriting the save file"
        , "  --stopAfter n exit this game session after around n seconds"
        , "  --dbgMsgSer let the server emit its internal debug messages"
        , "  --font fn use the given font for the main game window"
        , "  --maxFps n display at most n frames per second"
        , "  --noDelay don't maintain any requested delays between frames"
        , "  --noMore auto-answer all prompts"
        , "  --noAnim don't show any animations"
        , "  --savePrefix prepend the text to all savefile names"
        , "  --frontendStd use the simple stdout/stdin frontend"
        , "  --dbgMsgCli let clients emit their internal debug messages"
        , "  --fovMode m set a Field of View mode, where m can be"
        , "    Digital r, r > 0"
        , "    Permissive"
        , "    Shadow"
        , "    Blind"
        ]
      parseArgs [] = defDebugModeSer
      parseArgs ("--knowMap" : rest) =
        (parseArgs rest) {sknowMap = True}
      parseArgs ("--knowEvents" : rest) =
        (parseArgs rest) {sknowEvents = True}
      parseArgs ("--sniffIn" : rest) =
        (parseArgs rest) {sniffIn = True}
      parseArgs ("--sniffOut" : rest) =
        (parseArgs rest) {sniffOut = True}
      parseArgs ("--allClear" : rest) =
        (parseArgs rest) {sallClear = True}
      parseArgs ("--gameMode" : s : rest) =
        (parseArgs rest) {sgameMode = T.pack s}
      parseArgs ("--newGame" : rest) =
        let debugSer = parseArgs rest
        in debugSer { snewGameSer = True
                    , sdebugCli =
                         (sdebugCli debugSer) {snewGameCli = True}}
      parseArgs ("--stopAfter" : s : rest) =
        (parseArgs rest) {sstopAfter = Just $ read s}
      parseArgs ("--fovMode" : "Digital" : r : rest) | (read r :: Int) > 0 =
        (parseArgs rest) {sfovMode = Just $ Digital $ read r}
      parseArgs ("--fovMode" : mode : rest) =
        (parseArgs rest) {sfovMode = Just $ read mode}
      parseArgs ("--dbgMsgSer" : rest) =
        (parseArgs rest) {sdbgMsgSer = True}
      parseArgs ("--font" : s : rest) =
        let debugSer = parseArgs rest
        in debugSer {sdebugCli = (sdebugCli debugSer) {sfont = Just s}}
      parseArgs ("--maxFps" : n : rest) =
        let debugSer = parseArgs rest
        in debugSer {sdebugCli =
                       (sdebugCli debugSer) {smaxFps = Just $ read n}}
      parseArgs ("--noDelay" : rest) =
        let debugSer = parseArgs rest
        in debugSer {sdebugCli = (sdebugCli debugSer) {snoDelay = True}}
      parseArgs ("--noMore" : rest) =
        let debugSer = parseArgs rest
        in debugSer {sdebugCli = (sdebugCli debugSer) {snoMore = True}}
      parseArgs ("--noAnim" : rest) =
        let debugSer = parseArgs rest
        in debugSer {sdebugCli = (sdebugCli debugSer) {snoAnim = Just True}}
      parseArgs ("--savePrefix" : s : rest) =
        let debugSer = parseArgs rest
        in debugSer { ssavePrefixSer = Just s
                    , sdebugCli =
                         (sdebugCli debugSer) {ssavePrefixCli = Just s}}
      parseArgs ("--frontendStd" : rest) =
        let debugSer = parseArgs rest
        in debugSer {sdebugCli = (sdebugCli debugSer) {sfrontendStd = True}}
      parseArgs ("--dbgMsgCli" : rest) =
        let debugSer = parseArgs rest
        in debugSer {sdebugCli = (sdebugCli debugSer) {sdbgMsgCli = True}}
      parseArgs _ = error $ unlines usage
  return $! parseArgs args

-- | Fire up the frontend with the engine fueled by content.
-- The action monad types to be used are determined by the 'exeSer'
-- and 'executorCli' calls. If other functions are used in their place
-- the types are different and so the whole pattern of computation
-- is different. Which of the frontends is run depends on the flags supplied
-- when compiling the engine library.
mainSer :: (MonadAtomic m, MonadConnServer m)
        => Kind.COps
        -> (m () -> IO ())
        -> (Kind.COps -> DebugModeCli
            -> ((FactionId -> ChanFrontend -> ChanServer CmdClientUI CmdSer
                 -> IO ())
                -> (FactionId -> ChanServer CmdClientAI CmdSerTakeTime
                    -> IO ())
                -> IO ())
            -> IO ())
        -> IO ()
mainSer !copsSlow  -- evaluate fully to discover errors ASAP and free memory
        exeSer exeFront = do
  sdebugNxt <- debugArgs
  let cops = speedupCOps False copsSlow
      loopServer = loopSer sdebugNxt cmdSerSem
      exeServer executorUI executorAI = do
        -- Wait for clients to exit even in case of server crash
        -- (or server and client crash), which gives them time to save.
        -- TODO: send them a message to tell users "server crashed"
        -- and then let them exit.
        Ex.finally
          (exeSer (loopServer executorUI executorAI cops))
          (threadDelay 1000000)  -- server crash, show the error eventually
        waitForChildren childrenServer  -- no crash, wait indefinitely
  exeFront cops (sdebugCli sdebugNxt) exeServer
