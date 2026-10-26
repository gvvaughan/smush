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
