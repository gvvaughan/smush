--[[
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
]]

--[[--
 Write and read a barf, a bundled archive format.

 A barf is a list of files, which can follow other bytes, such as a
 shell script or a program, and is found from its end:

    !<barf>
    6 hello.txt
    Hello!
    17 bin/run
    #!/bin/sh
    echo hi
    000000000000056

 The magic line is followed by each entry, a header of `SIZE PATH`
 and then SIZE bytes of data and a newline.  The last line is the
 length of everything from the magic line to there, in 15 digits.

 A barf can be indexed, with `!<barx>` as its magic line.  Its first
 entry is `index`, a Lua list of `{path, offset, size}`, where
 offset is that of the data from the end of the index, and each of the
 other entries is named by its number.  The index is the only place that
 has the paths, and the data of any entry is found without a walk
 through the headers before it.  For the entries above it is:

    !<barx>
    53 index
    return {
    {"hello.txt", 4, 6},
    {"bin/run", 16, 17},
    }

    6 1
    Hello!
    17 2
    #!/bin/sh
    echo hi
    000000000000105

 This module only writes a barf.

 @module smush.barf
]]

local _std = require 'std.functional.init'

local _ENV = require 'std.normalize' {
   'string.find',
   'string.format',
   'string.gmatch',
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
}


local MAGIC = '!<barf>\n'
local INDEXED = '!<barx>\n'
local INDEX = 'index'


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


-- The header line of *entry*, named *name*, or by its path.
local function header_of(entry, name)
   return format('%d %s\n', #entry.data, name or entry.path)
end


-- The state of `pack` with *entry* in it, the *i*th.  The state is
-- changed in place: a copy of it for each entry would take time as the
-- square of the number of entries.
local function packed(state, i, entry)
   choose(entry_problem(entry, state.seen), function(problem)
      error(format('entry %d: %s', i, problem), 0)
   end)
   local parts = state.parts
   parts[#parts + 1] = header_of(entry, state.numbered and tostring(i))
   parts[#parts + 1] = entry.data
   parts[#parts + 1] = '\n'
   state.seen[entry.path] = true
   return state
end


-- The state of `index_text` with the row of *entry* in it, changed in
-- place.
local function indexed(state, i, entry)
   local header = header_of(entry, tostring(i))
   local at = state.pos + #header
   local rows = state.rows
   rows[#rows + 1] = format('{%q, %d, %d},\n', entry.path, at,
                            #entry.data)
   return {pos = at + #entry.data + 1, rows = rows}
end


-- The text of the index of *entries*: a Lua list of rows `{path,
-- offset, size}`, in the order of the barf.  Each offset is that
-- of the data of the entry, from the end of the entry of the index.
local function index_text(entries)
   local state = foldl(iter(ipairs(entries)),
                       {pos = 0, rows = {}}, indexed)
   return concat(flatten {'return {\n', state.rows, '}\n'})
end


-- The bytes of *entry*, named *name*.
local function entry_bytes(entry, name)
   return header_of(entry, name) .. entry.data .. '\n'
end


--- Make the bytes of a barf.
-- @tparam table entries a list of `{path=, data=}`, in order
-- @tparam[opt] table opts `index`, true to number the entries and keep
--    their paths in an index
-- @treturn string the barf, with its trailer
local function pack(entries, opts)
   local numbered = opts and opts.index
   local state = foldl(iter(ipairs(entries)),
                       {numbered = numbered, parts = {}, seen = {}},
                       packed)
   local index = choose(numbered, function()
      return entry_bytes({data = index_text(entries)}, INDEX)
   end, '')
   local barf = choose(numbered, INDEXED, MAGIC) .. index
      .. concat(state.parts)
   return barf .. format('%015d\n', #barf)
end


return {
   pack = pack,
}
