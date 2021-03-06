-- | Cave layouts for LambdaHack.
module Content.CaveKind ( cdefs ) where

import Data.Ratio

import Game.LambdaHack.Common.ContentDef
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Random as Random
import Game.LambdaHack.Content.CaveKind

cdefs :: ContentDef CaveKind
cdefs = ContentDef
  { getSymbol = csymbol
  , getName = cname
  , getFreq = cfreq
  , validate = cvalidate
  , content =
      [rogue, arena, empty, noise, combat]
  }
rogue,        arena, empty, noise, combat :: CaveKind

rogue = CaveKind
  { csymbol       = '$'
  , cname         = "A maze of twisty passages"
  , cfreq         = [("dng", 100), ("caveRogue", 1)]
  , cxsize        = fst normalLevelBound + 1
  , cysize        = snd normalLevelBound + 1
  , cgrid         = RollDiceXY (rollDice 2 3, rollDice 2 2)
  , cminPlaceSize = RollDiceXY (rollDice 2 2, rollDice 2 1)
  , cdarkChance   = (rollDice 1 54, rollDice 0 0)
  , cauxConnects  = 1%3
  , cvoidChance   = 1%4
  , cnonVoidMin   = 4
  , cminStairDist = 30
  , cdoorChance   = 1%2
  , copenChance   = 1%10
  , chidden       = 8
  , citemNum      = rollDice 7 2
  , cdefTile        = "fillerWall"
  , ccorridorTile   = "darkCorridor"
  , cfillerTile     = "fillerWall"
  , cdarkLegendTile = "darkLegend"
  , clitLegendTile  = "litLegend"
  }
arena = rogue
  { csymbol       = 'A'
  , cname         = "Underground city"
  , cfreq         = [("dng", 30), ("caveArena", 1)]
  , cgrid         = RollDiceXY (rollDice 2 2, rollDice 2 2)
  , cminPlaceSize = RollDiceXY (rollDice 3 2, rollDice 2 1)
  , cdarkChance   = (rollDice 1 80, rollDice 1 60)
  , cvoidChance   = 1%3
  , cnonVoidMin   = 2
  , chidden       = 9
  , citemNum      = rollDice 4 2  -- few rooms
  , cdefTile      = "floorArenaLit"
  , ccorridorTile = "path"
  }
empty = rogue
  { csymbol       = '.'
  , cname         = "Tall cavern"
  , cfreq         = [("dng", 20), ("caveEmpty", 1)]
  , cgrid         = RollDiceXY (rollDice 2 2, rollDice 1 2)
  , cminPlaceSize = RollDiceXY (rollDice 4 3, rollDice 4 1)
  , cdarkChance   = (rollDice 1 80, rollDice 1 80)
  , cauxConnects  = 1
  , cvoidChance   = 3%4
  , cnonVoidMin   = 1
  , cminStairDist = 50
  , chidden       = 10
  , citemNum      = rollDice 8 2  -- whole floor strewn with treasure
  , cdefTile      = "floorRoomLit"
  , ccorridorTile = "floorRoomLit"
  }
noise = rogue
  { csymbol       = '!'
  , cname         = "Glittering cave"
  , cfreq         = [("dng", 20), ("caveNoise", 1)]
  , cgrid         = RollDiceXY (rollDice 2 2, rollDice 1 2)
  , cminPlaceSize = RollDiceXY (rollDice 4 2, rollDice 4 1)
  , cdarkChance   = (rollDice 1 80, rollDice 1 40)
  , cvoidChance   = 0
  , cnonVoidMin   = 0
  , chidden       = 6
  , citemNum      = rollDice 4 2  -- few rooms
  , cdefTile      = "noiseSet"
  , ccorridorTile = "path"
  }
combat = rogue
  { csymbol       = 'C'
  , cname         = "Combat arena"
  , cfreq         = [("caveCombat", 1)]
  , cgrid         = RollDiceXY (rollDice 5 2, rollDice 2 2)
  , cminPlaceSize = RollDiceXY (rollDice 1 1, rollDice 1 1)
  , cdarkChance   = (rollDice 1 100, rollDice 1 100)
  , cvoidChance   = 1%10
  , cnonVoidMin   = 8
  , chidden       = 100
  , citemNum      = rollDice 12 2
  , cdefTile      = "combatSet"
  , ccorridorTile = "path"
  }
