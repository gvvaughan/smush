--[[
 Smush the source, Luke!
 Copyright (C) 2017-2026 Gary V. Vaughan
]]
--[[--
 Bundle Lua modules into a single file.

 `smush` writes one file that holds every module that it is given, with
 their comments and white space squeezed out, to be run as a program or
 loaded as a module.  The bundled modules run in an environment of their
 own, so they cannot see the modules of the host they are loaded in, or
 leave any behind.

 @module smush
]]


local Lexer = require 'smush.lexer'.prototype
local barf = require 'smush.barf'
local cminify = require 'smush.c'.minify
local host = require 'smush.host'
local minify = require 'smush.minify'
local _context = require 'std.prototype.contextmanager'
local _std = require 'std.functional.init'

local _ENV = require 'std.normalize' {
   'io.open',
   'io.popen',
   'io.stderr',
   'io.write',
   'math.floor',
   'os.execute',
   'os.exit',
   'os.getenv',
   'package',
   'package.searchpath',
   'string.find',
   'string.format',
   'string.gsub',
   'string.match',
   'string.sub',
   'table.concat',
   'table.sort',
   File = _context.File,
   choose = _std.choose,
   cond = _std.cond,
   slurp = _context.slurp,
   each = _std.each,
   keys = _std.keys,
   map = _std.map,
   memoize = _std.memoize,
   reject = _std.reject,
   sorted = _std.sorted,
}


-- A module name from the path of the file that holds it.
local function modname(fname)
   return (gsub(fname, '/', '.'):gsub('lib%.', ''):gsub('%.lua$', ''):gsub('%.init$', ''))
end


-- The file for an argument that is a module name rather than a path: find
-- it in the Lua path, as `require` would.
local function modfile(name)
   local fname, err = searchpath(name, package.path)
   if fname == nil then
      stderr:write('smush: module ', name, ' not found:', err, '\n')
      exit(1)
   end
   return fname
end


-- Each source is a path, which is bundled under the module name that
-- its path makes, or NAME=PATH, which is bundled as NAME, or else the name
-- of a module to find in the Lua path, which is bundled under that name.
-- (ALIAS::MODULE is not one: main sets those aside.)
local function source(arg)
   local name, fname = match(arg, '^([%w_.%-]+)=(.+)$')
   if name ~= nil then
      return name, fname
   elseif find(arg, '/', 1, true) or find(arg, '%.lua') then
      return modname(arg), arg
   end
   return arg, modfile(arg)
end


-- The libraries that every supported Lua has, Lua 5.1 to 5.5 and LuaJIT, and
-- `require` finds in `package.loaded`.  A bundle's own `package.loaded` has
-- them, as the host's does, unless the host is to provide one, with
-- `--external`.  Any other, such as `utf8`, which is in Lua 5.3 and later,
-- or `ffi`, which is in LuaJIT, ties the code that needs it to the Lua that
-- has it, so the bundle names it with `--external`, to say that it does.
local STANDARD = {'coroutine', 'debug', 'io', 'math', 'os', 'string', 'table'}


-- The version of this smush, if it has one, to say which one wrote a bundle.
local function smush_version()
   local ok, version = pcall(require, 'smush.version')
   return ok and version.VERSION or nil
end


-- The script or module that smush writes, runs bundled packages in a private
-- environment with a copy of the globals, and a custom `require` and
-- `package.loaded` so that nothing leaks into the host's `package` module.
local function header(script, externals)
   local version = smush_version()
   local smushed = version and ('smush ' .. version .. ': ') or ''
   local provided = {}
   each(externals, function(name) provided[name] = true end)
   local function seed(names, value)
      return concat(map(reject(names, function(name) return provided[name] end), function(name)
         return format(' loaded.%s=%s', name, value or 'host.loaded.' .. name)
      end))
   end

   return (script and '#!/usr/bin/env lua\n' or '') .. concat({
      '--[[ ' .. smushed .. 'minified code follows, see --help text for source location! ]]',
      'local host,hostrequire=package,require',
      'local env={}for k,v in next,_G do env[k]=v end env._G=env',
      'local bundled,loaded={},{}' .. concat(map(externals, function(name)
         return format(' bundled[%q]=function(n)local m=host.loaded[n]if m==nil then m=hostrequire(n)end return m end', name)
      end)) .. seed(STANDARD) .. seed({'_G'}, 'env'),
      'env.package=setmetatable({preload=bundled,loaded=loaded},{__index=host})' .. seed({'package'}, 'env.package'),
      'local require=function(modname)local m=loaded[modname]if m==nil then',
      'if bundled[modname]==nil then',
      [=[error("module '" .. modname .. "' not found:\n   no bundled module '" .. modname .. "'",2)]=],
      'end',
      'm=bundled[modname](modname)if m==nil then m=true end loaded[modname]=m end',
      'return m end',
      'env.require=require',
      'local _ENV=env',
   }, '\n')
