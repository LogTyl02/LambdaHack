-- | Semantics of atomic commands shared by client and server.
-- See
-- <https://github.com/kosmikus/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Common.AtomicSem
  ( cmdAtomicSem
  , posOfAid, posOfContainer
  ) where

import Control.Arrow (second)
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.List

import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.AtomicCmd
import qualified Game.LambdaHack.Common.Color as Color
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.TileKind as TileKind
import Game.LambdaHack.Utils.Assert

cmdAtomicSem :: MonadAction m => CmdAtomic -> m ()
cmdAtomicSem cmd = case cmd of
  CreateActorA aid body ais -> createActorA aid body ais
  DestroyActorA aid body ais -> destroyActorA aid body ais
  CreateItemA iid item k c -> createItemA iid item k c
  DestroyItemA iid item k c -> destroyItemA iid item k c
  SpotActorA aid body ais -> createActorA aid body ais
  LoseActorA aid body ais -> destroyActorA aid body ais
  SpotItemA iid item k c -> createItemA iid item k c
  LoseItemA iid item k c -> destroyItemA iid item k c
  MoveActorA aid fromP toP -> moveActorA aid fromP toP
  WaitActorA aid fromWait toWait -> waitActorA aid fromWait toWait
  DisplaceActorA source target -> displaceActorA source target
  MoveItemA iid k c1 c2 -> moveItemA iid k c1 c2
  AgeActorA aid t -> ageActorA aid t
  HealActorA aid n -> healActorA aid n
  HasteActorA aid delta -> hasteActorA aid delta
  PathActorA aid fromPath toPath -> pathActorA aid fromPath toPath
  ColorActorA aid fromCol toCol -> colorActorA aid fromCol toCol
  QuitFactionA fid mbody fromSt toSt -> quitFactionA fid mbody fromSt toSt
  LeadFactionA fid source target -> leadFactionA fid source target
  DiplFactionA fid1 fid2 fromDipl toDipl ->
    diplFactionA fid1 fid2 fromDipl toDipl
  AlterTileA lid p fromTile toTile -> alterTileA lid p fromTile toTile
  SearchTileA _ _ fromTile toTile ->
    assert (fromTile /= toTile) $ return ()  -- only for clients
  SpotTileA lid ts -> spotTileA lid ts
  LoseTileA lid ts -> loseTileA lid ts
  AlterSmellA lid p fromSm toSm -> alterSmellA lid p fromSm toSm
  SpotSmellA lid sms -> spotSmellA lid sms
  LoseSmellA lid sms -> loseSmellA lid sms
  AgeLevelA lid t -> ageLevelA lid t
  AgeGameA t -> ageGameA t
  DiscoverA{} -> return ()  -- Server keeps all atomic comands so the semantics
  CoverA{} -> return ()     -- of inverses has to be reasonably inverse.
  PerceptionA _ outPA inPA ->
    assert (not (EM.null outPA && EM.null inPA)) $ return ()
  RestartA fid sdisco sfper s _ _ -> restartA fid sdisco sfper s
  RestartServerA s -> restartServerA s
  ResumeA{} -> return ()
  ResumeServerA s -> resumeServerA s
  KillExitA{} -> return ()
  SaveBkpA -> return ()
  MsgAllA{} -> return ()

-- | Creates an actor. Note: after this command, usually a new leader
-- for the party should be elected (in case this actor is the only one alive).
createActorA :: MonadAction m => ActorId -> Actor -> [(ItemId, Item)] -> m ()
createActorA aid body ais = do
  -- Add actor to @sactorD@.
  let f Nothing = Just body
      f (Just b) = assert `failure` "actor already added" `with` (aid, body, b)
  modifyState $ updateActorD $ EM.alter f aid
  -- Add actor to @sprio@.
  let g Nothing = Just [aid]
      g (Just l) = assert (aid `notElem` l `blame` "actor already added"
                                           `with` (aid, body, l))
                   $ Just $ aid : l
  updateLevel (blid body) $ updatePrio $ EM.alter g (btime body)
  -- Actor's items may or may not be already present in @sitemD@,
  -- regardless if they are already present otherwise in the dungeon.
  -- We re-add them all to save time determining which really need it.
  forM_ ais $ \(iid, item) -> do
    let h item1 item2 =
          assert (item1 == item2 `blame` "inconsistent created actor items"
                                 `with` (aid, body, iid, item1, item2)) item1
    modifyState $ updateItemD $ EM.insertWith h iid item

