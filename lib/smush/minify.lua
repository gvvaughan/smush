--[[
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
]]
--[[--
 Minify Tokens.

 Writes the tokens of a source again with only what is wanted between them,
 for any lexer whose tokens are `{kind, text, line}`, and whose `COMMENT`
 and `WHITESPACE` tokens (see `trivia`) are the ones that are taken out.
 What is wanted between two tokens is the only part that is particular to a
 source, so `write` goes through the tokens, and is given a *separator*: a
 function of the token before, the token, and the list of the comments and
 white space between them, which gives the text to put in front of the token,
 if there is some.  It is called once more, with no token, after the last
 one, so that a language that has to end with some text can give it.  A
 separator is made by `compact` or by `readable` for the `needspace` of a
 lexer, and a language that needs more makes its own from them.

 @module smush.minify
]]


local _std = require 'std.functional.init'

local _ENV = require 'std.normalize' {
   'string.find',
   'string.match',
   'string.sub',
   choose = _std.choose,
   each = _std.each,
}


--- Whether *token* is one that is taken out: a comment, or white space.
-- @tparam table token a token
-- @treturn boolean
local function trivia(token)
   return token[1] == 'COMMENT' or token[1] == 'WHITESPACE'
end


--- Whether *token* is a backslash and the end of a line, which carries a line on.
-- @tparam table token a token
-- @treturn boolean
local function continuation(token)
   return token[1] == 'WHITESPACE' and sub(token[2], 1, 1) == '\\'
end


--- Whether *token* is white space that has the end of a line in it.
-- @tparam table token a token
-- @treturn boolean
local function linebreak(token)
   return token[1] == 'WHITESPACE' and not continuation(token) and find(token[2], '\n', 1, true) ~= nil
end


--- A function that tests whether two tokens need a space between them.
-- They do if the text of them, with no space, is not read as the two
-- tokens by the lexer, as `a b`, or `- -` in Lua, where `--` is a comment.
-- A text that the lexer refuses is not read as the two tokens either.  The
-- answer is kept for each pair of texts, as a pair is often met again.
-- @tparam table Lexer a lexer prototype
-- @treturn function `needspace(a, b)`, true if tokens *a* and *b* do
local function needspace(Lexer)
   local known = {}
   local function lex(text)
      return Lexer(text):tokens()
   end
   return function(a, b)
      local key = a[2] .. '\0' .. b[2]
      if known[key] == nil then
         local ok, tokens = pcall(lex, a[2] .. b[2])
         known[key] = not ok or #tokens ~= 2 or tokens[1][2] ~= a[2]
      end
      return known[key]
   end
end


--- A separator that gives a space, or a new line if the tokens were on
-- different lines, only where two tokens need one.
-- @tparam function needspace as made by `needspace`
-- @treturn function a separator
local function compact(needspace)
   return function(prev, token)
      if prev and token and needspace(prev, token) then
         return choose(prev[3] < token[3], '\n', ' ')
      end
   end
end


--- A separator that gives the lines of the source, and the indentation of
-- each, and a space where there was any white space or a comment, or two
-- tokens need one.  A backslash that carries a line on is kept.
-- @tparam function needspace as made by `needspace`
-- @treturn function a separator
local function readable(needspace)
   return function(prev, token, skipped)
      if token == nil then
         return nil
      end
      local newline, continued, fresh, indent = false, false, prev == nil, ''
      each(skipped, function(skip)
         if continuation(skip) then
            continued, fresh, indent = true, true, ''
         elseif linebreak(skip) then
            newline, fresh, indent = true, false, match(skip[2], '^.*\n(.*)$')
         elseif fresh and skip[1] == 'WHITESPACE' then
            fresh, indent = false, skip[2]
         end
      end)
      if prev == nil then
         return indent
      elseif newline then
         return '\n' .. indent
      elseif continued then
         return ' \\\n' .. indent
      elseif #skipped > 0 or needspace(prev, token) then
         return ' '
      end
   end
end


--- Put the text of *tokens*, all those of a source, in *put*, with what
-- *separator* gives in front of each.  The comments and the white space are
-- not put.  The separator is called once more at the end, with no token, for
-- any text that it has to end with.
-- @tparam table tokens the tokens of a source
-- @tparam function put a function that is given each piece of the result
-- @tparam function separator `separator(prev, token, skipped)`
local function write(tokens, put, separator)
   local prev, skipped = nil, {}
   each(tokens, function(token)
      if trivia(token) then
         skipped[#skipped + 1] = token
      else
         put(separator(prev, token, skipped) or '')
         put(token[2])
         prev, skipped = token, {}
      end
   end)
   put(separator(prev, nil, skipped) or '')
end


return {
   compact = compact,
   continuation = continuation,
   linebreak = linebreak,
   needspace = needspace,
   readable = readable,
   trivia = trivia,
   write = write,
}