end


-- What follows the bundled modules: run them in their environment.
local function footer(script, entry)
   return concat({
      "if _VERSION=='Lua 5.1'then for _,f in next,bundled do setfenv(f,env)end end",
      script and "os.exit(require'" .. entry .. "'.main(arg))"
              or "return require'" .. entry .. "'",
   }, '\n')
end

-- All of the tokens of the file *fname*, read once.
local tokenize = memoize(function(fname)
   local text, err = slurp(File(fname))
   if text == nil then
      stderr:write('smush: ', err, '\n')
      exit(1)
   end
   local ok, tokens = pcall(function()
      return Lexer(text, fname):tokens()
   end)
   if not ok then
      stderr:write('smush: ', tokens, '\n')
      exit(1)
   end
   return tokens
end)


-- The tokens of the file *fname* that matter to the program, without its
-- comments and whitespace, made once.
local significant = memoize(function(fname)
   return reject(tokenize(fname), minify.trivia)
end)

-- Whether two tokens need a space between them, and the separators that put
-- the tokens of a source in a bundle: compact, or readable.
local needspace = minify.needspace(Lexer)
local separators = {[false] = minify.compact, [true] = minify.readable}


-- The manifests of LuaRocks trees that rockof has read, by file.
local manifests = {}

-- The rock, and its version, that LuaRocks installed the file *fname* of
-- a module from, as `rock version`, or nothing if it is not in a tree of
-- LuaRocks, or none says that it has it.  A tree lists the files of every
-- rock in its manifest, so there is no need for LuaRocks itself.
local function rockof(fname)
   local root, luaver, file = match(fname, '^(.*)/share/lua/([%d.]+)/(.+)%.lua$')
   if root == nil then
      return nil
   end
   local path = root .. '/lib/luarocks/rocks-' .. luaver .. '/manifest'
   if manifests[path] == nil then
      local text = slurp(File(path))
      local manifest = {}
      local chunk = text and load(text, '=' .. path, 't', manifest)
      manifests[path] = chunk ~= nil and pcall(chunk) and manifest or false
   end
   local manifest = manifests[path]
   local providers = manifest and (manifest.modules or {})[(gsub(file, '/', '.'))]
   local rock, version = match(providers and providers[1] or '', '^([^/]*)/(.+)$')
   if rock ~= nil then
      return rock .. ' ' .. version
   end
end


-- The module that a bundle has for what it says with `--bundled`: the
-- version of this smush, which bundled it, and the rocks that its modules
-- come from, as the program that it is has them, for it to call from its
-- own `--bundled` option, so that the help and man page of the program
-- have the option.  Its `showbundled` writes with `io.write`, or with the
-- function that it is given.  *rocks* is a list of `rock version`.
local function bundled_module(rocks)
   local version = smush_version()
   local text = 'smush ' .. (version and (version .. ' ') or '') .. 'bundled:\n' ..
      concat(map(rocks, function(rock) return rock .. '\n' end))
   return "bundled['smush.bundled']=function()return{showbundled=function(write)(write or io.write)(" ..
      format('%q', text) .. ')end}end'
end


-- The modules that are in the Lua path and not bundled, but which a
-- string in *tokens* names.  A string such as 'std.functional._base.argscheck'
-- could be the module std.functional._base, or std.functional or std, so look
-- for the longest bundled match and in the Lua path.  Otherwise that module is
-- not bundled, even if a module it was part of was bundled.
local function unbundled(tokens, known)
   local r = {}
   for i = 1, len(tokens) do
      local token = tokens[i]
      local name = token[1] == 'STRING' and match(token[2], '^["\']([%w_][%w_.%-]*[%w_])["\']$')
      local optional = i > 2 and tokens[i - 1][2] == ',' and tokens[i - 2][2] == 'require'
      if name and not optional then
         while name ~= nil and not known[name] do
            if searchpath(name, package.path) then
               r[name] = true
               break
            end
            name = match(name, '^(.+)%.[^.]*$')
         end
      end
   end
   return keys(r)
