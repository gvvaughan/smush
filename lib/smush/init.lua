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
local _context = require 'std.prototype.contextmanager'
local _std = require 'std.functional.init'

local _ENV = require 'std.normalize' {
   'io.stderr',
   'io.write',
   'os.exit',
   'package',
   'package.searchpath',
   'string.find',
   'string.format',
   'string.gsub',
   'string.match',
   'string.sub',
   'table.concat',
   File = _context.File,
   slurp = _context.slurp,
   each = _std.each,
   keys = _std.keys,
   map = _std.map,
   reject = _std.reject,
   sorted = _std.sorted,
}


-- Whether tokens of these kinds, with no space between them, would be
-- read as something else than the two of them.
local WORDLIKE = {IDENTIFIER = true, NUMBER = true}

local function needspace(a, b)
   if a == nil then
      return false
   end
   return (WORDLIKE[a[1]] and WORDLIKE[b[1]])             -- one word
      or (a[2] == '-' and b[2] == '-')                    -- `--` is a comment
      or (a[1] == 'NUMBER' and b[2] == '.')               -- `1..` is a number
      or (a[2] == '[' and b[1] == 'STRING' and sub(b[2], 1, 1) == '[')
end                                                       -- `[[` is a string


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


-- The script or module that smush writes, runs bundled packages in a private
-- environment of its own with a copy of the globals, `require` and a
-- `package.loaded` so that nothing leaks into the host's `package` module,
-- and nothing leaks out of it, except for the modules that the host is to
-- provide, named by `--external`, which the bundle asks the host's own
-- `require` for, the first time that it needs one.  Any other module that
-- the host happens to have loaded, such as typecheck or std.strict, which
-- std.normalize and std.functional behave differently with, is not there
-- for the bundle.
local function header(script, externals)
   return (script and '#!/usr/bin/env lua\n' or '') .. concat({
      '--[[ minified code follows, see --help text for source location! ]]',
      'local host,hostrequire=package,require',
      'local env={}for k,v in next,_G do env[k]=v end env._G=env',
      'local bundled,loaded={},{}' .. concat(map(externals, function(name)
         return format(' bundled[%q]=function(n)local m=host.loaded[n]if m==nil then m=hostrequire(n)end return m end', name)
      end)),
      'env.package=setmetatable({preload={},loaded=loaded},{__index=host})',
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

-- The tokens of *fname* that matter to the program, without its comments
-- and whitespace.
local function significant(fname)
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
   return reject(tokens, function(token)
      return token[1] == 'COMMENT' or token[1] == 'WHITESPACE'
   end)
end

-- Write *tokens* with whitespace strategically injected back into the stream.
local function minify(tokens)
   local line, prev = 1
   each(tokens, function(token)
      if needspace(prev, token) then
         write(line < token[3] and '\n' or ' ')
      end
      write(tostring(token[2]))
      prev, line = token, token[3]
   end)
end


-- The modules that are in the Lua path and not bundled, but which  a
-- string in *tokens* names.  A string such as 'std.functional._base.argscheck'
-- implies the modules std.functional._base, or std.functional or std , so look
-- for the longest of them that is already bundled, or else the longest in the
-- path.  A module that is only asked for as `pcall(require, 'name')` is not
-- flagged as missing.
local function unbundled(tokens, known)
   local r = {}
   for i = 1, len(tokens) do
      local token = tokens[i]
      local name = token[1] == 'STRING' and match(token[2], '^["\']([%w_][%w_.%-]*[%w_])["\']$')
      local optional = i > 2 and tokens[i - 1][2] == ',' and tokens[i - 2][2] == 'require'
      if name and not optional then
         local found
         while name ~= nil and not known[name] do
            found = found or (searchpath(name, package.path) and name)
            name = match(name, '^(.+)%.[^.]*$')
         end
         if name == nil and found then
            r[found] = true
         end
      end
   end
   return keys(r)
end


local USAGE = [[
Usage: smush [OPTION]... SOURCE...

Write a single file that bundles each SOURCE, to standard output.  A SOURCE
is the path of a module, which is bundled under the name that its path makes,
NAME=PATH, which is bundled as NAME, or the name of a module to find in the
Lua path, which is bundled under that name.  ALIAS::MODULE makes the module
ALIAS the bundled MODULE, and not a copy of it, so that libraries which each
have a copy of one file share the one.

  --main=NAME      write a script that exits with the result of calling the
                   `main` function of the bundled module NAME
  --module=NAME    write a module that returns the bundled module NAME
  --external=NAME  the host provides the module NAME to the bundle, which
                   asks the host's `require` for it when it needs it
  --help           show this help, and exit
]]


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
   local script, entry, sources, known, externals = true, nil, {}, {}, {}
   local aliases = {}
   each(args, function(a)
      local k, v = match(a, '^%-%-(%w+)=(.*)$')
      if k == 'module' then
         script, entry = false, v
      elseif k == 'main' then
         script, entry = true, v
      elseif k == 'external' then
         known[v] = true
         externals[#externals + 1] = v
      elseif a == '--help' then
         write(USAGE)
         exit(0)
      elseif match(a, '^[%w_.%-]+::[%w_.%-]+$') then
         aliases[#aliases + 1] = {match(a, '^(.-)::(.*)$')}
      else
         sources[#sources + 1] = a
      end
   end)

   if entry == nil then
      stderr:write('smush: give --main=NAME or --module=NAME\n', USAGE)
      exit(1)
   end

   local tokens = {}
   each(sources, function(a)
      local name, fname = source(a)
      known[name], tokens[name] = true, significant(fname)
   end)

   each(aliases, function(alias)
      local name, target = alias[1], alias[2]
      if known[name] or not known[target] or name == target then
         stderr:write('smush: ', name, '::', target, ': ', target, ' is not a bundled module,',
            ' or ', name, ' is bundled or external already\n')
         exit(1)
      end
      known[name] = true
   end)

   print(header(script, sorted(externals)))

   each(sources, function(a)
      local name = source(a)
      print("bundled['" .. name .. "']=function()")
      minify(tokens[name])
      print '\nend'
      each(unbundled(tokens[name], known), function(missing)
         stderr:write('smush: warning: ', name, " names the module '", missing,
            "', which is in the Lua path, but is not bundled\n")
      end)
   end)

   each(aliases, function(alias)
      print("bundled['" .. alias[1] .. "']=function()return require'" .. alias[2] .. "'end")
   end)

   print(footer(script, entry))
end

return {
   main = function(args)
      return main(args or arg)
   end,
}