-- | Update a given level data within state.
updateLevel :: MonadAction m => LevelId -> (Level -> Level) -> m ()
updateLevel lid f = modifyState $ updateDungeon $ EM.adjust f lid

-- | Kills an actor. Note: after this command, usually a new leader
-- for the party should be elected.
destroyActorA :: MonadAction m => ActorId -> Actor -> [(ItemId, Item)] -> m ()
destroyActorA aid body ais = do
  -- Assert that actor's items belong to @sitemD@. Do not remove those
  -- that do not appear anywhere else, for simplicity and speed.
  itemD <- getsState sitemD
  let match (iid, item) = itemD EM.! iid == item
  assert (allB match ais `blame` "destroyed actor items not found"
                         `with` (aid, body, ais, itemD)) skip
  -- Remove actor from @sactorD@.
  let f Nothing = assert `failure` "actor already removed" `with` (aid, body)
      f (Just b) = assert (b == body `blame` "inconsisted destroyed actor body"
                                     `with` (aid, body, b)) Nothing
  modifyState $ updateActorD $ EM.alter f aid
  -- Remove actor from @sprio@.
  let g Nothing = assert `failure` "actor already removed" `with` (aid, body)
      g (Just l) = assert (aid `elem` l `blame` "actor already removed"
                                        `with` (aid, body, l))
                   $ let l2 = delete aid l
                     in if null l2 then Nothing else Just l2
  updateLevel (blid body) $ updatePrio $ EM.alter g (btime body)

-- | Create a few copies of an item that is already registered for the dungeon
-- (in @sitemRev@ field of @StateServer@).
createItemA :: MonadAction m => ItemId -> Item -> Int -> Container -> m ()
createItemA iid item k c = assert (k > 0) $ do
  -- The item may or may not be already present in @sitemD@,
  -- regardless if it's actually present in the dungeon.
  let f item1 item2 = assert (item1 == item2
                              `blame` "inconsistent created item"
                              `with` (iid, item, k, c)) item1
  modifyState $ updateItemD $ EM.insertWith f iid item
  case c of
    CFloor lid pos -> insertItemFloor lid iid k pos
    CActor aid l -> insertItemActor iid k l aid

insertItemFloor :: MonadAction m
                => LevelId -> ItemId -> Int -> Point -> m ()
insertItemFloor lid iid k pos =
  let bag = EM.singleton iid k
      mergeBag = EM.insertWith (EM.unionWith (+)) pos bag
  in updateLevel lid $ updateFloor mergeBag

insertItemActor :: MonadAction m
                => ItemId -> Int -> InvChar -> ActorId -> m ()
insertItemActor iid k l aid = do
  let bag = EM.singleton iid k
      upd = EM.unionWith (+) bag
  modifyState $ updateActorD $
    EM.adjust (\b -> b {bbag = upd (bbag b)}) aid
  modifyState $ updateActorD $
    EM.adjust (\b -> b {binv = EM.insert l iid (binv b)}) aid
  modifyState $ updateActorBody aid $ \b ->
    b {bletter = max l (bletter b)}

-- | Destroy some copies (possibly not all) of an item.
destroyItemA :: MonadAction m => ItemId -> Item -> Int -> Container -> m ()
destroyItemA iid item k c = assert (k > 0) $ do
  -- Do not remove the item from @sitemD@ nor from @sitemRev@,
  -- It's incredibly costly and not noticeable for the player.
  -- However, assert the item is registered in @sitemD@.
  itemD <- getsState sitemD
  assert (iid `EM.lookup` itemD == Just item `blame` "item already removed"
                                             `with` (iid, item, itemD)) skip
  case c of
    CFloor lid pos -> deleteItemFloor lid iid k pos
    CActor aid l -> deleteItemActor iid k l aid

deleteItemFloor :: MonadAction m
                => LevelId -> ItemId -> Int -> Point -> m ()
deleteItemFloor lid iid k pos =
  let rmFromFloor (Just bag) =
        let nbag = rmFromBag k iid bag
        in if EM.null nbag then Nothing else Just nbag
      rmFromFloor Nothing = assert `failure` "item already removed"
                                   `with` (lid, iid, k, pos)
  in updateLevel lid $ updateFloor $ EM.alter rmFromFloor pos

deleteItemActor :: MonadAction m
                => ItemId -> Int -> InvChar -> ActorId -> m ()
