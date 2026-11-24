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
 rock.  A standalone program has them in its payload instead, and finds
 them there first.

 @module smush.host
]]

local _std = require 'std.functional.init'

local _ENV = require 'std.normalize' {
   'io.open',
   'package',
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


local M = {path = path}


--- The payload of a standalone program.
-- It is the module `smush.payload` that the program provides, and there
-- is none when smush is not a standalone program.
-- @treturn[1] table the payload, with a `read` function
-- @treturn[2] nil if smush is not a standalone program
function M.payload()
   local open_payload = package.preload['smush.payload']
   return open_payload and open_payload()
end


--- The text of the host file *name*, such as `crush.c`.
-- A standalone program has it in its payload, where it is looked for
-- first, and only.  Otherwise it is the contents of the file that `path`
-- finds.
-- @string name the name of a file in `host`
-- @string script the path of the running script, `arg[0]`
-- @treturn[1] string the text of the file
-- @treturn[2] nil if there is no such file
function M.read(name, script)
   local payload = M.payload()
   local file = not payload and path(name, script)
   local handle = file and open(file, 'rb')
   return choose(payload, function()
      return payload.read('host/' .. name)
   end, function()
      return handle and handle:read '*a'
   end)
end


return M
