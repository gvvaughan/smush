# Smush the source, Luke!

[![License](http://img.shields.io/:license-mit-blue.svg)](http://mit-license.org)
[![workflow status](https://github.com/gvvaughan/smush/actions/workflows/spec.yml/badge.svg?branch=master)](https://github.com/gvvaughan/smush/actions)
[![codecov.io](https://codecov.io/gh/gvvaughan/smush/graph/badge.svg?branch=master)](https://codecov.io/gh/gvvaughan/smush?branch=master)

[Smush][] ships Lua code as one file, in either of two ways, for
[LuaJIT][] and [Lua][] 5.1, 5.2, 5.3, 5.4 and 5.5:

 * a **bundle** squeezes Lua modules into one Lua file, with their
   comments and white space taken out, to run as a program or to load as a
   module.  It runs wherever there is a Lua.
 * a **standalone program** is one file that carries its own Lua, and the
   C and Lua libraries it uses.  It builds itself the first time that it
   runs, on a machine that has a shell and a C compiler, and needs no Lua,
   no LuaRocks and no network.

Smush is released under the [MIT license][mit] (the same license as Lua
itself).  There is no warranty.


## Usage

To bundle Lua modules:

    smush --main=NAME SOURCE... > program
    smush --module=NAME SOURCE... > module.lua

Each SOURCE is the path of a Lua module, which is bundled as the name
that its path makes (`lib/foo/init.lua` is `foo`), `NAME=PATH`, which is
bundled as NAME, the name of a module that is in the Lua path, or
`ALIAS::MODULE`, which shares one bundled copy of a file that libraries
each keep a copy of.  A bundle runs in an environment of its own, so it
never sees, or is seen by, another copy of a library that the host has.
A module that has a C part is `--external`, and comes from the host.

To make a standalone program, from a bootstrap script that gathers its
sources and a build script that compiles them, which are written in the
small build language that `smush crush` runs:

    smush crush --first-run bootstrap > payload.barf
    smush standalone NAME payload.barf > FILE
    chmod +x FILE

The same commands make a standalone smush, from
`build-aux/standalone-5.1/bootstrap`.

The [manual][] has the rest, including the [bundle][bundles] options, the
[build language][crush], and [how a standalone program
works][standalone].


## Installation

    luarocks install smush

The `smush` command is one file, which has the modules of
[std.normalize][], [std.functional][] and [std.prototype][] that it uses
bundled in, so they are needed to build it, and nothing but Lua is needed
to run it.  LuaRocks builds it with [Luke][], from the rockspec.

Each release also ships `smush-X.Y.sh`, a standalone smush that needs no Lua:
it builds itself with the host machines shell and C compiler the first time
it runs.  Either Rename it `smush` and put it on your `PATH`, or install the
program that it builds directly into your `PATH` with:

    env SMUSH_STANDALONE_INSTALL_DIR=$HOME/.local/bin ./smush-X.Y.sh


## Documentation

Smush includes [comprehensive documentation][github.io], which is
written in [doc/smush.md][manual].


## Development

    specl spec/*_spec.yaml

## Bug reports and code contributions

Please make bug reports and suggestions as [GitHub issues][issues].
Pull requests are especially appreciated.

But first, please check that your issue has not already been reported
by someone else, and that it is not already fixed on [master][github]
in preparation for the next release.

There is no strict coding style, but please bear in mind the following
points when proposing changes:

0. Follow existing code. There are a lot of useful patterns and
   avoided traps there.

1. 3-character indentation using SPACEs in Lua sources.

2. Simple strings are easiest to type using single-quote delimiters
   saving double-quotes for where a string contains apostrophes.

3. Save horizontal space by only using SPACEs where the parser requires
   them.

4. Use vertical space to separate out compound statements to help the
   coverage reports discover untested lines.

5. Prefer explicit string function calls over object methods, to mitigate
   issues with monkey-patching in caller environment.


 [bundles]:        doc/smush.md#3-bundles
 [crush]:          doc/crush.md
 [github.io]:      https://gvvaughan.github.io/smush
 [github]:         https://github.com/gvvaughan/smush
 [issues]:         https://github.com/gvvaughan/smush/issues
 [lua]:            https://www.lua.org
 [luajit]:         https://luajit.org
 [luke]:           https://github.com/gvvaughan/luke
 [manual]:         doc/smush.md
 [mit]:            https://mit-license.org
 [smush]:          https://github.com/gvvaughan/smush
 [standalone]:     doc/smush.md#4-standalone-programs
 [std.functional]: https://github.com/lua-stdlib/functional
 [std.normalize]:  https://github.com/lua-stdlib/normalize
 [std.prototype]:  https://github.com/lua-stdlib/prototype
