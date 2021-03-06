-- | Operations concerning dungeon level tiles.
--
-- Unlike for many other content types, there is no type @Tile@,
-- of particular concrete tiles in the dungeon,
-- corresponding to 'TileKind' (the type of kinds of terrain tiles).
-- This is because the tiles are too numerous and there's not enough
-- storage space for a well-rounded @Tile@ type, on one hand,
-- and on the other hand, tiles are accessed
-- too often in performance critical code
-- to try to compress their representation and/or recompute them.
-- Instead, of defining a @Tile@ type, we express various properties
-- of concrete tiles by arrays or sparse EnumMaps, as appropriate.
--
-- Actors at normal speed (2 m/s) take one turn to move one tile (1 m by 1 m).
module Game.LambdaHack.Common.Tile
  ( SmellTime
  , kindHasFeature, kindHas, hasFeature
  , isClear, isLit, isExplorable, similar, speedup
  , openTo, closeTo, revealAs, hideAs, openable, closable, changeable
  ) where

import qualified Data.Array.Unboxed as A
import qualified Data.List as L

import qualified Game.LambdaHack.Common.Feature as F
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.TileKind
import Game.LambdaHack.Utils.Assert

-- | The last time a hero left a smell in a given tile. To be used
-- by monsters that hunt by smell.
type SmellTime = Time

-- | Whether a tile kind has the given feature.
kindHasFeature :: F.Feature -> TileKind -> Bool
kindHasFeature f t = f `elem` tfeature t

-- | Whether a tile kind has all features of the first set
-- and no features of the second.
kindHas :: [F.Feature] -> [F.Feature] -> TileKind -> Bool
kindHas yes no t = L.all (`kindHasFeature` t) yes
                   && not (L.any (`kindHasFeature` t) no)

-- | Whether a tile kind (specified by its id) has the given feature.
hasFeature :: Kind.Ops TileKind -> F.Feature -> Kind.Id TileKind -> Bool
hasFeature Kind.Ops{okind} f t =
  kindHasFeature f (okind t)

-- | Whether a tile does not block vision.
-- Essential for efficiency of "FOV", hence tabulated.
isClear :: Kind.Ops TileKind -> Kind.Id TileKind -> Bool
isClear Kind.Ops{ospeedup = Just Kind.TileSpeedup{isClearTab}} = isClearTab
isClear cotile = assert `failure` "no speedup" `with` Kind.obounds cotile

-- | Whether a tile is lit on its own.
-- Essential for efficiency of "Perception", hence tabulated.
isLit :: Kind.Ops TileKind -> Kind.Id TileKind -> Bool
isLit Kind.Ops{ospeedup = Just Kind.TileSpeedup{isLitTab}} = isLitTab
isLit cotile = assert `failure` "no speedup" `with` Kind.obounds cotile

-- | Whether a tile can be explored, possibly yielding a treasure
-- or a hidden message.
isExplorable :: Kind.Ops TileKind -> Kind.Id TileKind -> Bool
isExplorable cops tk = isClear cops tk || hasFeature cops F.Walkable tk

-- | The player can't tell one tile from the other.
similar :: TileKind -> TileKind -> Bool
similar t u =
  tsymbol t == tsymbol u &&
  tname   t == tname   u &&
  tcolor  t == tcolor  u &&
  tcolor2 t == tcolor2 u

speedup :: Bool -> Kind.Ops TileKind -> Kind.Speedup TileKind
speedup allClear Kind.Ops{ofoldrWithKey, obounds} =
  let createTab :: (TileKind -> Bool) -> A.UArray (Kind.Id TileKind) Bool
      createTab p =
        let f _ k acc = p k : acc
            clearAssocs = ofoldrWithKey f []
        in A.listArray obounds clearAssocs
      tabulate :: (TileKind -> Bool) -> Kind.Id TileKind -> Bool
      tabulate p = (createTab p A.!)
      isClearTab | allClear = tabulate $ not . kindHasFeature F.Impenetrable
                 | otherwise = tabulate $ kindHasFeature F.Clear
      isLitTab   = tabulate $ kindHasFeature F.Lit
  in Kind.TileSpeedup {isClearTab, isLitTab}

openTo :: Kind.Ops TileKind -> Kind.Id TileKind -> Rnd (Kind.Id TileKind)
openTo Kind.Ops{okind, opick} t = do
  let getTo (F.OpenTo group) acc = group : acc
      getTo _ acc = acc
  case foldr getTo [] $ tfeature $ okind t of
    [] -> return t
    groups -> do
      group <- oneOf groups
      opick group (const True)

closeTo :: Kind.Ops TileKind -> Kind.Id TileKind -> Rnd (Kind.Id TileKind)
closeTo Kind.Ops{okind, opick} t = do
  let getTo (F.CloseTo group) acc = group : acc
      getTo _ acc = acc
  case foldr getTo [] $ tfeature $ okind t of
    [] -> return t
    groups -> do
      group <- oneOf groups
      opick group (const True)

revealAs :: Kind.Ops TileKind -> Kind.Id TileKind -> Rnd (Kind.Id TileKind)
revealAs Kind.Ops{okind, opick} t = do
  let getTo (F.RevealAs group) acc = group : acc
      getTo _ acc = acc
  case foldr getTo [] $ tfeature $ okind t of
    [] -> return t
    groups -> do
      group <- oneOf groups
      opick group (const True)

hideAs :: Kind.Ops TileKind -> Kind.Id TileKind -> Kind.Id TileKind
hideAs Kind.Ops{okind, ouniqGroup} t =
  let getTo (F.HideAs group) _ = Just group
      getTo _ acc = acc
  in case foldr getTo Nothing (tfeature (okind t)) of
       Nothing    -> t
       Just group -> ouniqGroup group

-- | Whether a tile kind (specified by its id) has a OpenTo feature.
openable :: Kind.Ops TileKind -> Kind.Id TileKind -> Bool
openable Kind.Ops{okind} t =
  let getTo F.OpenTo{} = True
      getTo _ = False
  in any getTo $ tfeature $ okind t

-- | Whether a tile kind (specified by its id) has a CloseTo feature.
closable :: Kind.Ops TileKind -> Kind.Id TileKind -> Bool
closable Kind.Ops{okind} t =
  let getTo F.CloseTo{} = True
      getTo _ = False
  in any getTo $ tfeature $ okind t

-- | Whether a tile kind (specified by its id) has a ChangeTo feature.
changeable :: Kind.Ops TileKind -> Kind.Id TileKind -> Bool
changeable Kind.Ops{okind} t =
  let getTo F.ChangeTo{} = True
      getTo _ = False
  in any getTo $ tfeature $ okind t