deleteItemActor iid k l aid = do
  modifyState $ updateActorD $
    EM.adjust (\b -> b {bbag = rmFromBag k iid (bbag b)}) aid
  -- Do not remove from actor's @binv@, but assert it was there.
  b <- getsState $ getActorBody aid
  assert (l `EM.lookup` binv b == Just iid `blame` "item already removed"
                                           `with` (iid, l, aid)) skip
  -- Actor's @bletter@ for UI not reset, but checked.
  assert (bletter b >= l`blame` "inconsistent actor inventory letter"
                        `with` (iid, k, l, aid, bletter b)) skip

moveActorA :: MonadAction m => ActorId -> Point -> Point -> m ()
moveActorA aid fromP toP = assert (fromP /= toP) $ do
  b <- getsState $ getActorBody aid
  assert (fromP == bpos b `blame` "unexpected moved actor position"
                          `with` (aid, fromP, toP, bpos b, b)) skip
  modifyState $ updateActorBody aid
              $ \body -> body {bpos = toP, boldpos = fromP}

waitActorA :: MonadAction m => ActorId -> Time -> Time -> m ()
waitActorA aid fromWait toWait = assert (fromWait /= toWait) $ do
  b <- getsState $ getActorBody aid
  assert (fromWait == bwait b `blame` "unexpected waited actor time"
                              `with` (aid, fromWait, toWait, bwait b, b)) skip
  modifyState $ updateActorBody aid $ \body -> body {bwait = toWait}

displaceActorA :: MonadAction m => ActorId -> ActorId -> m ()
displaceActorA source target = assert (source /= target) $ do
  spos <- getsState $ bpos . getActorBody source
  tpos <- getsState $ bpos . getActorBody target
  modifyState $ updateActorBody source $ \ b -> b {bpos = tpos, boldpos = spos}
  modifyState $ updateActorBody target $ \ b -> b {bpos = spos, boldpos = tpos}

moveItemA :: MonadAction m => ItemId -> Int -> Container -> Container -> m ()
moveItemA iid k c1 c2 = assert (k > 0 && c1 /= c2) $ do
  (lid1, _) <- posOfContainer c1
  (lid2, _) <- posOfContainer c2
  assert (lid1 == lid2 `blame` "moved item containers not on the same level"
                       `with` (iid, k, c1, c2, lid1, lid2)) skip
  case c1 of
    CFloor lid pos -> deleteItemFloor lid iid k pos
    CActor aid l -> deleteItemActor iid k l aid
  case c2 of
    CFloor lid pos -> insertItemFloor lid iid k pos
    CActor aid l -> insertItemActor iid k l aid

posOfAid :: MonadActionRO m => ActorId -> m (LevelId, Point)
posOfAid aid = do
  b <- getsState $ getActorBody aid
  return (blid b, bpos b)

posOfContainer :: MonadActionRO m => Container -> m (LevelId, Point)
posOfContainer (CFloor lid p) = return (lid, p)
posOfContainer (CActor aid _) = posOfAid aid

-- TODO: optimize (a single call to updatePrio is enough)
ageActorA :: MonadAction m => ActorId -> Time -> m ()
ageActorA aid t = assert (t /= timeZero) $ do
  body <- getsState $ getActorBody aid
  ais <- getsState $ getActorItem aid
  destroyActorA aid body ais
  let newBody = body { btime = timeAdd (btime body) t
                     , bwait = if bwait body <= btime body
                               then timeZero    -- reset old waiting time
                               else bwait body  -- keep new waiting time
                     }
  createActorA aid newBody ais

healActorA :: MonadAction m => ActorId -> Int -> m ()
healActorA aid n = assert (n /= 0) $
  modifyState $ updateActorBody aid $ \b -> b {bhp = n + bhp b}

hasteActorA :: MonadAction m => ActorId -> Speed -> m ()
hasteActorA aid delta = assert (delta /= speedZero) $ do
  modifyState $ updateActorBody aid $ \ b ->
    let newSpeed = speedAdd (bspeed b) delta
    in assert (newSpeed >= speedZero `blame` "actor slowed below zero"
                                     `with` (aid, delta, bspeed b, newSpeed)) $
       b {bspeed = newSpeed}

pathActorA :: MonadAction m
           => ActorId -> Maybe [Vector] -> Maybe [Vector] -> m ()