end


-- The options that take a value, as `--NAME=VALUE` or `--NAME VALUE`.
local OPTIONS = {main = true, module = true, external = true}


local USAGE = [[
Usage: smush [OPTION]... SOURCE...
       smush barf [OPTION]... FILE...
       smush crush [--first-run] SCRIPT
       smush standalone NAME PAYLOAD

Write a single file that bundles each SOURCE, to standard output.  A SOURCE
is the path of a module, which is bundled under the name that its path makes,
NAME=PATH, which is bundled as NAME, or the name of a module to find in the
Lua path, which is bundled under that name.  An option that takes a value
is written `--NAME=VALUE` or `--NAME VALUE`.  ALIAS::MODULE makes the module
ALIAS the bundled MODULE, and not a copy of it, so that libraries which each
have a copy of one file share the one.

  --main=NAME      write a script that exits with the result of calling the
                   `main` function of the bundled module NAME
  --module=NAME    write a module that returns the bundled module NAME
  --external=NAME  the host provides the module NAME to the bundle, which
                   asks the host's `require` for it when it needs it
  --readable       keep the lines and the indentation of each SOURCE, taking
                   out only comments, blank lines and wasted white space
  --help           show this help, and exit
  --version        show the version, and exit
  --bundled        list the rocks bundled in smush, and exit

`smush barf --help` shows how to write a barf of files, and not a bundle.
`smush crush --help` shows how to run a crush script, and not write a bundle.
`smush standalone --help` shows how to write a standalone program.
]]


local BARF_USAGE = [[
Usage: smush barf [OPTION]... FILE...

Write a barf of each FILE, to standard output, under the path that is
given for it.  A directory includes all the files below it.

  -C DIR      change to DIR to find the FILEs after it, but store them
              with the relative path as given on the command line.  It
              lasts until the next -C, and DIR is always from the
              current directory
  --compress  compress the barf with LZ4
  --index     keep the paths in an index, and number the entries
  --help      show this help, and exit
]]


local CRUSH_USAGE = [[
Usage: smush crush [OPTION]... SCRIPT

Run the crush script SCRIPT in the current directory, and exit with the
status of crush.  Crush is built from host/crush.c once, and kept in
$XDG_CACHE_HOME/smush, or ~/.cache/smush, for every later run.

  --first-run  make an empty directory barfz in the current directory
               before SCRIPT runs, and write a compressed barf of the
               files that it leaves below barfz to standard output, and
               remove barfz.  What the script writes to its standard
               output goes to standard error
  --help       show this help, and exit
]]


local STANDALONE_USAGE = [[
Usage: smush standalone NAME PAYLOAD

Write the standalone program called NAME to standard output, for a redirection
to put in a file of any name: the script that builds the program on its first
run (host/stub.sh.in) with the minified host/barfx.c in it, followed by the
file PAYLOAD, which `smush crush --first-run` writes.  NAME is what the program
calls itself, and what the directory that it is kept in is named for.  The
program keeps what it builds in the cache of the user, in a directory that has
the checksum of PAYLOAD in its name, and starts that program on every run after
the first.
The file is not executable until chmod makes it so.

  --help  show this help, and exit
]]


-- *s* quoted for a shell.
local function quoted(s)
   return "'" .. gsub(s, "'", "'\\''") .. "'"
end


-- Whether what os.execute returned is success, in any Lua version.
local function succeeded(ok)
   return ok == true or ok == 0
end


-- The first line that the shell command *command* writes.
local function line_of(command)
   local pipe = popen(command)
   local line = pipe:read '*l'
   pipe:close()
   return line
end


-- The exit status that the results of os.execute are, in any Lua version:
-- *ok*, *how* and *code* in Lua 5.2 and later, or the wait status in 5.1,
-- which has the signal that ended the program in its low bits, if there was
-- one, and the exit status above them.
local function exit_code(ok, how, code)
   return cond(
      {ok == true, 0},
      {how == 'exit', code},
      {how == 'signal', function() return 128 + code end},
      {type(ok) == 'number' and ok % 128 ~= 0,
       function() return 128 + ok % 128 end},
      {type(ok) == 'number', function() return floor(ok / 256) end},
      {true, 1}
   )
end


