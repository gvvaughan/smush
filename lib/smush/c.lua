--[[
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
]]
--[[--
 Minify C.

 Writes C source again without the comments and white space that it does
 not need, for source that is kept in a repository with all of its comments,
 and carried without them in a file, such as a here document in a script.  It
 is the part of `smush` for C that `smush` for Lua is for the modules that a
 bundle is made of, and it puts the tokens of `smush.clexer` with
 `smush.minify` as `smush` puts those of `smush.lexer`.

 It reads one text, and does not parse it, so it makes no changes that need
 to know more than where each token ends.  A comment is a space, as it is to a
 compiler, and white space is only kept where the tokens on either side of it
 would be read as something else without it (`a b`, `- -c`, `L "x"`, `/ *`).
 A preprocessor directive is the one thing that has the end of a line in it,
 so each is on a line of its own, and white space between its tokens is a
 single space, since `#define F (x)` and `#define F(x)` are not the same
 directive.  The text of a string or of a character is not changed.  Every
 other line ends where the last token of it was written, if the next did not
 need one, so that the source is a few long lines.

 With `readable`, the lines of the source and the indentation of each stay
 as they are, and a run of white space in a line is one space, so that
 what is taken out is the comments, the blank lines and the space that is
 wasted, and the code can be read.  A backslash that carries a line on
 stays at the end of its line.

 @module smush.c
]]


local CLexer = require 'smush.clexer'.prototype
local minify = require 'smush.minify'
local _std = require 'std.functional.init'

local _ENV = require 'std.normalize' {
   'string.sub',
   'table.concat',
   choose = _std.choose,
   some = _std.some,
}


local needspace = minify.needspace(CLexer)


-- A separator, as `minify.compact` makes, that also puts each preprocessor
-- directive on a line of its own, and one space where it had any white space.
local function compact()
   local plain = minify.compact(needspace)
   local directive = false
   return function(prev, token, skipped)
      local broke = some(skipped, minify.linebreak)
      local ended = directive and (broke or token == nil)
      directive = directive and not ended
      if token == nil then
         return choose(ended, '\n')
      end
      local starts = token[1] == 'PUNCTUATION' and token[2] == '#' and (prev == nil or broke)
      directive = directive or starts
      if starts then
         return choose(prev ~= nil, '\n')
      elseif ended then
         return '\n'
      elseif prev and directive and #skipped > 0 then
         return ' '
      end
      return plain(prev, token, skipped)
   end
end


--- Write C again without the comments and white space that it does not
-- need.
-- @string text C source
-- @tparam[opt] table opts `name`, what to call the source in an error, and
--    `readable`, true to keep its lines and their indentation
-- @treturn string *text* minified, that ends with a newline, or is empty if
--    there is nothing in it
local function minify_c(text, opts)
   local out = {}
   local separator = choose(opts and opts.readable, function()
      return minify.readable(needspace)
   end, compact)
   minify.write(CLexer(text, opts and opts.name):tokens(), function(s)
      out[#out + 1] = s
   end, separator)
   local minified = concat(out)
   return choose(minified ~= '' and sub(minified, -1) ~= '\n', minified .. '\n', minified)
end


return {
   minify = minify_c,
}