pathActorA aid fromPath toPath = assert (fromPath /= toPath) $ do
  body <- getsState $ getActorBody aid
  assert (fromPath == bpath body `blame` "unexpected actor path"
                                 `with` (aid, fromPath, toPath, body)) skip
  modifyState $ updateActorBody aid $ \b -> b {bpath = toPath}

colorActorA :: MonadAction m
            => ActorId -> Color.Color -> Color.Color -> m ()
colorActorA aid fromCol toCol = assert (fromCol /= toCol) $ do
  body <- getsState $ getActorBody aid
  assert (fromCol == bcolor body `blame` "unexpected actor color"
                                 `with` (aid, fromCol, toCol, body)) skip
  modifyState $ updateActorBody aid $ \b -> b {bcolor = toCol}

quitFactionA :: MonadAction m
             => FactionId -> Maybe Actor -> Maybe Status -> Maybe Status
             -> m ()
quitFactionA fid mbody fromSt toSt = assert (fromSt /= toSt) $ do
  assert (maybe True ((fid ==) . bfid) mbody) skip
  fact <- getsState $ (EM.! fid) . sfactionD
  assert (fromSt == gquit fact `blame` "unexpected actor quit status"
                               `with` (fid, fromSt, toSt, fact)) skip
  let adj fa = fa {gquit = toSt}
  modifyState $ updateFaction $ EM.adjust adj fid

-- The previous leader is assumed to be alive.
leadFactionA :: MonadAction m
             => FactionId -> Maybe ActorId -> Maybe ActorId -> m ()
leadFactionA fid source target = assert (source /= target) $ do
  fact <- getsState $ (EM.! fid) . sfactionD
  assert (source == gleader fact `blame` "unexpected actor leader"
                                 `with` (fid, source, target, fact)) skip
  let adj fa = fa {gleader = target}
  modifyState $ updateFaction $ EM.adjust adj fid

diplFactionA :: MonadAction m
             => FactionId -> FactionId -> Diplomacy -> Diplomacy -> m ()
diplFactionA fid1 fid2 fromDipl toDipl =
  assert (fid1 /= fid2 && fromDipl /= toDipl) $ do
    fact1 <- getsState $ (EM.! fid1) . sfactionD
    fact2 <- getsState $ (EM.! fid2) . sfactionD
    assert (fromDipl == EM.findWithDefault Unknown fid2 (gdipl fact1)
            && fromDipl == EM.findWithDefault Unknown fid1 (gdipl fact2)
            `blame` "unexpected actor diplomacy status"
            `with` (fid1, fid2, fromDipl, toDipl, fact1, fact2)) skip
    let adj fid fact = fact {gdipl = EM.insert fid toDipl (gdipl fact)}
    modifyState $ updateFaction $ EM.adjust (adj fid2) fid1
    modifyState $ updateFaction $ EM.adjust (adj fid1) fid2

-- | Alter an attribute (actually, the only, the defining attribute)
-- of a visible tile. This is similar to e.g., @PathActorA@.
alterTileA :: MonadAction m
           => LevelId -> Point -> Kind.Id TileKind -> Kind.Id TileKind
           -> m ()
alterTileA lid p fromTile toTile = assert (fromTile /= toTile) $ do
  Kind.COps{cotile} <- getsState scops
  lvl <- getLevel lid
  let freshClientTile = hideTile cotile lvl p
  -- The second alternative can happen if, e.g., a client remembers,
  -- but does not see the tile (so does not notice the SearchTileA action),
  -- and it suddenly changes into another tile,
  -- which at the same time becomes visible (e.g., an open door).
  -- See 'AtomicSemCli' for how this is reported to the client.
  let adj ts = assert (ts Kind.! p == fromTile
                       || ts Kind.! p == freshClientTile
                       `blame` "unexpected altered tile kind"
                       `with` (lid, p, fromTile, toTile, ts Kind.! p))
               $ ts Kind.// [(p, toTile)]
  updateLevel lid $ updateTile adj
  case (Tile.isExplorable cotile fromTile, Tile.isExplorable cotile toTile) of
    (False, True) -> updateLevel lid $ \lvl2 -> lvl2 {lseen = lseen lvl + 1}
    (True, False) -> updateLevel lid $ \lvl2 -> lvl2 {lseen = lseen lvl - 1}
    _ -> return ()

