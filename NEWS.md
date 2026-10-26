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

  - smush bundles itself, which it needs as a program that needs nothing
    installed: `smush --main=smush smush smush.lexer ...` and the
    modules of std.normalize, std.functional and std.prototype that it
    uses, writes the same file that it is.

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
