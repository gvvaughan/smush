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

-- The tokens of *fname* that matter to the program, without its comments
-- and whitespace.  The name of this smush between two at signs is the
-- version of it, so that a program can say which smush bundled it.
local function significant(fname)
   local text, err = slurp(File(fname))
   if text == nil then
      stderr:write('smush: ', err, '\n')
      exit(1)
   end
   local version = smush_version()
   if version then
      -- Not written whole, or smush would fill it in its own source.
      text = gsub(text, '@' .. 'smush' .. '@', version)
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
  --help           show this help, and exit
  --version        show the version, and exit
  --bundled        list the rocks bundled in smush, and exit
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
      elseif a == '--help' then
         write(USAGE)
         exit(0)
      elseif a == '--version' then
         local version = require 'smush.version'
         write(version.versiontext)
         exit(0)
      elseif a == '--bundled' then
         local version = require 'smush.version'
         -- The smush that bundled this one, if its version file says.
         local by = version.SMUSH
         if by ~= nil and by ~= '' and not find(by, '@', 1, true) then
            write('smush ', by, ' bundled:\n')
         end
         for i = 1, #(version.BUNDLED or {}) do
            write(version.BUNDLED[i], '\n')
         end
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
