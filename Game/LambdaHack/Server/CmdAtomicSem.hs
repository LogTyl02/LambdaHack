-- | Semantics of 'CmdAction' server commands.
-- TODO: document
module Game.LambdaHack.Server.CmdAtomicSem
  ( cmdAtomicSem, resetsFovAtomic, cmdPosAtomic
  ) where

import qualified Data.EnumMap.Strict as EM
import Data.Maybe

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import qualified Game.LambdaHack.Color as Color
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.TileKind as TileKind
import Game.LambdaHack.Faction
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Misc
import Game.LambdaHack.Point
import Game.LambdaHack.Server.CmdAtomic
import Game.LambdaHack.State
import Game.LambdaHack.Time
import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Vector

cmdAtomicSem :: MonadAction m => CmdAtomic -> m ()
cmdAtomicSem cmd = case cmd of
  HealAtomic n aid -> healAtomic n aid
  HasteAtomic aid delta -> hasteAtomic aid delta
  DominateAtomic fromFaction toFaction target ->
    dominateAtomic fromFaction toFaction target
  SpawnAtomic aid body -> spawnAtomic aid body
  KillAtomic aid body -> killAtomic aid body
  CreateItemAtomic iid item k container ->
    createItemAtomic iid item k container
  DestroyItemAtomic iid item k container ->
    destroyItemAtomic iid item k container
  MoveItemAtomic iid k c1 c2 -> moveItemAtomic iid k c1 c2
  WaitAtomic aid fromWait toWait -> waitAtomic aid fromWait toWait
  ChangeTileAtomic p fromTile toTile -> changeTileAtomic p fromTile toTile
  MoveActorAtomic aid fromP toP -> moveActorAtomic aid fromP toP
  DisplaceActorAtomic source target -> displaceActorAtomic source target
  AlterSecretAtomic diffL -> alterSecretAtomic diffL
  AlterSmellAtomic diffL -> alterSmellAtomic diffL
  SetSmellAtomic fromSmell toSmell -> setSmellAtomic fromSmell toSmell
  AlterPath aid fromPath toPath -> alterPath aid fromPath toPath
  ColorActor aid fromColor toColor -> colorActor aid fromColor toColor

resetsFovAtomic :: MonadAction m => FactionId -> CmdAtomic -> m Bool
resetsFovAtomic fid cmd = case cmd of
  DominateAtomic source target _ -> return $ fid `elem` [source, target]
  SpawnAtomic _ body -> return $ fid == bfaction body
  KillAtomic _ _ -> return False  -- FOV left for 1 turn to see aftermath
  CreateItemAtomic _ _ _ _ -> return False  -- unless shines
  DestroyItemAtomic _ _ _ _ -> return False  -- ditto
  MoveItemAtomic _ _ _ _ -> return False  -- assumption: stays on the same pos
  ChangeTileAtomic _ _ _ -> return True  -- even if pos not visible initially
  MoveActorAtomic aid _ _ -> fidEquals fid aid  -- assumption: carries no light
-- TODO: MoveActorCarryingLIghtAtomic _ _ _ -> True
  DisplaceActorAtomic source target -> do
    bs <- fidEquals fid source
    bt <- fidEquals fid target
    return $ source /= target && (bs || bt)
  _ -> return False

fidEquals :: MonadAction m => FactionId -> ActorId -> m Bool
fidEquals fid aid = do
  afid <- getsState $ bfaction . getActorBody aid
  return $ fid == afid

cmdPosAtomic :: MonadAction m => CmdAtomic -> m [Point]
cmdPosAtomic cmd = case cmd of
  HealAtomic _ aid -> singlePos $ posOfAid aid
  HasteAtomic aid _ -> singlePos $ posOfAid aid
  DominateAtomic _ _ target -> singlePos $ posOfAid target
  SpawnAtomic _ body -> return $ [bpos body]
  KillAtomic _ body -> return $ [bpos body]
  CreateItemAtomic _ _ _ container -> singlePos $ posOfContainer container
  DestroyItemAtomic _ _ _ container -> singlePos $ posOfContainer container
  MoveItemAtomic _ _ c1 c2 -> mapM posOfContainer [c1, c2]
  WaitAtomic aid _ _ -> singlePos $ posOfAid aid
  ChangeTileAtomic p _ _ -> return [p]
  MoveActorAtomic _ fromP toP -> return [fromP, toP]
  DisplaceActorAtomic source target -> mapM posOfAid [source, target]
  AlterSecretAtomic diffL -> return []  -- TODO
  AlterSmellAtomic diffL -> return []  -- TODO
  SetSmellAtomic fromSmell toSmell -> return []  -- TODO
  AlterPath aid _ _ -> singlePos $ posOfAid aid
  ColorActor aid _ _-> singlePos $ posOfAid aid

