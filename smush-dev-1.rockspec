-- Smush the source, Luke!
-- Copyright (C) 2026 Gary V. Vaughan

local _MODREV, _SPECREV = 'dev', '-1'

rockspec_format = '3.0'
package = 'smush'
version = _MODREV .. _SPECREV

description = {
   summary = 'Bundle Lua modules into a single file',
   detailed = [[
      Squeezes the comments and white space out of Lua modules, and writes
      them into one file, to run as a program or load as a module, where
      they run in an environment of their own that nothing leaks out of or
      into.
   ]],
   homepage = 'https://github.com/gvvaughan/smush',
   license = 'MIT',
}

-- The std.functional, std.normalize and std.prototype releases that have
-- what smush uses (a sorted `keys`, `string.format` in Lua 5.1, and the
-- `scanner` and `contextmanager` modules) raise these.
dependencies = {
   'lua >= 5.1, < 5.6',
   'std.functional >= 2',
   'std.normalize >= 4',
   'std.prototype >= 2',
}

build = {
   type = 'builtin',
   modules = {
      smush = 'lib/smush/init.lua',
      ['smush.lexer'] = 'lib/smush/lexer.lua',
   },
   install = {
      bin = {smush = 'bin/smush'},
   },
}

test_dependencies = {
   'ansicolors',
   'luacov',
   'specl >= 16.1',
}

test = {
   type = 'command',
   command = 'specl spec/*_spec.yaml',
}

source = {
   url = 'git+https://github.com/gvvaughan/smush.git',
}
