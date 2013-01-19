{-# LANGUAGE OverloadedStrings, RankNTypes #-}
-- | Game action monads and basic building blocks for human and computer
-- player actions. Has no access to the the main action type.
-- Does not export the @liftIO@ operation nor a few other implementation
-- details.
module Game.LambdaHack.Server.Action
  ( -- * Action monads
    MonadServerRO( getServer, getsServer )
  , MonadServer( putServer, modifyServer )
  , MonadServerChan
  , executorSer
    -- * Accessor to the Perception Reader
  , askPerceptionSer
    -- * Turn init operations
  , withPerception, remember
    -- * Assorted primitives
  , saveGameBkp, dumpCfg, endOrLoop, gameReset
  , switchGlobalSelectedSide
  , sendUpdateCli, sendQueryCli, sendAIQueryCli
  , broadcastCli, broadcastPosCli
  , addHero
  ) where

import Control.Concurrent
import Control.Exception (finally)
import Control.Monad
import Control.Monad.Reader.Class
import qualified Control.Monad.State as St
import qualified Data.Char as Char
import Data.Dynamic
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import Data.List
import qualified Data.Map as M
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified System.Random as R
import System.Time
import Control.Arrow (second)

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.CmdCli
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Faction
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Perception
import Game.LambdaHack.Point
import Game.LambdaHack.Random
import Game.LambdaHack.Server.Action.ActionClass (MonadServerRO(..), MonadServer(..), MonadServerChan(..))
import Game.LambdaHack.Server.Action.ActionType (executorSer)
import qualified Game.LambdaHack.Server.Action.ConfigIO as ConfigIO
import Game.LambdaHack.Server.Action.HighScore (register)
import qualified Game.LambdaHack.Server.Action.Save as Save
import Game.LambdaHack.Server.Config
import qualified Game.LambdaHack.Server.DungeonGen as DungeonGen
import Game.LambdaHack.Server.Fov
import Game.LambdaHack.Server.State
import Game.LambdaHack.State
import Game.LambdaHack.Utils.Assert

-- | Update the cached perception for the selected level, for all factions,
-- for the given computation. The assumption is the level, and only the level,
-- has changed since the previous perception calculation.
withPerception :: MonadServerRO m => m () -> m ()
withPerception m = do
  cops <- getsState scops
  configFovMode <- getsServer (configFovMode . sconfig)
  sdebugSer <- getsServer sdebugSer
  lvl <- getsState getArena
  arena <- getsState sarena
  let tryFov = stryFov sdebugSer
      fovMode = fromMaybe configFovMode tryFov
      per side = levelPerception cops fovMode side lvl
  local (IM.mapWithKey (\side lp -> M.insert arena (per side) lp)) m

-- | Get the current perception of the server.
askPerceptionSer :: MonadServerRO m => m Perception
askPerceptionSer = do
  lid <- getsState sarena
  pers <- ask
  side <- getsState sside
  return $! pers IM.! side M.! lid

-- | Update all factions memory of the current level.
--
-- This has to be strict wrt map operation sor we leak one perception
-- per turn. This has to lazy wrt the perception sets or we compute them
-- for factions that do not move, perceive or not even reside on the level.
-- When clients and server communicate via network the communication
-- has to be explicitely lazy and multiple updates have to collapsed
-- when sending is forced by the server asking a client to perceive
-- something or to act.
remember :: MonadServerChan m => m ()
remember = do
  arena <- getsState sarena
  lvl <- getsState getArena
  faction <- getsState sfaction
  pers <- ask
  funBroadcastCli (\fid ->
    RememberPerCli arena (pers IM.! fid M.! arena) lvl faction)
  funAIBroadcastCli (\fid ->
    RememberPerCli arena (pers IM.! fid M.! arena) lvl faction)

-- | Save the history and a backup of the save game file, in case of crashes.
--
-- See 'Save.saveGameBkp'.
saveGameBkp :: MonadServerChan m => m ()
saveGameBkp = do
  -- Only save regular clients, AI clients will restore from the same saves.
  -- TODO: also save the targets from AI clients
  broadcastCli [] $ GameSaveCli True
  glo <- getState
  ser <- getServer
  config <- getsServer sconfig
  liftIO $ Save.saveGameBkpSer config glo ser

-- | Dumps the current game rules configuration to a file.
dumpCfg :: MonadServer m => FilePath -> m ()
dumpCfg fn = do
  config <- getsServer sconfig
  liftIO $ ConfigIO.dump config fn

-- | Handle current score and display it with the high scores.
-- Aborts if display of the scores was interrupted by the user.
--
-- Warning: scores are shown during the game,
-- so we should be careful not to leak secret information through them
-- (e.g., the nature of the items through the total worth of inventory).
handleScores :: MonadServerChan m => Bool -> Status -> Int -> m ()
handleScores write status total =
  when (total /= 0) $ do
    config <- getsServer sconfig
    time <- getsState getTime
    curDate <- liftIO getClockTime
    slides <-
      liftIO $ register config write total time curDate status
    side <- getsState sside
    go <- sendQueryCli side $ ShowSlidesCli slides
    when (not go) abort

-- | Continue or restart or exit the game.
endOrLoop :: MonadServerChan m => m () -> m ()
endOrLoop loopServer = do
  squit <- getsServer squit
  side <- getsState sside
  gquit <- getsState $ gquit . (IM.! side) . sfaction
  s <- getState
  ser <- getServer
  config <- getsServer sconfig
  let (_, total) = calculateTotal s
  -- The first, boolean component of squit determines
  -- if ending screens should be shown, the other argument describes
  -- the cause of the disruption of game flow.
  case (squit, gquit) of
    (Just _, _) -> do
      -- Save and display in parallel.
      mv <- liftIO newEmptyMVar
      liftIO $ void
        $ forkIO (Save.saveGameSer config s ser
                  `finally` putMVar mv ())
      broadcastCli [] $ GameSaveCli False
      tryIgnore $ do
        handleScores False Camping total
        broadcastPosCli [] $ MoreFullCli "See you soon, stronger and braver!"
      liftIO $ takeMVar mv  -- wait until saved
      -- Do nothing, that is, quit the game loop.
    (Nothing, Just (showScreens, status@Killed{})) -> do
      nullR <- sendQueryCli side NullReportCli
      unless nullR $ do
        -- Sisplay any leftover report. Suggest it could be the cause of death.
        broadcastPosCli [] $ MoreBWCli "Who would have thought?"
      tryWith
        (\ finalMsg ->
          let highScoreMsg = "Let's hope another party can save the day!"
              msg = if T.null finalMsg then highScoreMsg else finalMsg
          in broadcastPosCli [] $ MoreBWCli msg
          -- Do nothing, that is, quit the game loop.
        )
        (do
           when showScreens $ handleScores True status total
           go <- sendQueryCli side
                 $ ConfirmMoreBWCli "Next time will be different."
           when (not go) $ abortWith "You could really win this time."
           restartGame loopServer
        )
    (Nothing, Just (showScreens, status@Victor)) -> do
      nullR <- sendQueryCli side NullReportCli
      unless nullR $ do
        -- Sisplay any leftover report. Suggest it could be the master move.
        broadcastPosCli [] $ MoreFullCli "Brilliant, wasn't it?"
      when showScreens $ do
        tryIgnore $ handleScores True status total
        broadcastPosCli [] $ MoreFullCli "Can it be done better, though?"
      restartGame loopServer
    (Nothing, Just (_, Restart)) -> do
      broadcastPosCli [] $ MoreBWCli "This time for real."
      restartGame loopServer
    (Nothing, _) -> loopServer  -- just continue

restartGame :: MonadServerChan m => m () -> m ()
restartGame loopServer = do
  -- Take the original config from config file, to reroll RNG, if needed
  -- (the current config file has the RNG rolled for the previous game).
  cops <- getsState scops
  (state, ser, funRestart) <- gameResetAction cops
  putState state
  putServer ser
  funBroadcastCli (\fid -> let (sper, loc) = funRestart fid
                           in RestartCli sper loc)
  -- TODO: send to each client RestartCli; use d in its code; empty channels?
  saveGameBkp
  loopServer

-- | Find a hero name in the config file, or create a stock name.
findHeroName :: Config -> Int -> Text
findHeroName Config{configHeroNames} n =
  let heroName = lookup n configHeroNames
  in fromMaybe ("hero number" <+> showT n) heroName

-- | Create a new hero on the current level, close to the given position.
addHero :: Kind.COps -> Point -> FactionId -> State -> StateServer
        -> (State, StateServer)
addHero Kind.COps{coactor, cotile} ppos side
        s ser@StateServer{scounter} =
  let config@Config{configBaseHP} = sconfig ser
      loc = nearbyFreePos cotile ppos s
      freeHeroK = elemIndex Nothing $ map (tryFindHeroK s side) [0..9]
      n = fromMaybe 100 freeHeroK
      symbol = if n < 1 || n > 9 then '@' else Char.intToDigit n
      name = findHeroName config n
      startHP = configBaseHP - (configBaseHP `div` 5) * min 3 n
      m = template (heroKindId coactor) (Just symbol) (Just name)
                   startHP loc (getTime s) side False
  in ( updateArena (updateActor (IM.insert scounter m)) s
     , ser { scounter = scounter + 1 } )

-- | Create a set of initial heroes on the current level, at position ploc.
initialHeroes :: Kind.COps -> Point -> FactionId -> State -> StateServer
              -> (State, StateServer)
initialHeroes cops ppos side s ser =
  let Config{configExtraHeroes} = sconfig ser
      k = 1 + configExtraHeroes
  in iterate (uncurry $ addHero cops ppos side) (s, ser) !! k

createFactions :: Kind.COps -> Config -> Rnd FactionDict
createFactions Kind.COps{ cofact=Kind.Ops{opick, okind}
                        , costrat=Kind.Ops{opick=sopick} } config = do
  let g isHuman (fType, gname) = do
        gkind <- opick fType (const True)
        let fk = okind gkind
            genemy = []  -- fixed below
            gally  = []  -- fixed below
            gquit = Nothing
        gAiLeader <-
          if isHuman
          then return Nothing
          else fmap Just $ sopick (fAiLeader fk) (const True)
        gAiMember <- sopick (fAiMember fk) (const True)
        return Faction{..}
  lHuman <- mapM (g True) (configHuman config)
  lComputer <- mapM (g False) (configComputer config)
  let rawFs = zip [1..] $ lHuman ++ lComputer
      isOfType fType fact =
        let fk = okind $ gkind fact
        in case lookup fType $ ffreq fk of
          Just n | n > 0 -> True
          _ -> False
      enemyAlly fact =
        let f fType = filter (isOfType fType . snd) rawFs
            fk = okind $ gkind fact
            setEnemy = IS.fromList $ map fst $ concatMap f $ fenemy fk
            setAlly  = IS.fromList $ map fst $ concatMap f $ fally fk
            genemy = IS.toList setEnemy
            gally = IS.toList $ setAlly IS.\\ setEnemy
        in fact {genemy, gally}
  return $! IM.fromDistinctAscList $ map (second enemyAlly) rawFs

-- TODO: do this inside Action ()
gameReset :: Kind.COps
          -> IO (State, StateServer, FactionId -> (FactionPers, State))
gameReset cops@Kind.COps{ coitem, corule} = do
  -- Rules config reloaded at each new game start.
  (sconfig, dungeonGen, random) <- ConfigIO.mkConfigRules corule
  randomCli <- R.newStdGen  -- TODO: each AI client should have one
  -- from sconfig (only known to server), other clients each should have
  -- one known only to them (or server, if needed)
  let rnd :: Rnd (State, StateServer, FactionId -> (FactionPers, State))
      rnd = do
        faction <- createFactions cops sconfig
        let notSpawning (_, fact) = not $ isSpawningFact cops fact
            needInitialCrew = map fst $ filter notSpawning $ IM.toList faction
        sflavour <- dungeonFlavourMap coitem
        (discoS, discoRev) <- serverDiscos coitem
        DungeonGen.FreshDungeon{..} <-
          DungeonGen.dungeonGen
            cops sflavour discoRev sconfig (length needInitialCrew)
        let defState =
              defStateGlobal freshDungeon freshDepth discoS faction
                             cops random entryLevel
            defSer = defStateServer discoRev sflavour sconfig
            fo (fid, epos) (gloF, serF) =
              initialHeroes cops epos fid gloF serF
            (glo, ser) =
              foldr fo (defState, defSer) $ zip needInitialCrew entryPoss
            -- This state is quite small, fit for transmition to the client.
            -- The biggest part is content, which really needs to be updated
            -- at this point to keep clients in sync with server improvements.
            defLoc = defStateLocal cops freshDungeon discoS
                                   freshDepth faction randomCli entryLevel
            tryFov = stryFov $ sdebugSer ser
            fovMode = fromMaybe (configFovMode sconfig) tryFov
            pers = dungeonPerception cops fovMode glo
            funReset fid = (pers IM.! fid, defLoc fid)
        return (glo, ser, funReset)
  return $! St.evalState rnd dungeonGen

gameResetAction :: MonadServer m
                => Kind.COps
                -> m ( State
                     , StateServer
                     , FactionId -> (FactionPers, State))
gameResetAction = liftIO . gameReset

switchGlobalSelectedSide :: MonadServer m => FactionId -> m ()
switchGlobalSelectedSide =
  modifyState . switchGlobalSelectedSideOnlyForGlobalState

connSendUpdateCli :: MonadServerChan m => ConnClient -> CmdUpdateCli -> m ()
connSendUpdateCli ConnClient {toClient} cmd =
  liftIO $ writeChan toClient $ CmdUpdateCli cmd

sendUpdateCli :: MonadServerChan m => FactionId -> CmdUpdateCli -> m ()
sendUpdateCli fid cmd = do
  conn <- getsDict (fst . (IM.! fid))
  connSendUpdateCli conn cmd

connSendQueryCli :: (Typeable a, MonadServerChan m)
                 => ConnClient -> CmdQueryCli a
                 -> m a
connSendQueryCli ConnClient {toClient, toServer} cmd = do
  liftIO $ writeChan toClient $ CmdQueryCli cmd
  a <- liftIO $ readChan toServer
  return $ fromDyn a (assert `failure` (cmd, a))

sendQueryCli :: (Typeable a, MonadServerChan m)
             => FactionId -> CmdQueryCli a
             -> m a
sendQueryCli fid cmd = do
  conn <- getsDict (fst . (IM.! fid))
  connSendQueryCli conn cmd

sendAIQueryCli :: (Typeable a, MonadServerChan m)
                  => FactionId -> CmdQueryCli a
                  -> m a
sendAIQueryCli fid cmd = do
  connFaction <- getsDict (IM.! fid)
  -- Prefer the AI client, if it exists.
  let conn = fromMaybe (fst connFaction) (snd connFaction)
  connSendQueryCli conn cmd

broadcastCli :: MonadServerChan m
             => [FactionId -> m Bool] -> CmdUpdateCli
             -> m ()
broadcastCli ps cmd = do
  faction <- getsState sfaction
  let p fid = do
        bs <- sequence $ map (\f -> f fid) ps
        return $! and bs
  ks <- filterM p $ IM.keys faction
  mapM_ (flip sendUpdateCli cmd) ks

isFactionHuman :: MonadServerChan m => FactionId -> m Bool
isFactionHuman fid = getsState $ flip isHumanFaction fid

isFactionAware :: MonadServerChan m => [Point] -> FactionId -> m Bool
isFactionAware poss fid = do
  arena <- getsState sarena
  pers <- ask
  let per = pers IM.! fid M.! arena
      inter = IS.fromList poss `IS.intersection` totalVisible per
  return $! null poss || not (IS.null inter)

broadcastPosCli :: MonadServerChan m => [Point] -> CmdUpdateCli -> m ()
broadcastPosCli poss cmd =
  broadcastCli [isFactionHuman, isFactionAware poss] cmd

funBroadcastCli :: MonadServerChan m => (FactionId -> CmdUpdateCli) -> m ()
funBroadcastCli cmd = do
  faction <- getsState sfaction
  let f fid = sendUpdateCli fid (cmd fid)
  mapM_ f $ IM.keys faction

funAIBroadcastCli :: MonadServerChan m => (FactionId -> CmdUpdateCli) -> m ()
funAIBroadcastCli cmd = do
  faction <- getsState sfaction
  d <- getDict
  let f fid = case snd $ d IM.! fid of
        Nothing -> return ()
        Just conn -> connSendUpdateCli conn (cmd fid)
  mapM_ f $ IM.keys faction