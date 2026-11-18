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
