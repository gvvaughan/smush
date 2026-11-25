---
layout: default
---
# CRUSH

The build and bootstrap scripts of
[standalone programs](smush.md#4-standalone-programs) are written in crush.
It's a tiny shell implemented entirely in under 1000 lines of source code in
`host/crush.c`.  It is not a subset of the standard POSIX shell, but the
syntax is simple and ought to be familiar, and it includes builtins for some
of the utilities that you can't rely on behaving uniformly across a variety
of supported machines: `echo` for example.  Additionally, you can 
[run a script](#8-running-a-script) written in the crush language using
`smush crush`.

Crush reads and checks the entirety of a script, before anything is actually
executed, so a script that crush cannot read changes nothing on the machine.
Its error messages give the line and the column.


## 1. Scripts

A script is lines of statements, separated by newlines or `;`.  A `#` that
starts a word begins a comment, which extends to the end of the line (`a#b`
is one word). A backslash at the end of a line continues it:

    # Compile the program.
    run cc -O2 -o $OUT main.c \
        lua/lapi.c lua/lauxlib.c

A line is either an assignment, which sets a local variable for the script, or
else a chain of statements joined by `||` which work just like Bourne shell.
Ever statement can be simple command or a block of commands optionally
prefixed by environment settings that apply only to the command (or block)
that follows and nothing else.  Many of the file redirections available in
Bourne shell can optionally be added at the end.  This is the grammar:

    script     = line { ( NEWLINE | ';' ) line }
    line       = assignment | chain
    chain      = statement { '||' statement }
    statement  = [ env ] ( block | command ) { redirect }
    block      = '{' script '}'
    command    = for | word { word }
    for        = 'for' NAME { NAME } 'in' word { word } block
    env        = assignment { assignment }
    assignment = NAME '=' [ word | '[' { word } ']' ]
    redirect   = [ DIGIT ] ( '>' | '>>' ) word
    word       = part { part }
    part       = text | '$' NAME | '...' | "...$NAME..."

Local assignments must each be on their own line, so `x=1 y=2` is a syntax
error (`x=1; y=2` is fine though), and so is an assignment on either side of
a `||` or followed by a redirection.

A NAME is made of letters, digits and underscores, but cannot start with a
digit.  Anything else that is not a valid assignment, but with an `=` in it
is a word, and so a command: `1a=2` tries to execute a program called `1a=2`.


## 2. Words and Variables

A value is a list of strings.  `a=x` sets a list of a single item `x`,
`a=[x y z]` assigns a list of three itmes, and `a=` assigns an empty list.
A list may run over several lines between its enclosing brackets.

`$a` is a reference to the list currently assigned to the local variable a,
but note that after `$a` is expanded, that word is *not* resplit.

Lists join together similarly to the "free caret" concept in rc.  A word with
a list in it expands to a word for each item in that list, so when `d=[a b]`,
`-I$d` expands to `-Ia -Ib`, and `lib/$d.lua` is `lib/a.lua lib/b.lua`.

A list with only one item is joined to every item of another, but lists of
the same length are joined in pairs, if `a=[p q]` and `b=[1 2]`, then `$a-$b`
is `p-1 q-2`.  An empty list makes the whole word disappear: with
`e=`, `before$e` is no word at all.  List pairings of other unequal lengths
are an error.

    a=[x y z]
    echo $a -I$a        # x y z -Ix -Iy -Iz

A variable that the script has not set is looked up in the environment, and
its value is split at blanks into a list, so with `CC='ccache cc'`, `$CC` is
a reference to a list of two words, and `$CFLAGS` is a word for each of the
flags in it.  Otherwise a reference to a variable that is not set locally or
found in the environment is treated as an empty list.

A local variable in the script is not exported to the environment of any
program that the script executes, unless it is [given to
them](#3-programs-and-their-environment).

Quotes also affect the expansion of variables:

  * inside `'...'` nothing is expanded at all, and the way to write a `'`
    in there is to end the quotes, write `"'"`, and begin them again;
  * inside `"..."` only `$name` is expanded, but a backslash escapes `"`, `$`,
    `\` and a newline.  A quoted `$name` is one string with the items of the
    list it contains joined by blanks. (a reference expanded from the
    environment it is not split though, so write `"$OUT/host"` for a path
    with an environment variable that may have a blank in it;
  * outside quotes a backslash makes the next character literal.

Only `$name` is a valid variable reference.  There is no `${name}`, and no
`$(...)` syntax.

There is no file globbing so words are never matched against the files that
are in the execution directory; `*` is a plain `*` not the name of every
file.


## 3. Programs and Their Environment

A command that is not a builtin is a program, search for in `$PATH`.  A
program that exits with a status other than 0 ends the entire script with
that same status, unless a `||` follows it:  `a || b` runs `b` only if `a`
fails, and a `||` chain ends the script only if its last command fails,
with that last command's exit status. A program that cannot be found exits
the script with 127.

    false || echo recovered      # goes on
    sh -c 'exit 4'               # ends the script, with 4

Assignments before a command, a block or a `for` are set in the environment of
every program that the statement runs, and then discarded.  Inner scopes
override outer scopes for what each command that runs (and none sets a local
script variable):

    X=1 Y=2 sh -c 'echo $X $Y'                      # 1 2
    X=1 { X=2 sh -c 'echo inner $X'; sh -c 'echo outer $X' }

The second writes `inner 2` and `outer 1`.

    X=0; X=1 echo "$X"                              # 0

Without single quotes, as here, crush expands $X first, to the local variable
not the environment variable set for the command.

Redirections are always at the end of a statement.  `>` writes a file, and
`>>` appends to one, from standard output, or from the descriptor that a
digit before it names:

    echo one > out.txt
    echo two >> out.txt
    sh -c 'echo err >&2' 2> err.txt

A block or a `for` count as statements too, so the redirection applies to
everything that runs in its scope.  There is no `<`, and no `2>&1`: use
`sh -c` for those if you need them.


## 4. Blocks and Loops

`{` and `}`, as words of their own, start and end a block, which is a
statement that has the status of the last command that ran in it, which may
be the first command that failed!  A block is not a scope to variables, which
are always global, and still set after the block ends.  The `;` to end a
command right before `}` is optional, so `{ run echo a; run echo b }` is legal
as one line.

`for NAME... in WORD... BLOCK` runs the block once for each NAME of the items
of the words, in order, with the names set to the next items.  With one name
it is a loop over a list.  With several, the list is read a row at a time:

    for f in a b c { run echo $f }

    rows=[a 1 b 2]
    for n v in $rows { echo $n is $v }       # a is 1, then b is 2

A list that does not fill its last row is an error, before the first pass.  A
list with no items runs nothing.  The names stay set to their last values even
after the end of the for loop.  A block or a `for` may be in a chain, where
`||` goes on after it if a command in it fails:

    for f in a b { sh -c 'exit 3' } || echo the body failed

Nothing may immediately follow the `}` except redirections, `;`, `||` or
another `}`.


## 5. Builtins

  * `cd [DIR]` changes directory, to `$HOME` without a DIR, for the rest of the
    script.  It ends the script with status 1 if it fails.
  * `echo [WORD...]` writes its words with a blank between each and a newline
    after, and has no options: `echo -n hi` writes `-n hi`.
  * `exit [N]` ends the script with status N, or with the status of the last
    command if N is not supplied.
  * `embed NAME FILE` writes C that defines the bytes of FILE, so that a
    C program can be compiled with the bytes from another file inside:

        const unsigned char NAME_data[] = "hello\n";
        const unsigned long NAME_size = 6;

  * `sha256 FILE...` writes the SHA-256 sum of each FILE, as `HASH  FILE`, the
    way `sha256sum` does. `sha256 -c HASH:FILE...` checks each FILE against
    its HASH, hashes of 64 hexadecimal digits in either case, and writes
    `FILE: OK` or `FILE: FAILED`.  It checks the rest after a file that fails,
    a file that it cannot read or a word that is not a HASH:FILE, and then
    fails, with status 1 with a count of the files that did not match.
  * `run COMMAND...` writes `% COMMAND...` to standard error, with the words
    expanded and quoted where they have blanks, and runs the program COMMAND,
    so that a build log shows what it did.  It only starts a program from
    `$PATH` and never a builtin, so `run cd` looks for a program called `cd`.

## 6. Status and Errors

A script ends with the status of the last command it executed:

  * the status of a program or of `exit` passes through unchanged, and 127 is a
    program that was not found;
  * 1 is a failure of crush itself, such as a script that it cannot read, a
    `cd` that cannot be executed, or a `sha256 -c` that did not check;
  * 2 is a command line that is wrong;
  * 3 is a syntax error in the script.

A script that has a syntax error fails before anything runs, with the name of
the script, and the line and the column:

    $ crush script
    script: 1:8: | is not in crush: use sh -c
    $ echo $?
    3


## 7. What Crush Leaves Out

Crush has no pipes (`|`), `&`, `<`, `( )`, backticks, `$(...)`, `${...}`, `$$`
or `$?`, and no `if`, `while`, `case` or functions.  A script that uses one is
refused, with its line and column, before it runs.  Whatever else is needed, a
script can synthesize from `sh -c`:

    run sh -c 'cd lua && ls *.c | wc -l'

That is the shell of the machine, so a script that uses it depends on that
machines shell, which is the entire purpose of using crush!  A build script
that needs more than crush provides is a sign that the work belongs in the
bootstrap script, which runs on the build machine, and not in the build script,
which runs where the program is built.


## 8. Running a Script

`smush crush SCRIPT` runs the crush script SCRIPT in the current directory,
and exits with the status of crush.  Crush is built from `host/crush.c` with
`$CC` the first time it is used, and the program is then chached in
`$XDG_CACHE_HOME/smush`, or `~/.cache/smush`, named for the text of `crush.c`
and for the system, so that no rerun builds it again, nor runs from a different
`crush` that is on the path.  If that directory cannot be written, crush is
built temporarily for each run.

A script can rely on `$TMPDIR`, which is `/tmp` if the caller has
none, for any temporary files that it makes and removes.

With `--first-run` smush makes an empty `barfz/` in the current directory
before running the script, and on successful completion writes a compressed barf
of the files that the script leaves below it to standard output, as
[Making a Payload](smush.md#42-making-a-payload) describes.

The build script of the standalone smush must be self contained.  It lists what
to compile, and `$CC`, `$CFLAGS`, `$LDFLAGS` and `$LIBS` come from the
environment that the first-run script sets up:

    lua_c=[
        lapi lauxlib lbaselib lcode ldblib ldebug ldo ldump lfunc lgc linit
        liolib llex lmathlib lmem loadlib lobject lopcodes loslib lparser
        lstate lstring lstrlib ltable ltablib ltm lundump lvm lzio
    ]

    run $CC $CFLAGS -DLUA_USE_POSIX -Ilua -o $OUT main.c data.c \
        lua/$lua_c.c $LDFLAGS $LIBS

The `lua/$lua_c.c` makes `lua/lapi.c lua/lauxlib.c` and the rest, one word for
each name in the list.


Report bugs at the [issue tracker][issues].


 [issues]:  https://github.com/gvvaughan/smush/issues
