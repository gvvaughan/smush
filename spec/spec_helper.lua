--[[
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
]]

-- Load modules from this source tree, ahead of any installed copies.
-- Specl reloads this file for every example, so only prepend once.
local LIBPATH = './lib/?.lua;./lib/?/init.lua;'
if package.path:sub(1, #LIBPATH) ~= LIBPATH then
   package.path = LIBPATH .. package.path
end


-- Call *fn* with *...* in-process, in an environment where it loads
-- every module afresh, and return a specl Process with its exit status
-- and output.
function capture(fn, ...)
   return require 'specl.inprocess'.capture(function(fn, ...)
      setfenv(fn, getfenv(1))
      return fn(...)
   end, {fn, ...})
end


-- Set `t[k] = v` until the next call to `restore`.
-- Specl runs this file again for every example, so keep the record of
-- replacements somewhere that every copy of these functions shares.
local registry = debug.getregistry()
registry['smush.spec.replaced'] = registry['smush.spec.replaced'] or {}
local replaced = registry['smush.spec.replaced']

function replace(t, k, v)
   replaced[#replaced + 1] = {t, k, t[k]}
   t[k] = v
end

function restore()
   for i = #replaced, 1, -1 do
      local t, k, v = unpack(replaced[i])
      t[k] = v
      replaced[i] = nil
   end
end


-- The entries of the barf at the end of *bytes*, a list of `{path=,
-- data=, mode=}` in order, with the paths from the index if there is
-- one; or nil and why not.  This trusts what `pack` writes, and does
-- not check it.
function unbarf(bytes)
   local length = tonumber(bytes:match('(' .. ('%d'):rep(15) .. ')\n$'))
   if not length then
      return nil, 'no trailer'
   end
   local last = #bytes - 16
   local pos = last - length + 1
   local magic = bytes:match('^(!<bar%a>)\n', pos)
   if not magic then
      return nil, 'no magic'
   end
   local entries = {}
   pos = pos + #magic + 1
   while pos <= last do
      local size, mode, path, data = bytes:match(
         '^(%d+) (%d+) ([^\n]+)\n()', pos)
      entries[#entries + 1] = {
         path = path,
         data = bytes:sub(data, data + size - 1),
         mode = tonumber(mode, 8),
      }
      pos = data + size + 1
   end
   if magic == '!<barx>' then
      local text = table.remove(entries, 1).data
      local index = load(text, '=index', 't', {})()
      for i, row in ipairs(index) do
         entries[i].path = row[1]
      end
   end
   return entries
end
