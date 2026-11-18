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

 A barf can be indexed, with `!<barx>` as its magic line.  Its first
 entry is `index`, a Lua list of `{path, offset, size, mode}`, where
 offset is that of the data from the end of the index, and each of the
 other entries is named by its number.  The index is the only place that
 has the paths, and the data of any entry is found without a walk
 through the headers before it.  For the entries above it is:

    !<barx>
    63 644 index
    return {
    {"hello.txt", 8, 6, 420},
    {"bin/run", 24, 17, 493},
    }

    6 644 1
    Hello!
    17 755 2
    #!/bin/sh
    echo hi
    000000000000127

 `unpack` gives the entries with their paths, as for any barf.

 `host/barfx.c` reads a barf in C, and this module writes one, and
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
}


local MAGIC = '!<barf>\n'
local TRAILER = 16
local LENGTH = '^(' .. rep('%d', 15) .. ')\n$'
local DEFAULT_MODE = tonumber('644', 8)
local INDEXED = '!<barx>\n'
local INDEX = 'index'


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


-- The header line of *entry*, named *name*, or by its path.
local function header_of(entry, name)
   return format('%d %o %s\n', #entry.data, entry.mode or DEFAULT_MODE,
                 name or entry.path)
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
   rows[#rows + 1] = format('{%q, %d, %d, %d},\n', entry.path, at,
                            #entry.data, entry.mode or DEFAULT_MODE)
   return {pos = at + #entry.data + 1, rows = rows}
end


-- The text of the index of *entries*: a Lua list of rows `{path,
-- offset, size, mode}`, in the order of the barf.  Each offset is that
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
-- @tparam table entries a list of `{path=, data=, mode=}`, in order;
--    `mode` is a number (`tonumber('755', 8)`) and is 420 (octal 644)
--    if left out
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
         seen[path] = true
         entries[#entries + 1] = entry
         return read_entries(bytes, data_end + 1, last, seen, entries)
      end}
   )
end


-- The state of `resolve` with the entry that the row *i* of the index
-- names.
local function named(state, i, row)
   local raw = state.raw[i + 1]
   local path = type(row) == 'table' and row[1]
   local problem = state.problem or cond(
      {not raw or raw.path ~= tostring(i), function()
         return format('entry %d is not named', i)
      end},
      {path_problem(path), function(why)
         return format('path %q %s', tostring(path), why)
      end},
      {state.seen[tostring(path)], function()
         return format('path %q is there twice', path)
      end}
   )
   state.problem = problem
   state.seen[tostring(path)] = true
   state.entries[#state.entries + 1] = {
      path = path, data = raw and raw.data, mode = raw and raw.mode,
   }
   return state
end


-- The entries that the index, the first of *raw*, names, which are the
-- others, numbered; or nil and why not.
local function resolve(raw)
   local text = raw[1] and raw[1].data or ''
   local chunk, why = load(text, '=index', 't', {})
   return cond(
      {not raw[1] or raw[1].path ~= INDEX, failing 'no index'},
      {not chunk, failing('bad index: %s', why)},
      {true, function()
         local ok, rows = pcall(chunk)
         local list = choose(ok and type(rows) == 'table', rows, {})
         local state = foldl(iter(ipairs(list)),
                             {raw = raw, seen = {}, entries = {}},
                             named)
         return cond(
            {not ok or type(rows) ~= 'table', failing 'bad index'},
            {type(rows) == 'table' and #rows ~= #raw - 1,
               failing 'the index does not name the entries'},
            {state.problem, failing('%s', state.problem)},
            {true, state.entries}
         )
      end}
   )
end


-- The entries of the barf that has its magic line at *start* in
-- *bytes*, and ends at *last*; or nil and why not.
local function read_barf(bytes, start, last)
   local magic = sub(bytes, start, start + #MAGIC - 1)
   local function entries()
      return read_entries(bytes, start + #MAGIC, last, {}, {})
   end
   return cond(
      {magic == MAGIC, entries},
      {magic == INDEXED, function()
         local raw, why = entries()
         return cond(
            {not raw, failing('%s', why)},
            {true, function() return resolve(raw) end}
         )
      end},
      {true, failing 'no magic'}
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
      {magic == MAGIC or magic == INDEXED, function()
         return read_barf(bytes, start, last)
      end},
      {true, failing 'no magic'}
   )
end


return {
   pack = pack,
   unpack = unpack,
}
