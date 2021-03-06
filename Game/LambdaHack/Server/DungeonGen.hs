-- | The main dungeon generation routine.
module Game.LambdaHack.Server.DungeonGen
  ( FreshDungeon(..), dungeonGen
  ) where

import Control.Arrow (first)
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.List
import Data.Maybe

import qualified Game.LambdaHack.Common.Effect as Effect
import qualified Game.LambdaHack.Common.Feature as F
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.PointXY
import Game.LambdaHack.Common.Random
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.CaveKind
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.TileKind
import Game.LambdaHack.Server.DungeonGen.Cave hiding (TileMapXY)
import Game.LambdaHack.Server.DungeonGen.Place
import Game.LambdaHack.Utils.Assert

convertTileMaps :: Rnd (Kind.Id TileKind) -> Int -> Int -> TileMapXY
                -> Rnd TileMap
convertTileMaps cdefTile cxsize cysize ltile = do
  let bounds = (origin, toPoint cxsize $ PointXY (cxsize - 1, cysize - 1))
      assocs = map (first (toPoint cxsize)) (EM.assocs ltile)
  pickedTiles <- replicateM (cxsize * cysize) cdefTile
  return $ Kind.listArray bounds pickedTiles Kind.// assocs

placeStairs :: Kind.Ops TileKind -> TileMap -> CaveKind -> [Point]
            -> Rnd Point
placeStairs cotile cmap CaveKind{..} ps = do
  let dist cmin l _ = all (\pos -> chessDist cxsize l pos > cmin) ps
  findPosTry 1000 cmap
    [ dist $ cminStairDist
    , dist $ cminStairDist `div` 2
    , dist $ cminStairDist `div` 4
    , dist $ cminStairDist `div` 8
    , \p t -> Tile.hasFeature cotile F.CanActor t
              && dist 0 p t  -- can't overwrite stairs with other stairs
    ]

-- | Create a level from a cave, from a cave kind.
buildLevel :: Kind.COps -> Cave -> Int -> Int -> Int -> Int -> Maybe Bool
           -> Rnd Level
buildLevel cops@Kind.COps{ cotile=cotile@Kind.Ops{opick, okind}
                         , cocave=Kind.Ops{okind=cokind} }
           Cave{..} ldepth minD maxD nstairUp escapeFeature = do
  let kc@CaveKind{..} = cokind dkind
      fitArea pos = inside cxsize pos . qarea
      findLegend pos = maybe clitLegendTile qlegend
                       $ find (fitArea pos) dplaces
      hasEscapeAndSymbol sym t = Tile.kindHasFeature (F.Cause Effect.Escape) t
                                 && tsymbol t == sym
      ascendable  = Tile.kindHasFeature $ F.Cause (Effect.Ascend 1)
      descendable = Tile.kindHasFeature $ F.Cause (Effect.Ascend (-1))
  cmap <- convertTileMaps (opick cdefTile (const True)) cxsize cysize dmap
  -- We keep two-way stairs separately, in the last component.
  let makeStairs :: Bool -> Bool -> Bool
                 -> ( [(Point, Kind.Id TileKind)]
                    , [(Point, Kind.Id TileKind)]
                    , [(Point, Kind.Id TileKind)] )
                 -> Rnd ( [(Point, Kind.Id TileKind)]
                        , [(Point, Kind.Id TileKind)]
                        , [(Point, Kind.Id TileKind)] )
      makeStairs moveUp noAsc noDesc (up, down, upDown) =
        if (if moveUp then noAsc else noDesc) then
          return (up, down, upDown)
        else do
          let cond tk = (if moveUp then ascendable tk else descendable tk)
                        && (if noAsc then not (ascendable tk) else True)
                        && (if noDesc then not (descendable tk) else True)
              stairsCur = up ++ down ++ upDown
              posCur = nub $ sort $ map fst stairsCur
          spos <- placeStairs cotile cmap kc posCur
          stairId <- opick (findLegend spos) cond
          let st = (spos, stairId)
              asc = ascendable $ okind stairId
              desc = descendable $ okind stairId
          return $ case (asc, desc) of
                     (True, False) -> (st : up, down, upDown)
                     (False, True) -> (up, st : down, upDown)
                     (True, True)  -> (up, down, st : upDown)
                     (False, False) -> assert `failure` st
  (stairsUp1, stairsDown1, stairsUpDown1) <-
    makeStairs False (ldepth == maxD) (ldepth == minD) ([], [], [])
  assert (null stairsUp1) skip
  let nstairUpLeft = nstairUp - length stairsUpDown1
  (stairsUp2, stairsDown2, stairsUpDown2) <-
    foldM (\sts _ -> makeStairs True (ldepth == maxD) (ldepth == minD) sts)
          (stairsUp1, stairsDown1, stairsUpDown1)
          [1 .. nstairUpLeft]
  -- If only a single tile of up-and-down stairs, add one more stairs down.
  (stairsUp, stairsDown, stairsUpDown) <-
    if length (stairsUp2 ++ stairsDown2) == 0
    then (makeStairs False True (ldepth == minD)
             (stairsUp2, stairsDown2, stairsUpDown2))
    else return (stairsUp2, stairsDown2, stairsUpDown2)
  let stairsUpAndUpDown = stairsUp ++ stairsUpDown
  assert (length stairsUpAndUpDown == nstairUp) skip
  let stairsTotal = stairsUpAndUpDown ++ stairsDown
      posTotal = nub $ sort $ map fst stairsTotal
  epos <- placeStairs cotile cmap kc posTotal
  escape <- case escapeFeature of
              Nothing -> return []
              Just True -> do
                upEscape <- opick (findLegend epos) $ hasEscapeAndSymbol '<'
                return [(epos, upEscape)]
              Just False -> do
                downEscape <- opick (findLegend epos) $ hasEscapeAndSymbol '>'
                return [(epos, downEscape)]
  let exits = stairsTotal ++ escape
      ltile = cmap Kind.// exits
      -- We reverse the order in down stairs, to minimize long stair chains.
      lstair = ( map fst $ stairsUp ++ stairsUpDown
               , map fst $ stairsUpDown ++ stairsDown )
  -- traceShow (ldepth, nstairUp, (stairsUp, stairsDown, stairsUpDown)) skip
  litemNum <- castDice citemNum
  lsecret <- random
  return $! levelFromCaveKind cops kc ldepth ltile lstair litemNum lsecret

