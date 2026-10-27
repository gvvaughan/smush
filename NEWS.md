<!--
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
-->

# Smush NEWS - User visible changes

## Noteworthy changes in release ?.? (????-??-??) [?]

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

  - An option that takes a value is written `--NAME=VALUE` or
    `--NAME VALUE`, and smush exits for an option that it does not know,
    where it took it for a module to bundle and said that it could not
    find the module.

### Bug fixes

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
