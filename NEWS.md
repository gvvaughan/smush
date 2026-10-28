# Smush NEWS - User visible changes

## Noteworthy changes in release ?.? (????-??-??) [?]

### Bug fixes

  - Fixed broken build dependencies to include minimal std.prototype
    with Scanner objects used by smush.


## Noteworthy changes in release 0.1 (2026-10-28) [stable]

### New features

  - smush is a project of its own, moved from luke, where it bundled
    `build-aux/luke`.  It writes one file that bundles the modules that
    it is given, as a script that exits with the result of the `main`
    function of one of them (`--main=NAME`), or as a module that returns
    one of them (`--module=NAME`), and the modules run in an environment
    of their own: they cannot see the modules of the host, apart from
    those that it is told the host provides (`--external=NAME`), or
    leave any behind.  `--main` or `--module` is now needed, where luke
    assumed that the main function was luke's.

  - The `smush` command that LuaRocks installs is smush bundled with
    the modules of std.normalize, std.functional and std.prototype that
    it uses, in one file that needs nothing else installed, which
    LuaRocks builds with luke from the rockspec.  They are needed only to
    build it.

  - A module that the host provides, named by `--external=NAME`, such as
    one written in C that cannot be bundled, is asked of the host's own
    `require` the first time that the bundle needs it, so the host need
    not have loaded it already.

  - A source `ALIAS::MODULE` makes the module ALIAS the bundled module
    MODULE, so that libraries which each have a copy of one file share a
    single bundled copy of it.

  - `smush --version` show release version string, or for a development
    build bake `$USER/$gitref`.

  - `smush --bundled` lists the rocks that are bundled in it, one to a line,
    with their versions, when LuaRocks built it with luarocks-build-luke 0.3
    or later.

  - An option that takes a value is written `--NAME=VALUE` or
    `--NAME VALUE`, and smush exits for an option that it does not know,
    where it took it for a module to bundle and said that it could not
    find the module.

  - The `package.preload` of a bundle is the loaders of the modules that
    it bundles, so that code in a bundle that loads a bundled module in an
    environment of its own, as a test runner does, can find its loader.

### Incompatible changes

  - smush exits for an option that it does not know, where it took it
    for a module to bundle.

  - The `package.preload` and `package.loaded` of a bundle are not empty:
    they have the loaders of the modules that it bundles, and the
    standard libraries, `_G` and `package` that it has of its own.

  - A module that `--external=NAME` names is asked of the host's own
    `require` the first time that the bundle needs it, and not taken
    from the host's `package.loaded` when the bundle starts, so a host
    that cannot load it now fails when the bundle needs it, where the
    bundle used to find `nil`.

### Bug fixes

  - A bundle can `require` the standard libraries that every supported Lua
    has, as in any Lua: its `package.loaded` has `coroutine`, `debug`, `io`,
    `math`, `os`, `string` and `table`, and its own `_G` and `package`.
    `require 'string'` previously failed `no bundled module 'string'`.
    A library that only some Luas have, such as `utf8` or `ffi`, is not
    there unless the bundle is built with `--external=utf8`, or whichever
    it needs, to say that the code that needs it is tied to a Lua that
    has it.

  - smush now warns when a bundled module requires a module that isn't
    bundled, even if the missing module's name starts with the name of
    one that is.  It had taken `optparse._strict` for a part of
    `optparse`, and not said that it was missing, so the bundle failed
    when it ran.

  - Two minuses are not written next to each other, which were a
    comment, so `a - -b` is `a - -b` still.

  - A number, then the dots that follow it, are not written without
    a space between them, which was a malformed number: `1 ..2`.

  - A bracket, then a string in long brackets, are not written without
    a space between them, which was a longer string: `t[ [[key]] ]`.

  - Numbers are not changed: hexadecimal and floating point numbers were
    cut short at their first letter or point, and leading zeros were
    dropped.

  - A string or comment that is never closed is an error that says which
    file and line, where it used to loop for ever.
