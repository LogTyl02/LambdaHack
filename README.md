LambdaHack [![Build Status](https://secure.travis-ci.org/kosmikus/LambdaHack.png)](http://travis-ci.org/kosmikus/LambdaHack)
==========

This is an alpha release of LambdaHack, a [Haskell] [1] game engine
library for [roguelike] [2] games of arbitrary theme, size and complexity,
packaged together with a small example dungeon crawler. When completed,
the engine will let you specify content to be procedurally generated,
define the AI behaviour on top of the generic content-independent rules
and compile a ready-to-play game binary, using either the supplied
or a custom-made main loop. Several frontends are available
(GTK is the default) and many other generic engine components
are easily overridden, but the fundamental source of flexibility lies
in the strict and type-safe separation of code and content and of clients
(human and AI-controlled) and server. Long-term goals for LambdaHack include
support for multiplayer tactical squad combat, in-game content creation,
auto-balancing and persistent content modification based
on player behaviour.

The engine comes with a sample code for a little dungeon crawler,
called LambdaHack and described in PLAYING.md. The engine and the example
game are bundled together in a single [Hackage] [3] package.
You are welcome to create your own games by modifying the sample game
and the engine code, but please consider eventually splitting your changes
into a separate Hackage package that depends on the upstream library,
to help us exchange ideas and share improvements to the common code.

Games known to use the LambdaHack library:

* [Allure of the Stars] [6], a near-future Sci-Fi game in early development


Compilation and installation
----------------------------

The library is best compiled and installed via Cabal, which also takes care
of all dependencies. The latest official version of the library
can be downloaded automatically by Cabal from [Hackage] [3] as follows

    cabal install LambdaHack

For a newer snapshot, download source from a development branch
at [github] [5] and run Cabal from the main directory

    cabal install

For the example game, the best frontend (wrt keyboard support and colours)
is the default gtk. To compile with one of the terminal frontends,
use Cabal flags, e.g,

    cabal install -fvty


Compatibility notes
-------------------

The current code was tested with GHC 7.6, but should also work with
other GHC versions (see file .travis.yml for GHC 7.4 commands).

If you are using the curses or vty frontends,
numerical keypad may not work correctly depending on the versions
of curses, terminfo and terminal emulators.
Selecting heroes via number keys or SHIFT-keypad keys is disabled
with curses, because CTRL-keypad for running does not work there,
so the numbers produced by the keypad have to be used. With vty on xterm,
CTRL-direction keys seem to work OK, but on rxvt they do not.
Vi keys (ykuhlbjn) should work everywhere regardless. Gtk works fine, too.


Testing and debugging
---------------------

The Makefile contains many sample test commands. All that use the screensaver
game modes (AI vs. AI) and the simplest stdout frontend are gathered
in `make test`. Of these, travis runs the set contained in
`make test-travis` on each push to the repo. Commands with prefix
`frontend` run AI vs. AI games with the standard, user-friendly frontend.
Commands with prefix `peek` set up a game mode where the player peeks
into AI moves each time an AI actor dies or autosave kicks in.
Run `LambdaHack --help` to see a brief description of all debug options.
Of these, `--sniffIn` and `--sniffOut` are very useful (though verbose
and initially cryptic), for monitoring the traffic between clients
and the server. Some options in config files may turn out useful too,
though they mostly overlap with commandline options (and will be totally
merged at some point).

You can use HPC with the game as follows

    cabal clean
    cabal install --enable-library-coverage
    make test
    hpc report --hpcdir=dist/hpc/mix/LambdaHack-0.2.10/ LambdaHack
    hpc markup --hpcdir=dist/hpc/mix/LambdaHack-0.2.10/ LambdaHack

The debug option `--stopAfter` is required for any screensaver mode
game invocations that gather HPC info, because HPC needs a clean exit
(to save data files) and screensaver modes can't be cleanly stopped
in any other way.


Further information
-------------------

For more information, visit the [wiki] [4]
and see the files PLAYING.md, CREDITS and LICENSE.

Have fun!



[1]: http://www.haskell.org/
[2]: http://roguebasin.roguelikedevelopment.org/index.php?title=Berlin_Interpretation
[3]: http://hackage.haskell.org/package/LambdaHack
[4]: https://github.com/kosmikus/LambdaHack/wiki
[5]: http://github.com/kosmikus/LambdaHack
[6]: http://hackage.haskell.org/package/Allure
