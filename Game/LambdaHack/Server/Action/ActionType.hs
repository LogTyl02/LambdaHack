{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | The main game action monad type implementation. Just as any other
-- component of the library, this implementation can be substituted.
-- This module should not be imported anywhere except in 'Action'
-- to expose the executor to any code using the library.
module Game.LambdaHack.Server.Action.ActionType
  ( ActionSer, executorSer
  ) where

import qualified Control.Monad.IO.Class as IO
import Control.Monad.Trans.State.Strict hiding (State)
import qualified Data.EnumMap.Strict as EM
import Data.Maybe
import System.FilePath

import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.ClientCmd
import qualified Game.LambdaHack.Common.Save as Save
import Game.LambdaHack.Common.State
import Game.LambdaHack.Server.Action.ActionClass
import Game.LambdaHack.Server.Config
import Game.LambdaHack.Server.State

data SerState = SerState
  { serState  :: !State           -- ^ current global state
  , serServer :: !StateServer     -- ^ current server state
  , serDict   :: !ConnServerDict  -- ^ client-server connection information
  , serToSave :: !(Save.ChanSave (State, StateServer))
                                  -- ^ connection to the save thread
  }

-- | Server state transformation monad.
newtype ActionSer a = ActionSer {runActionSer :: StateT SerState IO a}
  deriving (Monad, Functor)

instance MonadActionRO ActionSer where
  getState    = ActionSer $ gets serState
  getsState f = ActionSer $ gets $ f . serState

instance MonadAction ActionSer where
  modifyState f =
    ActionSer $ modify $ \serS -> serS {serState = f $ serState serS}
  putState    s =
    ActionSer $ modify $ \serS -> serS {serState = s}

instance MonadServer ActionSer where
  getServer      = ActionSer $ gets serServer
  getsServer   f = ActionSer $ gets $ f . serServer
  modifyServer f =
    ActionSer $ modify $ \serS -> serS {serServer = f $ serServer serS}
  putServer    s =
    ActionSer $ modify $ \serS -> serS {serServer = s}
  liftIO         = ActionSer . IO.liftIO
  saveServer     = ActionSer $ do
    s <- gets serState
    ser <- gets serServer
    toSave <- gets serToSave
    IO.liftIO $ Save.saveToChan toSave (s, ser)

instance MonadConnServer ActionSer where
  getDict      = ActionSer $ gets serDict
  getsDict   f = ActionSer $ gets $ f . serDict
  modifyDict f =
    ActionSer $ modify $ \serS -> serS {serDict = f $ serDict serS}
  putDict    s =
    ActionSer $ modify $ \serS -> serS {serDict = s}

-- | Run an action in the @IO@ monad, with undefined state.
executorSer :: ActionSer () -> IO ()
executorSer m =
  let saveFile (_, ser) =
        configAppDataDir (sconfig ser)
        </> fromMaybe "save" (ssavePrefixSer (sdebugSer ser))
        <.> saveName
      exe toSave =
        evalStateT (runActionSer m)
          SerState { serState = emptyState
                   , serServer = emptyStateServer
                   , serDict = EM.empty
                   , serToSave = toSave
                   }
  in Save.wrapInSaves saveFile exe
