-- | Text frontend based on HSCurses.
module Game.LambdaHack.Frontend.Curses
  ( -- * Session data type for the frontend
    FrontendSession
    -- * The output and input operations
  , fdisplay, fpromptGetKey
    -- * Frontend administration tools
  , frontendName, startup
  ) where

import Control.Monad
import Data.Char (chr, ord)
import qualified Data.List as L
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified UI.HSCurses.Curses as C
import qualified UI.HSCurses.CursesHelper as C

import Game.LambdaHack.Common.Animation (DebugModeCli (..), SingleFrame (..))
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Key as K
import Game.LambdaHack.Utils.Assert

-- | Session data maintained by the frontend.
data FrontendSession = FrontendSession
  { swin      :: !C.Window  -- ^ the window to draw to
  , sstyles   :: !(M.Map Color.Attr C.CursesStyle)
      -- ^ map from fore/back colour pairs to defined curses styles
  , sdebugCli :: !DebugModeCli  -- ^ client configuration
  }

-- | The name of the frontend.
frontendName :: String
frontendName = "curses"

-- | Starts the main program loop using the frontend input and output.
startup :: DebugModeCli -> (FrontendSession -> IO ()) -> IO ()
startup sdebugCli k = do
  C.start
--  C.keypad C.stdScr False  -- TODO: may help to fix xterm keypad on Ubuntu
  void $ C.cursSet C.CursorInvisible
  let s = [ (Color.Attr{fg, bg}, C.Style (toFColor fg) (toBColor bg))
          | fg <- [minBound..maxBound],
            -- No more color combinations possible: 16*4, 64 is max.
            bg <- Color.legalBG ]
  nr <- C.colorPairs
  when (nr < L.length s) $
    C.end >> (assert `failure` "terminal has too few color pairs" `with` nr)
  let (ks, vs) = unzip s
  ws <- C.convertStyles vs
  let swin = C.stdScr
      sstyles = M.fromList (zip ks ws)
  k FrontendSession{..}
  C.end

-- | Output to the screen via the frontend.
fdisplay :: FrontendSession    -- ^ frontend session data
         -> Bool
         -> Maybe SingleFrame  -- ^ the screen frame to draw
         -> IO ()
fdisplay _ _ Nothing = return ()
fdisplay FrontendSession{..}  _ (Just SingleFrame{..}) = do
  -- let defaultStyle = C.defaultCursesStyle
  -- Terminals with white background require this:
  let defaultStyle = sstyles M.! Color.defAttr
  C.erase
  C.setStyle defaultStyle
  C.mvWAddStr swin 0 0 (T.unpack sfTop)
  -- We need to remove the last character from the status line,
  -- because otherwise it would overflow a standard size xterm window,
  -- due to the curses historical limitations.
  C.mvWAddStr swin (L.length sfLevel + 1) 0 (L.init $ T.unpack sfBottom)
  let nm = L.zip [0..] $ L.map (L.zip [0..]) sfLevel
  sequence_ [ C.setStyle (M.findWithDefault defaultStyle acAttr sstyles)
              >> C.mvWAddStr swin (y + 1) x [acChar]
            | (y, line) <- nm, (x, Color.AttrChar{..}) <- line ]
  C.refresh

-- | Input key via the frontend.
nextEvent :: FrontendSession -> IO K.KM
nextEvent FrontendSession{sdebugCli=DebugModeCli{snoMore}} =
  if snoMore then return K.escKey
  else keyTranslate `fmap` C.getKey C.refresh

-- | Display a prompt, wait for any key.
fpromptGetKey :: FrontendSession -> SingleFrame -> IO K.KM
fpromptGetKey sess frame = do
  fdisplay sess True $ Just frame
  nextEvent sess

keyTranslate :: C.Key -> K.KM
keyTranslate e = (\(key, modifier) -> K.KM {..}) $
  case e of
    C.KeyChar '\ESC' -> (K.Esc,     K.NoModifier)
    C.KeyExit        -> (K.Esc,     K.NoModifier)
    C.KeyChar '\n'   -> (K.Return,  K.NoModifier)
    C.KeyChar '\r'   -> (K.Return,  K.NoModifier)
    C.KeyEnter       -> (K.Return,  K.NoModifier)
    C.KeyChar ' '    -> (K.Space,   K.NoModifier)
    C.KeyChar '\t'   -> (K.Tab,     K.NoModifier)
    C.KeyBTab        -> (K.BackTab, K.NoModifier)
    C.KeyUp          -> (K.Up,      K.NoModifier)
    C.KeyDown        -> (K.Down,    K.NoModifier)
    C.KeyLeft        -> (K.Left,    K.NoModifier)
    C.KeySLeft       -> (K.Left,    K.NoModifier)
    C.KeyRight       -> (K.Right,   K.NoModifier)
    C.KeySRight      -> (K.Right,   K.NoModifier)
    C.KeyHome        -> (K.Home,    K.NoModifier)
    C.KeyPPage       -> (K.PgUp,    K.NoModifier)
    C.KeyEnd         -> (K.End,     K.NoModifier)
    C.KeyNPage       -> (K.PgDn,    K.NoModifier)
    C.KeyBeg         -> (K.Begin,   K.NoModifier)
    C.KeyB2          -> (K.Begin,   K.NoModifier)
    C.KeyClear       -> (K.Begin,   K.NoModifier)
    -- No KP_ keys; see <https://github.com/skogsbaer/hscurses/issues/10>
    -- TODO: try to get the Control modifier for keypad keys from the escape
    -- gibberish and use Control-keypad for KP_ movement.
    C.KeyChar c
      -- This case needs to be considered after Tab, since, apparently,
      -- on some terminals ^i == Tab and Tab is more important for us.
      | ord '\^A' <= ord c && ord c <= ord '\^Z' ->
        -- Alas, only lower-case letters.
        (K.Char $ chr $ ord c - ord '\^A' + ord 'a', K.Control)
        -- Movement keys are more important than hero selection,
        -- so disabling the latter and interpreting the keypad numbers
        -- as movement:
      | c `elem` ['1'..'9'] -> (K.KP c,              K.NoModifier)
      | otherwise           -> (K.Char c,            K.NoModifier)
    _                       -> (K.Unknown (show e),  K.NoModifier)

toFColor :: Color.Color -> C.ForegroundColor
toFColor Color.Black     = C.BlackF
toFColor Color.Red       = C.DarkRedF
toFColor Color.Green     = C.DarkGreenF
toFColor Color.Brown     = C.BrownF
toFColor Color.Blue      = C.DarkBlueF
toFColor Color.Magenta   = C.PurpleF
toFColor Color.Cyan      = C.DarkCyanF
toFColor Color.White     = C.WhiteF
toFColor Color.BrBlack   = C.GreyF
toFColor Color.BrRed     = C.RedF
toFColor Color.BrGreen   = C.GreenF
toFColor Color.BrYellow  = C.YellowF
toFColor Color.BrBlue    = C.BlueF
toFColor Color.BrMagenta = C.MagentaF
toFColor Color.BrCyan    = C.CyanF
toFColor Color.BrWhite   = C.BrightWhiteF

toBColor :: Color.Color -> C.BackgroundColor
toBColor Color.Black     = C.BlackB
toBColor Color.Red       = C.DarkRedB
toBColor Color.Green     = C.DarkGreenB
toBColor Color.Brown     = C.BrownB
toBColor Color.Blue      = C.DarkBlueB
toBColor Color.Magenta   = C.PurpleB
toBColor Color.Cyan      = C.DarkCyanB
toBColor Color.White     = C.WhiteB
toBColor _               = C.BlackB  -- a limitation of curses
