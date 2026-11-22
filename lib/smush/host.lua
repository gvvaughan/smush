--[[
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
]]

--[[--
 Find the host files that a standalone program is made from.

 The host files are the C and shell sources that build a standalone
 program on a machine that has little more than a C compiler, `crush.c`
 and `barfx.c` among them.  They are in `host`, next to the `bin` that
 holds the script, in a git clone and in the directory of an installed
 rock.

 @module smush.host
]]

local _std = require 'std.functional.init'

local _ENV = require 'std.normalize' {
   'io.open',
   'string.match',
   choose = _std.choose,
}


--- The path of the host file *name*, such as `crush.c`.
-- It is in the `host` directory next to the bin directory of *script*,
-- which is where a git clone has it, and a rock installs it.  There is
-- no other place to look, so a file of another release is never found.
-- @string name the name of a file in `host`
-- @string script the path of the running script, `arg[0]`
-- @treturn[1] string the path of the file
-- @treturn[2] nil if there is no such file
local function path(name, script)
   local root = match(script or '', '^(.-)/?bin/[^/]+$')
   local file = choose(root, function()
      return choose(root ~= '', root .. '/', '') .. 'host/' .. name
   end)
   local handle = file and open(file)
   return choose(handle, function()
      handle:close()
      return file
   end)
end


return {
   path = path,
}
