-- | The type of kinds of monsters and heroes.
module Game.LambdaHack.Content.ActorKind
  ( ActorKind(..), avalidate
  ) where

import Control.Arrow ((&&&))
import Data.List
import qualified Data.Ord as Ord
import Data.Text (Text)

import Game.LambdaHack.Common.Ability
import Game.LambdaHack.Common.Color
import Game.LambdaHack.Common.Misc
import qualified Game.LambdaHack.Common.Random as Random
import Game.LambdaHack.Common.Time

-- TODO: make all but a few fields optional in some way, so that, a.g.,
-- a game content with no regeneration does not ever need to mention aregen.
-- | Actor properties that are fixed for a given kind of actors.
data ActorKind = ActorKind
  { asymbol :: !Char             -- ^ map symbol
  , aname   :: !Text             -- ^ short description
  , afreq   :: !Freqs            -- ^ frequency within groups
  , acolor  :: !Color            -- ^ map color
  , aspeed  :: !Speed            -- ^ natural speed in m/s
  , ahp     :: !Random.RollDice  -- ^ encodes initial and maximal hp
  , asight  :: !Bool             -- ^ can it see?
  , asmell  :: !Bool             -- ^ can it smell?
  , aiq     :: !Int              -- ^ intelligence
  , aregen  :: !Int              -- ^ number of turns to regenerate 1 HP
  , acanDo  :: ![Ability]        -- ^ the set of supported abilities
  }
  deriving Show  -- No Eq and Ord to make extending it logically sound, see #53

-- | Filter a list of kinds, passing through only the incorrect ones, if any.
--
-- Make sure actor kinds can be told apart on the level map.
avalidate :: [ActorKind] -> [ActorKind]
avalidate l =
  let cmp = Ord.comparing $ asymbol &&& acolor
      eq ka1 ka2 = cmp ka1 ka2 == Ord.EQ
      sorted = sortBy cmp l
      nubbed = nubBy eq sorted
  in deleteFirstsBy eq sorted nubbed