singlePos :: MonadAction m => m Point -> m [Point]
singlePos m = fmap return m

posOfAid :: MonadAction m => ActorId -> m Point
posOfAid aid = getsState $ bpos . getActorBody aid

posOfContainer :: MonadAction m => Container -> m Point
posOfContainer (CFloor pos) = return pos
posOfContainer (CActor aid) = posOfAid aid

healAtomic :: MonadAction m => Int -> ActorId -> m ()
healAtomic n aid = assert (n /= 0) $
  modifyState $ updateActorBody aid $ \b -> b {bhp = n + bhp b}

hasteAtomic :: MonadAction m => ActorId -> Speed -> m ()
hasteAtomic aid delta = assert (delta /= speedZero) $ do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  modifyState $ updateActorBody aid $ \ b ->
    let innateSpeed = aspeed $ okind $ bkind b
        curSpeed = fromMaybe innateSpeed (bspeed b)
        newSpeed = speedAdd curSpeed delta
    in assert (newSpeed >= speedZero `blame` (aid, curSpeed, delta)) $
       if curSpeed == innateSpeed
       then b {bspeed = Nothing}
       else b {bspeed = Just newSpeed}

dominateAtomic :: MonadAction m => FactionId -> FactionId -> ActorId -> m ()
dominateAtomic fromFaction toFaction target = do
  tm <- getsState (getActorBody target)
  assert (fromFaction == bfaction tm `blame` (fromFaction, tm, toFaction)) $
    modifyState $ updateActorBody target $ \b -> b {bfaction = toFaction}

-- TODO: perhaps assert that the inventory of the actor is empty
-- or at least that the items belong to litem.
spawnAtomic :: MonadAction m => ActorId -> Actor -> m ()
spawnAtomic aid body = modifyState $ insertActor aid body

-- TODO: perhaps assert that the inventory of the actor is empty.
killAtomic :: MonadAction m => ActorId -> Actor -> m ()
killAtomic aid _body = modifyState $ deleteActor aid

-- | Create a few copies of an item that is already registered for the dungeon
-- (in @sitemRev@ field of @StateServer@).
createItemAtomic :: MonadAction m
                 => ItemId -> Item -> Int -> Container -> m ()
createItemAtomic iid item k container = assert (k > 0) $ do
  -- The item may or may not be already present in the dungeon.
  let f item1 item2 = assert (item1 == item2) item1
  modifyState $ updateItem $ EM.insertWith f iid item
  case container of
    CFloor pos -> insertItemFloor iid k pos
    CActor aid -> insertItemActor iid k aid

insertItemFloor :: MonadAction m
                => ItemId -> Int -> Point -> m ()
insertItemFloor iid k pos =
  let bag = EM.singleton iid k
      mergeBag = EM.insertWith (EM.unionWith (+)) pos bag
  in modifyState $ updateArena $ updateFloor mergeBag

insertItemActor :: MonadAction m
                => ItemId -> Int -> ActorId -> m ()
insertItemActor iid k aid = do
  item <- getsState $ getItemBody iid
  let l = if jsymbol item == '$' then Just $ InvChar '$' else Nothing
      bag = EM.singleton iid k
  body <- getsState $ getActorBody aid
  case assignLetter iid l body of
    Nothing -> insertItemFloor iid k (bpos body)
    Just l2 -> do
      let upd = EM.unionWith (+) bag
      modifyState $ updateArena $ updateActor
        $ EM.adjust (\b -> b {bbag = upd (bbag b)}) aid
      modifyState $ updateArena $ updateActor
        $ EM.adjust (\b -> b {binv = EM.insert l2 iid (binv b)}) aid
      modifyState $ updateActorBody aid $ \b ->
        b {bletter = max l2 (bletter b)}