-- Notice a previously invisible tiles. This is similar to @SpotActorA@,
-- but done in bulk, because it often involves dozens of tiles pers move.
-- We don't check that the tiles at the positions in question are unknown
-- to save computation, especially for clients that remember tiles
-- at previously seen positions. Similarly, when updating the @lseen@
-- field we don't assume the tiles were unknown previously.
spotTileA :: MonadAction m => LevelId -> [(Point, Kind.Id TileKind)] -> m ()
spotTileA lid ts = assert (not $ null ts) $ do
  Kind.COps{cotile} <- getsState scops
  Level{ltile} <- getLevel lid
  let adj tileMap = tileMap Kind.// ts
  updateLevel lid $ updateTile adj
  let f (p, t2) = do
        let t1 = ltile Kind.! p
        case (Tile.isExplorable cotile t1, Tile.isExplorable cotile t2) of
          (False, True) -> updateLevel lid $ \lvl -> lvl {lseen = lseen lvl+1}
          (True, False) -> updateLevel lid $ \lvl -> lvl {lseen = lseen lvl-1}
          _ -> return ()
  mapM_ f ts

-- Stop noticing a previously visible tiles. Unlike @spotTileA@, it verifies
-- the state of the tiles before changing them.
loseTileA :: MonadAction m => LevelId -> [(Point, Kind.Id TileKind)] -> m ()
loseTileA lid ts = assert (not $ null ts) $ do
  Kind.COps{cotile=cotile@Kind.Ops{ouniqGroup}} <- getsState scops
  let unknownId = ouniqGroup "unknown space"
      matches _ [] = True
      matches tileMap ((p, ov) : rest) =
        tileMap Kind.! p == ov && matches tileMap rest
      tu = map (second (const unknownId)) ts
      adj tileMap = assert (matches tileMap ts) $ tileMap Kind.// tu
  updateLevel lid $ updateTile adj
  let f (_, t1) =
        when (Tile.isExplorable cotile t1) $
          updateLevel lid $ \lvl -> lvl {lseen = lseen lvl - 1}
  mapM_ f ts

alterSmellA :: MonadAction m
            => LevelId -> Point -> Maybe Time -> Maybe Time -> m ()
alterSmellA lid p _fromSm toSm = do
  -- TODO: this rarely crashes when a dominated smelling monster exists:
  -- let alt sm = assert (sm == fromSm `blame` "unexpected tile smell"
  --                                   `with` (lid, p, fromSm, toSm, sm)) toSm
  let alt _ =  toSm
  updateLevel lid $ updateSmell $ EM.alter alt p

spotSmellA :: MonadAction m => LevelId -> [(Point, Time)] -> m ()
spotSmellA lid sms = assert (not $ null sms) $ do
  let alt sm Nothing = Just sm
      alt sm (Just _) = Just sm
-- TODO: a hack to sidestep server not disabling the nose of fresh actors,
-- see smellFromActors
--      alt sm (Just oldSm) = assert `failure` "smell already added"
--                                   `with` (lid, sms, sm, oldSm)
      f (p, sm) = EM.alter (alt sm) p
      upd m = foldr f m sms
  updateLevel lid $ updateSmell upd

loseSmellA :: MonadAction m => LevelId -> [(Point, Time)] -> m ()
loseSmellA lid sms = assert (not $ null sms) $ do
  let alt sm Nothing = assert `failure` "smell already removed"
                              `with` (lid, sms, sm)
      alt sm (Just oldSm) =
        assert (sm == oldSm `blame` "unexpected lost smell"
                            `with` (lid, sms, sm, oldSm)) Nothing
      f (p, sm) = EM.alter (alt sm) p
      upd m = foldr f m sms
  updateLevel lid $ updateSmell upd

-- | Age the level.
--
-- Not aging the game here, since not all factions see the level,
-- so not all get this command (it would lead information that
-- there is somebody's leader on the level).
ageLevelA :: MonadAction m => LevelId -> Time -> m ()
ageLevelA lid delta = assert (delta /= timeZero) $
  updateLevel lid $ \lvl -> lvl {ltime = timeAdd (ltime lvl) delta}

ageGameA :: MonadAction m => Time -> m ()
ageGameA delta = assert (delta /= timeZero) $
  modifyState $ updateTime $ timeAdd delta

restartA :: MonadAction m
         => FactionId -> Discovery -> FactionPers -> State -> m ()
restartA _ _ _ = putState

restartServerA :: MonadAction m =>  State -> m ()
restartServerA = putState

resumeServerA :: MonadAction m =>  State -> m ()
resumeServerA = putState
