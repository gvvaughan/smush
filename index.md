---
layout: default
---
# SMUSH

[Smush] bundles Lua modules into a single file, with their comments and
white space squeezed out, to run as a program or to load as a module, for
[LuaJIT] and [Lua] 5.1 through 5.5:

 * one file to ship, with [nothing to install](#1-installation) but Lua
 * a [command line](#2-command-line) that takes the modules to bundle,
   by path or by name
 * bundled modules that run in an [environment of their own](#4-the-environment-of-a-bundle),
   so a bundle and the host it is loaded into never see each other's
   copies of a library
 * [aliases](#3-sources) that make libraries which each keep a copy of one
   file share a single bundled copy of it
 * [externals](#5-external-modules) for the modules that cannot be bundled,
   such as those written in C
 * [warnings](#6-warnings) of the modules that a bundle needs and doesn't have
 * easy to drive [from a rockspec](#7-rockspecs), as [Luke] and [Specl] do

Smush is released under the [MIT license][mit], the same license as Lua
itself.  There is no warranty.


## 1. Installation

    luarocks install smush

The `smush` command is one file, with the modules of [std.normalize],
[std.functional] and [std.prototype] that it uses bundled in, so those are
needed to build it, and nothing but Lua is needed to run it.  LuaRocks
builds it, from the rockspec, with [Luke].

Each release also commits that file, `build-aux/smush`, to its release
branch, so you can copy it into a project of your own.


## 2. Command Line

    smush --main=NAME SOURCE... > program
    smush --module=NAME SOURCE... > module.lua

Smush writes to standard output.  With `--main=NAME` it writes a script,
which exits with the result of calling the `main` function of the bundled
module NAME with the arguments of the command line.  With `--module=NAME`
it writes a module, which returns the bundled module NAME.  One of them is
needed.

An option that takes a value is written `--NAME=VALUE` or `--NAME VALUE`.

  * `--main=NAME` writes a script that exits with the result of calling the
    `main` function of the bundled module NAME;
  * `--module=NAME` writes a module that returns the bundled module NAME;
  * `--external=NAME` says that the host provides the module NAME to the
    bundle (see [External Modules](#5-external-modules));
  * `--help` shows how to use smush, and exits;
  * `--version` shows which version of smush it is, and exits;
  * `--bundled` lists the rocks bundled in smush, one to a line, and exits.

Smush exits with an error for any other option.


## 3. Sources

Each SOURCE is one of:

  * the path of a Lua module, such as `lib/foo/init.lua`, which is bundled
    as the name that its path makes: `foo`.  Without an `init`, the path
    `lib/foo/bar.lua` makes `foo.bar`;
  * `NAME=PATH`, which is bundled as NAME, whatever its path;
  * the name of a module that is in the Lua path, such as `std.normalize`,
    which is bundled under that name;
  * `ALIAS::MODULE`, which makes the module ALIAS the bundled module MODULE,
    and not a copy of it.

An alias is for libraries that each keep a copy of one file, such as
`typecheck._normalize` and `optparse._normalize`, which are copies of
`std.normalize._core`.  They share the one that is bundled, and there is
no copy of it to differ from it:

    smush --main=specl.cli lib/specl/cli.lua std.normalize std.normalize._core \
        typecheck optparse \
        typecheck._normalize::std.normalize._core \
        optparse._normalize::std.normalize._core

MODULE has to be bundled, and ALIAS can't be, or be external, already, or
smush exits with an error that says so.


## 4. The Environment of a Bundle

The modules of a bundle run in an environment of their own, with copies of
the globals, and a `require` and a `package.loaded` of their own, so:

  * a bundled module never finds a module of the same name that the host
    has loaded, nor does it see the host's `package.path` or
    `package.loaded`, except for the modules that are
    [external](#5-external-modules);
  * the `package.loaded` of a bundle has the standard libraries, and its own
    `_G` and `package`, so `require 'string'` works in a bundle, as it does
    anywhere;
  * nothing that a bundled module loads is left in the host's
    `package.loaded`;
  * the `package.preload` of a bundle is the loaders of its bundled modules,
    so that a program that loads them itself, in an environment of its own,
    as a test runner does for the modules of the code that it tests, can
    find them;
  * a bundled copy of a library does not see, and is not seen by, another
    copy of it that the host has.  That is what lets a program that is built
    on libraries, such as a test runner that is built on the libraries that
    it tests, be one file that has no place in a LuaRocks tree.


## 5. External Modules

A module that has a C part, such as `lpeg` or `yaml`, can't be bundled, so
bundle the Lua modules that use it, and say that the host provides it:

    smush --main=app --external=lpeg lib/app.lua > app

The bundle asks the host's own `require` for an external module the first
time that it needs it, so the host need not have loaded it already.  The
module is then the host's, and is shared with it.  `--external=package`
gives the bundle the host's real `package`, which a program that sets
search paths for code that it runs, as a test runner does, needs.


## 6. Warnings

Smush warns of a module in the Lua path that a bundled module names, but
that is not bundled, when it is neither external nor only asked for with
`pcall(require, 'name')`, because a bundle that needs it would fail when it
ran, and says which bundled module names it:

    smush: warning: four names the module 'three', which is in the Lua path, but is not bundled

A module that is part of a bundled module, such as `optparse._strict` of
`optparse`, is warned of too, if it is in the Lua path and not bundled, so
that a library that has gained a file is not bundled without it.


## 7. Rockspecs

Smush is easy to drive from the `build` table of a rockspec that is built
with [luarocks-build-luke].  This is how [Specl] bundles itself:

{% highlight lua %}
build = {
   type = 'luke',

   variables = {
      SMUSH = {checkprog = 'SMUSH', progs = {'smush'}},
   },

   bin = {
      {['build-aux/specl'] = {
         command = '$SMUSH --main=specl.cli $sources > $target',
         sources = {'lib/specl/cli.lua', 'lib/specl/main.lua', 'std.normalize'},
      }},
   },

   install = {
      bin = {specl = 'build-aux/specl'},
   },
}
{% endhighlight %}

Luke finds smush in `PATH`, and builds `build-aux/specl` from the sources.
A module that is named, as `std.normalize` is, is found in `LUA_PATH`,
which `luarocks path` sets.

Report bugs at the [issue tracker][issues].


 [issues]:               https://github.com/gvvaughan/smush/issues
 [lua]:                  https://www.lua.org
 [luajit]:               https://luajit.org
 [luarocks-build-luke]:  https://luarocks.org/modules/gvvaughan/luarocks-build-luke
 [luke]:                 https://gvvaughan.github.io/luke
 [mit]:                  https://mit-license.org
 [smush]:                https://github.com/gvvaughan/smush
 [specl]:                https://gvvaughan.github.io/specl
 [std.functional]:       https://github.com/lua-stdlib/functional
 [std.normalize]:        https://github.com/lua-stdlib/normalize
 [std.prototype]:        https://github.com/lua-stdlib/prototype
