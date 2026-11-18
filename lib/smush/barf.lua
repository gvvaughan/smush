--[[
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
]]

--[[--
 Write and read a barf, a bundled archive format.

 A barf is a list of files, which can follow other bytes, such as a
 shell script or a program, and is found from its end:

    !<barf>
    6 644 hello.txt
    Hello!
    17 755 bin/run
    #!/bin/sh
    echo hi
    000000000000064

 The magic line is followed by each entry, a header of `SIZE MODE PATH`
 and then SIZE bytes of data and a newline.  The last line is the
 length of everything from the magic line to there, in 15 digits.

 `host/barf.c` reads a barf in C, and this module writes one, and
 reads one for the specs to check it by.

 @module smush.barf
]]

local _std = require 'std.functional.init'

local _ENV = require 'std.normalize' {
   'string.find',
   'string.format',
   'string.gmatch',
   'string.match',
   'string.rep',
   'string.sub',
   'table.concat',
   choose = _std.choose,
   cond = _std.cond,
   firstof = _std.firstof,
   flatten = _std.flatten,
   foldl = _std.foldl,
   id = _std.id,
   isstring = _std.isstring,
   iter = _std.iter,
   merged = _std.merged,
}


local MAGIC = '!<barf>\n'
local TRAILER = 16
local LENGTH = '^(' .. rep('%d', 15) .. ')\n$'
local DEFAULT_MODE = tonumber('644', 8)


-- A function that returns nil and the message that `format` makes.
local function failing(...)
   local args = {n = select('#', ...), ...}
   return function()
      return nil, format(unpack(args, 1, args.n))
   end
end


--- Describe what is wrong with a path of an entry, if anything.
-- A path is a name of a file that is made below the directory that a
-- barf is unpacked into, so it is not empty, not absolute, has no
-- newline, and no `..` or empty component.
-- @string path the path of an entry
-- @treturn[1] nil if the path is good
-- @treturn[2] string what is wrong with it
local function path_problem(path)
   local function component_problem(component)
      return cond(
         {component == '..', 'has a ".." component'},
         {component == '', 'has an empty component'}
      )
   end
   return choose(isstring(path) and path ~= '', function()
      return cond(
         {find(path, '\n', 1, true), 'has a newline'},
         {find(path, '\0', 1, true), 'has a NUL'},
         {sub(path, 1, 1) == '/', 'is absolute'},
         {firstof(iter(gmatch(path .. '/', '([^/]*)/')),
                  component_problem), id}
      )
   end, 'is empty')
end


-- What is wrong with *entry*, given the paths *seen* so far, or nil.
local function entry_problem(entry, seen)
   local path, problem = entry.path, path_problem(entry.path)
   return cond(
      {problem, function()
         return format('path %q %s', tostring(path), problem)
      end},
      {seen[path], function()
         return format('path %q is there twice', path)
      end},
      {not isstring(entry.data), function()
         return format('%q has no data', path)
      end}
   )
end


-- The state of `pack` with *entry* in it, the *i*th.
local function packed(state, i, entry)
   choose(entry_problem(entry, state.seen), function(problem)
      error(format('entry %d: %s', i, problem), 0)
   end)
   local header = format('%d %o %s\n', #entry.data,
                         entry.mode or DEFAULT_MODE, entry.path)
   return {
      parts = flatten {state.parts, header, entry.data, '\n'},
      seen = merged(state.seen, {[entry.path] = true}),
   }
end


--- Make the bytes of a barf.
-- @tparam table entries a list of `{path=, data=, mode=}`, in order;
--    `mode` is a number (`tonumber('755', 8)`) and is 420 (octal 644)
--    if left out
-- @treturn string the barf, with its trailer
local function pack(entries)
   local state = foldl(iter(ipairs(entries)),
                       {parts = {MAGIC}, seen = {}}, packed)
   local barf = concat(state.parts)
   return barf .. format('%015d\n', #barf)
end


-- The entries of *bytes* from *pos* to *last*, added to *entries*,
-- given the paths *seen* so far; or nil and why not.
local function read_entries(bytes, pos, last, seen, entries)
   local eol = pos <= last and find(bytes, '\n', pos, true)
   local size, mode, path = match(sub(bytes, pos, eol or 0),
                                  '^(%d+) ([0-7]+) ([^\n]+)\n$')
   local first = eol and eol + 1
   local data_end = size and first + tonumber(size) or last + 1
   local problem = path_problem(path)
   return cond(
      {pos == last + 1, entries},
      {pos > last, failing 'entries do not end at the trailer'},
      {not size, failing('bad header at %d', pos)},
      {data_end > last or sub(bytes, data_end, data_end) ~= '\n',
         failing('bad size for %q', path)},
      {problem, failing('path %q %s', path, problem)},
      {seen[path], failing('path %q is there twice', path)},
      {true, function()
         local entry = {
            path = path,
            data = sub(bytes, first, data_end - 1),
            mode = tonumber(mode, 8),
         }
         return read_entries(bytes, data_end + 1, last,
                             merged(seen, {[path] = true}),
                             merged(entries, {[#entries + 1] = entry}))
      end}
   )
end


--- Read the barf at the end of some bytes.
-- Whatever comes before the barf is ignored: the trailer gives where
-- the barf starts.
-- @string bytes a file, such as a script or a program, that ends in a
--    barf
-- @treturn[1] table a list of `{path=, data=, mode=}`, in order
-- @treturn[2] nil
-- @treturn[2] string why there is no barf
local function unpack(bytes)
   local length = tonumber(match(sub(bytes, -TRAILER), LENGTH))
   local start = length and #bytes - TRAILER - length + 1
   local last = #bytes - TRAILER
   local magic = length and start >= 1
      and sub(bytes, start, start + #MAGIC - 1)
   return cond(
      {not length, failing 'no trailer'},
      {magic == MAGIC, function()
         return read_entries(bytes, start + #MAGIC, last, {}, {})
      end},
      {true, failing 'no magic'}
   )
end


return {
   pack = pack,
   unpack = unpack,
}