-- | Destroy some copies (possibly not all) of an item.
destroyItemAtomic :: MonadAction m
                  => ItemId -> Item -> Int -> Container -> m ()
destroyItemAtomic iid _item k container = assert (k > 0) $ do
  -- Do not remove the item from @sitem@ nor from @sitemRev@,
  -- This is behaviourally equivalent.
  case container of
    CFloor pos -> deleteItemFloor iid k pos
    CActor aid -> deleteItemActor iid k aid
                  -- Actor's @bletter@ for UI not reset.
                  -- This is OK up to isomorphism.

deleteItemFloor :: MonadAction m
                 => ItemId -> Int -> Point -> m ()
deleteItemFloor iid k pos =
  let rmFromFloor (Just bag) =
        let nbag = rmFromBag k iid bag
        in if EM.null nbag then Nothing else Just nbag
      rmFromFloor Nothing = assert `failure` (iid, k, pos)
  in modifyState $ updateArena $ updateFloor $ EM.alter rmFromFloor pos

deleteItemActor :: MonadAction m
                 => ItemId -> Int -> ActorId -> m ()
deleteItemActor iid k aid =
  modifyState $ updateArena $ updateActor
  $ EM.adjust (\b -> b {bbag = rmFromBag k iid (bbag b)}) aid

moveItemAtomic :: MonadAction m
               => ItemId -> Int -> Container -> Container -> m ()
moveItemAtomic iid k c1 c2 = assert (k > 0) $ do
  case c1 of
    CFloor pos -> deleteItemFloor iid k pos
    CActor aid -> deleteItemActor iid k aid
  case c2 of
    CFloor pos -> insertItemFloor iid k pos
    CActor aid -> insertItemActor iid k aid

waitAtomic :: MonadAction m => ActorId -> Time -> Time -> m ()
waitAtomic aid _fromWait toWait =
  modifyState $ updateActorBody aid $ \b -> b {bwait = toWait}

changeTileAtomic :: MonadAction m
                 => Point -> Kind.Id TileKind -> Kind.Id TileKind -> m ()
changeTileAtomic p _fromTile toTile =
  let adj = (Kind.// [(p, toTile)])
  in modifyState (updateArena (updateTile adj))

moveActorAtomic :: MonadAction m => ActorId -> Point -> Point -> m ()
moveActorAtomic aid _fromP toP =
  modifyState $ updateActorBody aid $ \b -> b {bpos = toP}

displaceActorAtomic :: MonadAction m => ActorId -> ActorId -> m ()
displaceActorAtomic source target = do
  spos <- getsState $ bpos . getActorBody source
  tpos <- getsState $ bpos . getActorBody target
  modifyState $ updateActorBody source $ \ b -> b {bpos = tpos}
  modifyState $ updateActorBody target $ \ b -> b {bpos = spos}

alterSecretAtomic :: MonadAction m => DiffEM Point Time -> m ()
alterSecretAtomic diffL =
  modifyState $ updateArena $ updateSecret $ applyDiffEM diffL

alterSmellAtomic :: MonadAction m => DiffEM Point Time -> m ()
alterSmellAtomic diffL =
  modifyState $ updateArena $ updateSmell $ applyDiffEM diffL

-- TODO: only wipe out smell within radius 10; use DiffEM
setSmellAtomic :: MonadAction m => SmellMap -> SmellMap -> m ()
setSmellAtomic _fromSmell toSmell = do
  modifyState $ updateArena $ updateSmell $ const toSmell

alterPath :: MonadAction m
          => ActorId -> Maybe [Vector] -> Maybe [Vector] -> m ()
alterPath aid _fromPath toPath =
  modifyState $ updateActorBody aid $ \b -> b {bpath = toPath}

colorActor :: MonadAction m
           => ActorId -> Maybe Color.Color -> Maybe Color.Color -> m ()
colorActor aid _fromColor toColor =
  modifyState $ updateActorBody aid $ \b -> b {bcolor = toColor}