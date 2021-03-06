-- | The type of kinds of game factions (heroes, enemies, NPCs, etc.)
-- for LambdaHack.
module Content.FactionKind ( cdefs ) where

import Game.LambdaHack.Common.Ability
import Game.LambdaHack.Common.ContentDef
import Game.LambdaHack.Content.FactionKind

cdefs :: ContentDef FactionKind
cdefs = ContentDef
  { getSymbol = fsymbol
  , getName = fname
  , getFreq = ffreq
  , validate = fvalidate
  , content =
      [hero, monster, horror]
  }
hero,        monster, horror :: FactionKind

hero = FactionKind
  { fsymbol        = '@'
  , fname          = "hero"
  , ffreq          = [("hero", 1)]
  , fAbilityLeader = allAbilities
  , fAbilityOther  = meleeAdjacent
  }

monster = FactionKind
  { fsymbol        = 'm'
  , fname          = "monster"
  , ffreq          = [("monster", 1), ("spawn", 50), ("summon", 50)]
  , fAbilityLeader = allAbilities
  , fAbilityOther  = allAbilities
  }

horror = FactionKind
  { fsymbol        = 'h'
  , fname          = "horror"
  , ffreq          = [("horror", 1), ("summon", 50)]
  , fAbilityLeader = allAbilities
  , fAbilityOther  = allAbilities
  }


_noAbility, _onlyFollowTrack, meleeAdjacent, _meleeAndRanged, allAbilities :: [Ability]

_noAbility = []  -- not even projectiles will fly

_onlyFollowTrack = [Track]  -- projectiles enabled

meleeAdjacent = [Track, Melee]

_meleeAndRanged = [Track, Melee, Ranged]  -- melee and reaction fire

allAbilities = [minBound..maxBound]