-- The relative paths of the files below the directory *dir*, sorted.
local function files_below(dir)
   local pipe = popen('cd ' .. quoted(dir) ..
      " && find . -type f | LC_ALL=C sort")
   local paths = {}
   for p in pipe:lines() do
      paths[#paths + 1] = sub(p, 3)
   end
   pipe:close()
   return paths
end


-- Write a barf of the files in *args*, to standard output.  A directory
-- includes all the files below it, and `-C DIR` changes to DIR to find
-- the names after it, but stores them as they were given.
local function barf_main(args)
   local opts, entries = {}, {}
   local base, taking
   local function fail(...)
      stderr:write('smush barf: ', ...)
      stderr:write '\n'
      exit(1)
   end
   local function add(name, path)
      local data, err = slurp(File(path))
      if data == nil then
         fail(err)
      end
      entries[#entries + 1] = {path = name, data = data}
   end
   each(args, function(a)
      if taking then
         base, taking = a, nil
      elseif a == '-C' then
         taking = true
      elseif a == '--compress' or a == '--index' then
         opts[sub(a, 3)] = true
      elseif a == '--help' then
         write(BARF_USAGE)
         exit(0)
      elseif sub(a, 1, 1) == '-' then
         stderr:write("smush barf: unrecognized option '", a, "'\n",
            BARF_USAGE)
         exit(1)
      else
         local name = gsub(a, '/+$', '')
         local path = base and base .. '/' .. name or name
         if succeeded(execute('test -d ' .. quoted(path))) then
            each(files_below(path), function(p)
               add(name .. '/' .. p, path .. '/' .. p)
            end)
         else
            add(name, path)
         end
      end
   end)
   if taking then
      fail 'the option -C needs a directory'
   end
   local ok, bytes = pcall(barf.pack, entries, opts)
   if not ok then
      fail(bytes)
   end
   write(bytes)
end


-- The directory that the programs that smush builds are kept in, so that
-- each is built once, or nil if there is no absolute path for it.
local function cache_dir()
   local xdg, home = getenv 'XDG_CACHE_HOME', getenv 'HOME'
   if xdg and sub(xdg, 1, 1) == '/' then
      return xdg .. '/smush'
   elseif home and sub(home, 1, 1) == '/' then
      return home .. '/.cache/smush'
   end
end


-- A name for the program built from the file *source*, that is the same for
-- the same text on the same system and kind of machine.  It is made of the
-- `cksum` of the text, which is in every POSIX system, and the names that
-- `uname` gives, and is nil if there is none.
local function crush_key(source)
   local crc, size = match(line_of('cksum < ' .. quoted(source)) or '',
                           '^(%d+) (%d+)')
   local system, machine = line_of 'uname -s', line_of 'uname -m'
   if crc and system and machine then
      return (gsub(format('%s-%s-%s-%s', crc, size, system, machine),
                   '[^%w_.-]', '_'))
   end
end


-- Compile the file *source* into the program *out*, and whether it worked.
local function compile_crush(source, out)
   return succeeded(execute(format(
      '${CC:-cc} ${CFLAGS} ${CPPFLAGS} -D_XOPEN_SOURCE=700 -o %s %s',
      quoted(out), quoted(source))))
end


-- The path of a crush built from the file *source*, or nil if it cannot be
-- built.  It is built once and kept in the cache, where every later run
-- finds it by its path, so that a program called crush that is somewhere
-- else is never run in its place.  If it cannot be kept there, it is built
-- in the directory *dir*, and goes when that does.
local function crush_program(source, dir)
   local cache, key = cache_dir(), crush_key(source)
   local kept, tmp
   if cache and key then
      kept = cache .. '/crush-' .. key
      local found = open(kept)
      if found then
         found:close()
         return kept
      end
      if succeeded(execute('mkdir -p ' .. quoted(cache) .. ' 2>/dev/null')) then
         tmp = line_of('mktemp ' .. quoted(cache .. '/crush.XXXXXX'))
      end
   end
   if tmp then
      stderr:write('smush crush: building crush, once, in ', cache, '\n')
      local built = compile_crush(source, tmp)
      -- Rename it into place, so that a run that starts while another
      -- finishes finds the whole program, or none of it.
      if built and succeeded(execute(format('chmod 755 %s && mv -f %s %s',
                                            quoted(tmp), quoted(tmp),
                                            quoted(kept)))) then
         return kept
      end
      execute('rm -f ' .. quoted(tmp))
      if not built then
         return nil
      end
   end
   if compile_crush(source, dir .. '/crush') then
      return dir .. '/crush'
   end
end


-- Run the crush script in *args* with the crush that is built from the
-- host files, which are next to the bin directory of *script*, the path of
-- the running script.  With --first-run, make a barfz in the current
-- directory first, and write a barf of what the script leaves in it, and
-- remove it.
local function crush_main(args, script)
   local first_run, name
   each(args, function(a)
      if a == '--first-run' then
         first_run = true
      elseif a == '--help' then
         write(CRUSH_USAGE)
         exit(0)
      elseif sub(a, 1, 1) == '-' or name then
         stderr:write("smush crush: unrecognized argument '", a, "'\n",
            CRUSH_USAGE)
         exit(1)
      else
         name = a
      end
   end)
   if not name then
      stderr:write('smush crush: give a SCRIPT\n', CRUSH_USAGE)
      exit(1)
   end
   local crush_c = host.read('crush.c', script)
   if not crush_c then
      stderr:write('smush crush: no host/crush.c next to the bin directory of ',
                   tostring(script), '\n')
      exit(1)
   end

   local dir = line_of 'mktemp -d'
   local made_barfz
   local function finish()
      execute('rm -rf ' .. quoted(dir))
      if made_barfz then
         execute 'rm -rf barfz'
      end
   end
   local function stop(message)
      stderr:write('smush crush: ', message, '\n')
      finish()
      exit(1)
   end

   local source = dir .. '/crush.c'
   local handle = open(source, 'wb')
   if not handle or not handle:write(crush_c) or not handle:close() then
      stop('cannot write ' .. source)
   end
   local crush = crush_program(source, dir)
   if not crush then
      stop 'cannot build crush'
   end
   if not first_run then
      local ok, how, code = execute(format('%s %s', quoted(crush),
                                           quoted(name)))
      finish()
      exit(exit_code(ok, how, code))
   end

   if not succeeded(execute 'mkdir barfz 2>/dev/null') then
      stop 'cannot make barfz, which may be there already'
   end
   made_barfz = true
   if not succeeded(execute(format('%s %s >&2', quoted(crush),
                                   quoted(name)))) then
      stop('the script ' .. name .. ' failed')
   end

   local entries = {}
   for i, p in ipairs(files_below 'barfz') do
      local data, err = slurp(File('barfz/' .. p))
      if data == nil then
         stop(err)
      end
      entries[i] = {path = p, data = data}
   end
   local ok, bytes = pcall(barf.pack, entries, {compress = true})
   if not ok then
      stop(bytes)
   end
   finish()
   write(bytes)
end


-- Write the standalone program *name*, with the payload that is in the file
-- *payload*, to standard output.  Its stub and the C that unpacks the
-- payload are the host files next to the bin directory of *script*, the path
-- of the running script.
local function standalone_main(args, script)
   local words = {}
   each(args, function(a)
      if a == '--help' then
         write(STANDALONE_USAGE)
         exit(0)
      elseif sub(a, 1, 1) == '-' then
         stderr:write("smush standalone: unrecognized option '", a, "'\n",
            STANDALONE_USAGE)
         exit(1)
      end
      words[#words + 1] = a
   end)
   local name, payload = unpack(words)
   local function stop(message)
      stderr:write('smush standalone: ', message, '\n')
      exit(1)
   end
   if #words ~= 2 then
      stderr:write('smush standalone: give a NAME and a PAYLOAD\n',
         STANDALONE_USAGE)
      exit(1)
   end
   if not match(name, '^[%w_][%w_.-]*$') then
      stop('the NAME ' .. name .. ' is not a name for a program and a directory')
   end

   local texts = {}
   for _, file in ipairs {'stub.sh.in', 'barfx.c'} do
      texts[file] = host.read(file, script)
      if not texts[file] then
         stop('no host/' .. file .. ' next to the bin directory of ' ..
              tostring(script))
      end
   end
   local bytes, err = slurp(File(payload))
   if bytes == nil then
      stop(err)
   end
   local crc, size = match(line_of('cksum < ' .. quoted(payload)) or '',
                           '^(%d+) (%d+)')
   if not crc then
      stop('cannot find the checksum of ' .. payload)
   end

   write((gsub(texts['stub.sh.in'], '@(%u[%u_]*)@', {
      NAME = name,
      ID = crc .. '-' .. size,
      BARFX_C = gsub(cminify(texts['barfx.c'], {name = 'barfx.c'}), '\n$', ''),
   })), bytes)
end


--- Write a single file that bundles *sources*.
-- A source is a path, NAME=PATH, or the name of a module in the Lua path.
-- With `--module=NAME` the file is a module that returns the bundled
-- module NAME, and with `--main=NAME` it is a script that exits with what
-- the main function of the bundled module NAME returns.
-- Warn of a module in the Lua path that a bundled module names, but is not
-- bundled, unless it is an `--external=NAME` that the host is to provide.
-- A source `ALIAS::MODULE` makes the module ALIAS the bundled MODULE, and
-- there is no other source for it.
local function main(args)
   if args[1] == 'barf' then
      return barf_main({unpack(args, 2)})
   end
   if args[1] == 'crush' then
      return crush_main({unpack(args, 2)}, args[0])
   end
   if args[1] == 'standalone' then
      return standalone_main({unpack(args, 2)}, args[0])
   end
   local script, entry, sources, known, externals = true, nil, {}, {}, {}
   local aliases = {}
   local readable = false
   local i = 1
   while i <= len(args) do
      local a = args[i]
      local k, v = match(a, '^%-%-(%w+)=(.*)$')
      if k == nil then
         k = match(a, '^%-%-(%w+)$')
         if OPTIONS[k] then
            i = i + 1
            v = args[i]
            if v == nil then
               stderr:write("smush: option '--", k, "' needs a value\n")
               exit(1)
            end
         end
      end
      if k == 'module' then
         script, entry = false, v
      elseif k == 'main' then
         script, entry = true, v
      elseif k == 'external' then
         known[v] = true
         externals[#externals + 1] = v
      elseif a == '--readable' then
         readable = true
      elseif a == '--help' then
         write(USAGE)
         exit(0)
      elseif a == '--version' then
         local version = require 'smush.version'
         write(version.versiontext)
         exit(0)
      elseif a == '--bundled' then
         local ok, bundled = pcall(require, 'smush.bundled')
         if not ok then
            stderr:write('smush: not a bundled program!\n',
               'Run build-aux/smush, which smush bundles, to list what is in it.\n')
            exit(1)
         end
         bundled.showbundled()
         exit(0)
      elseif sub(a, 1, 1) == '-' then
         stderr:write("smush: unrecognized option '", a, "'\n", USAGE)
         exit(1)
      elseif match(a, '^[%w_.%-]+::[%w_.%-]+$') then
         aliases[#aliases + 1] = {match(a, '^(.-)::(.*)$')}
      else
         sources[#sources + 1] = a
      end
      i = i + 1
   end

   if entry == nil then
      stderr:write('smush: give --main=NAME or --module=NAME\n', USAGE)
      exit(1)
   end

   local rocks, seen = {}, {}
   each(sources, function(a)
      local name, fname = source(a)
      known[name] = true
      local rock = rockof(fname)
      if rock ~= nil and not seen[rock] then
         seen[rock] = true
         rocks[#rocks + 1] = rock
      end
   end)
   sort(rocks)

   each(aliases, function(alias)
      local name, target = alias[1], alias[2]
      if known[name] or not known[target] or name == target then
         stderr:write('smush: ', name, '::', target, ': ', target, ' is not a bundled module,',
            ' or ', name, ' is bundled or external already\n')
         exit(1)
      end
      known[name] = true
   end)

   local text = {}
   local function put(s)
      text[#text + 1] = s
   end

   put(header(script, sorted(externals)) .. '\n')

   each(sources, function(a)
      local name, fname = source(a)
      put("bundled['" .. name .. "']=function()\n")
      minify.write(tokenize(fname), put, separators[readable](needspace))
      put '\nend\n'
      each(unbundled(significant(fname), known), function(missing)
         stderr:write('smush: warning: ', name, " names the module '", missing,
            "', which is in the Lua path, but is not bundled\n")
      end)
   end)

   each(aliases, function(alias)
      put("bundled['" .. alias[1] .. "']=function()return require'" .. alias[2] .. "'end\n")
   end)

   if not known['smush.bundled'] then
      put(bundled_module(rocks) .. '\n')
   end

   put(footer(script, entry) .. '\n')
   write(concat(text))
end

return {
   main = function(args)
      return main(args or arg)
   end,
}
