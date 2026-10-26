# Smush the source, Luke!

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

  * `--main=NAME` writes a script that exits with the result of calling
    the `main` function of the bundled module NAME with its arguments.
  * `--module=NAME` writes a module that returns the bundled module NAME.
  * `--external=NAME` says that the host provides the module NAME to the
    bundle, which is how a bundle reaches a module that cannot be
    bundled, such as one written in C.

For example, `smush` is bundled with the modules that it uses, so that it
needs nothing else to be installed:

    smush --main=smush smush smush.lexer \
        std.prototype.contextmanager std.prototype.scanner \
        std.prototype.set std.prototype.object std.prototype.container \
        std.prototype._base std.functional.init std.functional._base \
        std.normalize std.normalize._core > smush-bundle

Smush warns of a module in the Lua path that a bundled module names but
that is not bundled, unless it is external or is only asked for with
`pcall(require, 'name')`.


## The environment of a bundle

The modules of a bundle run in an environment of their own, with copies
of the globals, and a `require` and `package.loaded` of their own, so:

  * a bundled module never finds a module of the same name that the host
    has loaded, nor does it see the host's `package.path` or
    `package.loaded`, except for the modules that are `--external`;
  * nothing a bundled module loads is left in the host's `package.loaded`;
  * a bundled copy of a library does not see, and is not seen by, another
    copy of it that the host has.  That is what lets a program that is
    built on libraries, such as a test runner that is built on the
    libraries that it tests, be one file that has no place in a LuaRocks
    tree.

A module that has a C part can be bundled for its Lua part, with
`--external` for the C part.


## Installation

    luarocks install smush

Smush needs [std.normalize][], [std.functional][] and [std.prototype][].


## Development

    specl spec/*_spec.yaml

 [lua]:            https://www.lua.org
 [luajit]:         https://luajit.org
 [mit]:            https://mit-license.org
 [smush]:          https://github.com/gvvaughan/smush
 [std.functional]: https://github.com/lua-stdlib/functional
 [std.normalize]:  https://github.com/lua-stdlib/normalize
 [std.prototype]:  https://github.com/lua-stdlib/prototype
