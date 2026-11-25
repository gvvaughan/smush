---
layout: default
---
# SMUSH

[Smush] ships Lua code as one file, in either of two ways, for [LuaJIT] and
[Lua] 5.1 through 5.5:

 * a [bundle](#3-bundles) squeezes Lua modules, with their comments and white
   space taken out, into one Lua file, to run as a program or to load as a
   module.  It runs wherever there is a Lua
 * a [standalone program](#4-standalone-programs) is one file that carries
   its own Lua, and the C and Lua libraries it uses.  It builds itself the
   first time that it runs, on a machine that has a shell and a C compiler,
   and needs no Lua, no LuaRocks and no network

Both are made by the one [`smush` command](#2-command-line), and each has what
the other lacks:

|                           | bundle                  | standalone program            |
| ------------------------- | ----------------------- | ----------------------------- |
| needs on the machine      | Lua                     | a shell and a C compiler      |
| holds                     | Lua modules             | Lua modules, C, and a Lua     |
| C modules                 | [external](#33-external-modules) | built in, if the program has them |
| made by                   | `smush --main`          | `smush crush --first-run`, then `smush standalone` |
| first run                 | starts at once          | builds, then starts           |

A bundle is the way to ship a library or a tool to people who have Lua
already.  A standalone program is the way to ship a tool to people who may
not, such as a program that builds Lua code, which has to run before there is
a Lua to run it.

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

The [standalone smush](#46-smush-as-a-standalone-program) is made as any other
standalone program is, and has no need of Lua or LuaRocks at all.


## 2. Command Line

    smush --main=NAME SOURCE... > program
    smush --module=NAME SOURCE... > module.lua
    smush barf [--compress] [--index] FILE... > files.barf
    smush crush [--first-run] SCRIPT
    smush standalone NAME PAYLOAD > FILE
    smush bundled [NAME URL SUM]... > bundled.lua

Smush writes to standard output.  The first two forms write a
[bundle](#3-bundles).  The others are for [standalone
programs](#4-standalone-programs), though `barf` and `crush` are for any
program that needs an archive that a C compiler can unpack, or a build script
that a machine with a C compiler can run.

  * `--help` shows how to use smush, and exits;
  * `--version` shows which version of smush it is, and exits;
  * `--bundled` says which version of smush it is, and lists the rocks
    bundled in it, or the sources that a standalone smush was fetched
    from, one to a line, and exits (see
    [What is Bundled](#36-what-is-bundled) and
    [Smush as a Standalone Program](#46-smush-as-a-standalone-program)).

An option that takes a value is written `--NAME=VALUE` or `--NAME VALUE`.
Smush exits with an error for any option that it does not have.


## 3. Bundles

    smush --main=NAME SOURCE... > program
    smush --module=NAME SOURCE... > module.lua

With `--main=NAME` smush writes a script, which exits with the result of
calling the `main` function of the bundled module NAME with the arguments of
the command line.  With `--module=NAME` it writes a module, which returns the
bundled module NAME.  One of them is needed.

  * `--main=NAME` writes a script that exits with the result of calling the
    `main` function of the bundled module NAME;
  * `--module=NAME` writes a module that returns the bundled module NAME;
  * `--external=NAME` names a module that the host provides to the
    bundle (see [External Modules](#33-external-modules));
  * `--readable` keeps the lines and the indentation of each SOURCE, and
    takes out only its comments, its blank lines and the white space that
    is not needed, so that the bundle can be read.


### 3.1. Sources

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


### 3.2. The Environment of a Bundle

The modules of a bundle run in an environment of their own, with copies of
the globals, and a `require` and a `package.loaded` of their own, so:

  * a bundled module never finds a module of the same name that the host
    has loaded, nor does it see the host's `package.path` or
    `package.loaded`, except for the modules that are
    [external](#33-external-modules);
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


### 3.3. External Modules

A module that has a C part, such as `lpeg` or `yaml`, can't be bundled, so
bundle the Lua modules that use it, and say that the host provides it:

    smush --main=app --external=lpeg lib/app.lua > app

The bundle asks the host's own `require` for an external module the first
time that it needs it, so the host need not have loaded it already.  The
module is then the host's, and is shared with it.  `--external=package`
gives the bundle the host's real `package`, which a program that sets
search paths for code that it runs, as a test runner does, needs.

A program that has to carry its C modules too is a [standalone
program](#4-standalone-programs), which links them in.


### 3.4. Warnings

Smush warns of a module in the Lua path that a bundled module names, but
that is not bundled, when it is neither external nor only asked for with
`pcall(require, 'name')`, because a bundle that needs it would fail when it
ran, and says which bundled module names it:

    smush: warning: four names the module 'three', which is in the Lua path, but is not bundled

A module that is part of a bundled module, such as `optparse._strict` of
`optparse`, is warned of too, if it is in the Lua path and not bundled, so
that a library that has gained a file is not bundled without it.


### 3.5. Rockspecs

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


### 3.6. What is Bundled

Every bundle has a module `smush.bundled`, which smush writes into it, with
a function `showbundled`.  It writes the version of the smush that bundled
it, and then each rock that the modules in the bundle are from, as LuaRocks
has them installed, with its version, one to a line:

    smush 0.4 bundled:
    std.functional 2.1-1
    std.normalize 5.0.1-1
    std.prototype 2.1-1

Smush finds the rock of a module in the manifest of the LuaRocks tree that
has its file, so it needs no LuaRocks itself.  A module that no rock has,
such as a file of the project that is bundled, or a checkout in the Lua
path, is not listed.  `showbundled` writes with `io.write`, or with a
function that it is given: `showbundled(write)`.  A standalone program has
no bundle, and lists the URLs it was fetched from instead (see [Making a
Payload](#42-making-a-payload)).

A program calls it from its own `--bundled` option, so that the help and
the man page of the program have the option, and says that it is not
bundled when it cannot `require` the module, as it cannot when it is run
from a source tree:

{% highlight lua %}
local ok, bundled = pcall(require, 'smush.bundled')
if ok then
   bundled.showbundled()
else
   io.stderr:write 'not a bundled program!\n'
end
{% endhighlight %}

[Luke] and [Specl] do, as does `smush --bundled`.  A source of the bundle
that is called `smush.bundled` is bundled as it is, and smush writes no
module of that name.


## 4. Standalone Programs

A standalone program is for a tool that has to run on a machine that has no
Lua, or no Lua that is the one that the tool needs.  It is one file, which
holds the sources that the program is built from, and a script that builds
them.  What is built is the program of the machine that it is built on, so
nothing about the machine, except that it has a shell and a C compiler, is
assumed when the file is made.

There are three steps:

  1. a build script, that makes the program from its sources on the machine
     that runs it, and a bootstrap script, that gathers those sources on the
     machine of the author, are written in [crush](#41-build-scripts), a small
     language that a C compiler is all it takes to run;
  2. `smush crush --first-run` runs the bootstrap script, and writes a
     [payload](#42-making-a-payload), the files that it leaves behind, packed;
  3. `smush standalone` writes the [program](#43-assembling-the-program), as
     one file, from the payload.


### 4.1. Build Scripts

A build script is written in crush, which is `host/crush.c`, about fourteen
hundred lines of C99.  It is a build tool for a machine that has a compiler and little
else: it has no dependencies, and `cc -o crush crush.c` builds it.  The
language is a small subset of the shell, which is easy to read for anyone who
knows one, with a few things that it does itself, so that no script needs a
`curl` or a `sha256sum` that a machine may not have:

    # A name, where to fetch it from, and its sum.
    dependencies=[
        lua  https://www.lua.org/ftp/lua-5.1.5.tar.gz  2640fc56a795...
    ]

    for name url sum in $dependencies {
        run curl -fsSL -o $name.tar.gz $url
        sha256 -c $sum:$name.tar.gz
        run mkdir $name
        run tar -xzf $name.tar.gz -C $name --strip-components=1
    }

    run cc -O2 -o $OUT main.c lua/lapi.c lua/lauxlib.c

A script is lines of commands, with `||` to go on if a command fails, `{ }`
to group commands, `NAME=VALUE` to set a variable of the script, which holds a
list of words, and `NAME=VALUE command` to set one in the environment of a
command.  A `for` runs a block once for each word of a list, or for each row
of one that has several words to a row.  A command that fails ends the
script, with its status, unless a `||` follows it.  The builtins are `cd`,
`exit`, `run`, which writes the command that it runs to standard error as it
runs it, `sha256`, which writes the SHA-256 sum of files, or with `-c` checks
them, and `embed`, which writes the bytes of a file as C, so that a program
can hold a file in itself.  `echo` is a builtin too, which writes its words
with a blank between each and a newline after, and has no options, so that a
script does not depend on the `echo` that a machine has.  `host/crush.c` has
the grammar, and the rest of the rules, at its head.

`smush crush SCRIPT` runs the crush script SCRIPT in the current directory,
and exits with the status of crush.  Crush is built from `host/crush.c` with
`$CC` the first time, and the program is kept in `$XDG_CACHE_HOME/smush`, or
`~/.cache/smush`, named for the text of `crush.c` and for the system, so that
no run builds it again, or runs a different `crush` that is on the path.
A script can rely on `$TMPDIR`, which is `/tmp` if the caller has none, for
the files that it makes and removes.


### 4.2. Making a Payload

The payload is a compressed barf of what the program is built from.  A barf is
an archive that `host/barfx.c` unpacks with nothing but a C compiler to build
it.  `smush barf [--compress] [--index] FILE... > files.barf` writes the files
as a barf, under the paths that are given.  `--compress` compresses the barf
with LZ4, and `--index` keeps the paths in an index, with the entries
numbered.

Each name is a path from the current directory, and the barf stores it just as
it is written.  `-C DIR` changes to DIR to find the names after it, but the
barf stores them with the relative path as given on the command line, without
DIR.  A `-C` applies to the names after it, up to the next `-C`, and its DIR
is always from the current directory.  A directory includes all the files
below it, in sorted order.  For example:

    smush barf --index -C lib smush/init.lua -C other/lib std/x/init.lua

reads `lib/smush/init.lua` and `other/lib/std/x/init.lua`, and stores them as
`smush/init.lua` and `std/x/init.lua`.

A program that lists what it is made from with `--bundled`, as a bundle does
(see [What is Bundled](#36-what-is-bundled)), carries a module
`smush.bundled`.  `smush bundled [NAME URL SUM]... > bundled.lua` writes it
from the rows that a bootstrap script fetches from, which is why it takes a
NAME and a SUM that it does not write.  Its `showbundled` writes the version
of smush, and then the URL of each source, one to a line, after `fetched:`
where a bundle has `bundled:`:

    smush 0.5 fetched:
    https://www.lua.org/ftp/lua-5.1.5.tar.gz
    https://github.com/lua-stdlib/normalize/archive/refs/tags/v5.1.tar.gz

Pack the file with the others, as `smush/bundled.lua`, so that the program
finds it with `require 'smush.bundled'`.

`smush crush --first-run SCRIPT > payload.barf` makes an empty `barfz` in the
current directory, and runs the script, the bootstrap script.  What the script
writes to its standard output goes to standard error.  Smush writes a
compressed barf of the files that the script leaves below `barfz`, removes
`barfz`, and exits with an error if the script fails, or if there is a `barfz`
already, which it leaves as it is.

The bootstrap script is the author's, and runs where the author is, in the
current directory, which holds the sources and whatever else it needs.  It is
free to use `curl` or `wget`, and `tar`, and to put things where it likes, so
it:

  * fetches what the program depends on, and checks each against a sum that
    is written in the script, with `sha256 -c`, so that a payload is made of
    exactly the sources that the author looked at;
  * copies into `barfz/` what the program is built from, which is a `build`
    script, in crush, `crush.c` and `barfx.c` so that the first run need not
    fetch them, and everything that `build` compiles or reads;
  * removes whatever it fetched or made that is not in `barfz`.  The script is
    the only one that knows what it left, so it cleans up after itself.

The bootstrap and build scripts of smush itself, in
`build-aux/standalone-5.1/`, are an example.  The bootstrap runs in the root
of the source, and takes the version of smush from the `lib/smush/version.lua`
that building smush makes, so build smush first.  It fetches Lua 5.1.5, and
the std modules that smush needs, into a work directory in `$TMPDIR`, which it
removes when it is done.  It moves the Lua sources into `barfz/`, and copies
`host/main.c` and the build script there.  It packs the Lua files of smush
and of the modules with `smush barf --index -C`, which gives them the paths
that `require` looks for them by, and a `smush/bundled.lua` that `smush
bundled` writes for `--bundled`, and makes that into the C of `barfz/data.c`
with `embed`.  The build script is one command, that compiles all of those
with `$CC`.


### 4.3. Assembling the Program

    smush crush --first-run build-aux/standalone-5.1/bootstrap > payload.barf
    smush standalone smush payload.barf > smush-0.5.sh
    chmod +x smush-0.5.sh

`smush standalone NAME PAYLOAD > FILE` writes the program called NAME to FILE,
which is `host/stub.sh.in`, a shell script, with `@NAME@` filled in with NAME,
`@ID@` with the checksum of the payload, as `cksum` writes it, and `@BARFX_C@`
with `host/barfx.c` with its comments and white space squeezed out, followed by
the payload.  NAME is what the program calls itself, in its messages and in
the name of its cache directory, so it has to be safe in a file name.  FILE is
only where the program is kept, and may be called anything, such as the
version of the release.  FILE is a program once `chmod +x` has made it
executable.  Nothing is built until it runs.


### 4.4. The First Run

The first time a standalone program runs, on a machine, it:

  1. compiles `barfx`, from the C in the file, and unpacks the payload with
     it into a directory of `$TMPDIR`;
  2. compiles `crush.c` from the payload;
  3. runs `build` from the payload with crush, in the directory that the
     payload was unpacked in, with these in the environment:

     * `CC`, the C compiler, `cc` if unset;
     * `CFLAGS`, `-O2` if unset;
     * `LDFLAGS`;
     * `LIBS`, `-lm` if unset, for the math library that Lua needs.  The
       build script uses only what is in `LIBS`, so a machine that needs more,
       or less, sets it, to nothing if it has the math library already;
     * `OUT`, the file that `build` has to make;

  4. keeps the file `OUT` in `$XDG_CACHE_HOME/NAME/ID-SYSTEM-MACHINE/NAME`,
     or under `~/.cache` if `XDG_CACHE_HOME` is not set, and starts it with the
     arguments that it was given.

The first run reports that it is building, on standard error, and a build that
fails keeps nothing, so the next run builds again.  The ID makes the directory
of a new version of the program another one, and the system and machine keep
the programs of machines that share a home directory apart.  Every later run
starts the kept program, and nothing else.


### 4.5. The Program

`build-aux/standalone-5.1/build` of smush shows what a build script makes: a
program from `host/main.c`, which is linked with Lua, and the `data.c` that
`embed` wrote.  `data.c` holds `runtime_data` and `runtime_size`, the bytes of
an indexed barf of the Lua files of the program, and `main.c` is all of the C
that is the same for every program.  The program:

  * runs `main.lua` from the barf, with its arguments, and with them in the
    table `arg`;
  * finds a module with `require` in the barf, and nowhere else, so that a
    module that is not in the program is an error, and is never one that
    happens to be on the machine.  It is compiled when it is first required,
    so a program starts as fast as the modules that it needs allow;
  * builds with LuaJIT or Lua 5.1 through 5.5, whichever the build links it
    with, and runs the Lua of the program in that.

A program with C modules compiles `main.c` with `-DHOST_MODULES`, and links a
file that defines `host_modules`, a list of `luaL_Reg` ended by `{NULL, NULL}`.
`require` finds those by name before the barf.

The module `smush.payload` is always there, and its `read(path)` gives the
bytes of the file `path` of the barf, or nil.  It is for a program that has
files that are not Lua, such as the sources of the program that it builds.
The name is the host's, so that it is never the name of a module of the
program.


### 4.6. Smush as a Standalone Program

`smush` is itself a standalone program, made by the bootstrap and the build of
`build-aux/standalone-5.1/`, so that there is a smush where there is no Lua,
and no LuaRocks.  Its runtime is `lib/smush/*.lua`, the std modules, and the
host files `crush.c`, `barfx.c` and `stub.sh.in`.  A standalone smush reads
those three from its own payload, with `smush.payload`, and not from a `host`
directory next to a `bin` directory, which a standalone smush does not have.
So `smush crush` and `smush standalone` work in a program that is not in a
clone or a rock, and a standalone smush makes other standalone programs.  It
reads them only there, so what it makes is of the release that it is, and
never of one that is on the machine.

Its Lua is 5.1.5.  `build-aux/standalone-X.Y/` has a bootstrap and a build for
each release of Lua that smush supports, 5.1 to 5.5, which are the same except
for the sources that the first run builds the program from, and the list of
the files of them, so that CI can make a standalone smush with each.  LuaJIT
is built with `make`, and has none.


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
