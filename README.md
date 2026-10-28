# Smush the source, Luke!

[![License](http://img.shields.io/:license-mit-blue.svg)](http://mit-license.org)
[![workflow status](https://github.com/gvvaughan/smush/actions/workflows/spec.yml/badge.svg?branch=release-v0.1.1)](https://github.com/gvvaughan/smush/actions)
[![codecov.io](https://codecov.io/gh/gvvaughan/smush/graph/badge.svg?branch=release-v0.1.1)](https://codecov.io/gh/gvvaughan/smush?branch=release-v0.1.1)

[Smush][] bundles Lua modules into a single file, with their comments
and white space squeezed out, to run as a program or to load as a
module, for [LuaJIT][] and [Lua][] 5.1, 5.2, 5.3, 5.4 and 5.5.

Smush is released under the [MIT license][mit] (the same license as Lua
itself).  There is no warranty.


## Usage

    smush --main=NAME SOURCE... > program
    smush --module=NAME SOURCE... > module.lua

Each SOURCE is the path of a Lua module, which is bundled as the name
that its path makes (`lib/foo/init.lua` is `foo`), `NAME=PATH`, which is
bundled as NAME, or the name of a module that is in the Lua path.

`ALIAS::MODULE` makes the module ALIAS the bundled module MODULE, in place
of a source of its own.  Libraries that each keep a copy of one file, such
as `typecheck._normalize` and `optparse._normalize`, which are copies of
`std.normalize._core`, can then share the one that is bundled, with
`typecheck._normalize::std.normalize._core`, and the bundle has one
instance of it, and no copy to differ from it.

An option that takes a value is written `--NAME=VALUE` or `--NAME VALUE`.

  * `--main=NAME` writes a script that exits with the result of calling
    the `main` function of the bundled module NAME with its arguments.
  * `--module=NAME` writes a module that returns the bundled module NAME.
  * `--external=NAME` says that the host provides the module NAME to the
    bundle, which is how a bundle reaches a module that cannot be
    bundled, such as one written in C.  The bundle asks the host for it,
    with the host's own `require`, the first time that it needs it, so
    the host need not have loaded it already.

Smush warns of a module in the Lua path that a bundled module names but
that is not bundled, unless it is external or is only asked for with
`pcall(require, 'name')`.


## The environment of a bundle

The modules of a bundle run in their own environment, with copies of the
globals, and a custom `require` and `package.loaded`, so:

  * a bundled module never finds a module of the same name that the host
    has loaded, nor does it see the host's `package.loaded`, except for the
    modules that are `--external`; its `package.loaded` has the standard
    libraries that every supported Lua has (`coroutine`, `debug`, `io`,
    `math`, `os`, `string` and `table`), and its own `_G` and `package`, so
    `require 'string'` works in a bundle, as it does anywhere.  A library
    that only some Luas have, such as `utf8` or `ffi`, needs `--external`;
  * nothing a bundled module loads is left in the host's `package.loaded`;
  * a bundled copy of a library is hermetically separated from any other
    copy of it that the host has installed.  This lets a program such as
    a test runner use its bundled libraries even while it tests a different
    version of the same libraries it is calling internally.

A module that has a C part can be partially bundled for only its Lua part,
with `--external` for the C part.


## Installation

    luarocks install smush

The `smush` command is one file, which has the modules of
[std.normalize][], [std.functional][] and [std.prototype][] that it uses
bundled in, so they are needed to build it, and nothing but Lua is needed
to run it.  LuaRocks builds it with [Luke][], from the rockspec.


## Documentation

Luke includes [comprehensive documentation][github.io], which is
written in [doc/smush.md][manual].


## Development

    specl spec/*_spec.yaml

 [github.io]:      https://gvvaughan.github.io/smush
 [lua]:            https://www.lua.org
 [luke]:           https://github.com/gvvaughan/luke
 [luajit]:         https://luajit.org
 [manual]:         doc/smush.md
 [mit]:            https://mit-license.org
 [smush]:          https://github.com/gvvaughan/smush
 [std.functional]: https://github.com/lua-stdlib/functional
 [std.normalize]:  https://github.com/lua-stdlib/normalize
 [std.prototype]:  https://github.com/lua-stdlib/prototype