levelFromCaveKind :: Kind.COps
                  -> CaveKind -> Int -> TileMap -> ([Point], [Point])
                  -> Int -> Int
                  -> Level
levelFromCaveKind Kind.COps{cotile}
                  CaveKind{..} ldepth ltile lstair litemNum lsecret =
  Level
    { ldepth
    , lprio = EM.empty
    , lfloor = EM.empty
    , ltile
    , lxsize = cxsize
    , lysize = cysize
    , lsmell = EM.empty
    , ldesc = cname
    , lstair
    , lseen = 0
    , lclear = let f !n !tk | Tile.isExplorable cotile tk = n + 1
                            | otherwise = n
               in Kind.foldlArray f 0 ltile
    , ltime = timeTurn
    , litemNum
    , lsecret
    , lhidden = chidden
    }

findGenerator :: Kind.COps -> Caves
              -> LevelId -> LevelId -> LevelId -> Int -> Int
              -> Rnd Level
findGenerator cops caves ldepth minD maxD totalDepth nstairUp = do
  let Kind.COps{cocave=Kind.Ops{opick}} = cops
      (genName, escapeFeature) =
        fromMaybe ("dng", Nothing) $ EM.lookup ldepth caves
  ci <- opick genName (const True)
  cave <- buildCave cops (fromEnum ldepth) totalDepth ci
  buildLevel cops cave
             (fromEnum ldepth) (fromEnum minD) (fromEnum maxD) nstairUp
             escapeFeature

-- | Freshly generated and not yet populated dungeon.
data FreshDungeon = FreshDungeon
  { freshDungeon :: !Dungeon  -- ^ maps for all levels
  , freshDepth   :: !Int      -- ^ dungeon depth (can be different than size)
  }

-- | Generate the dungeon for a new game.
dungeonGen :: Kind.COps -> Caves -> Rnd FreshDungeon
dungeonGen cops caves = do
  let (minD, maxD) =
        case (EM.minViewWithKey caves, EM.maxViewWithKey caves) of
          (Just ((s, _), _), Just ((e, _), _)) -> (s, e)
          _ -> assert `failure` "no caves" `with` caves
      totalDepth = if minD == maxD
                   then 10
                   else fromEnum maxD - fromEnum minD + 1
  let gen :: (Int, [(LevelId, Level)]) -> LevelId
          -> Rnd (Int, [(LevelId, Level)])
      gen (nstairUp, l) ldepth = do
        lvl <- findGenerator cops caves ldepth minD maxD totalDepth nstairUp
        -- nstairUp for the next level is nstairDown for the current level
        let nstairDown = length $ snd $ lstair lvl
        return $ (nstairDown, (ldepth, lvl) : l)
  (nstairUpLast, levels) <- foldM gen (0, []) $ reverse [minD..maxD]
  assert (nstairUpLast == 0) skip
  let freshDungeon = EM.fromList levels
      freshDepth = totalDepth
  return FreshDungeon{..}
