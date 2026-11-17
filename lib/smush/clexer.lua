--[[
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
]]
--[[--
 C Lexer.

 Reads the tokens of C source, which `smush.c` writes again without the
 comments and white space that it does not need.  A `CLexer` is a `Scanner`
 of the text of the source, with a method that reads each kind of token, and
 one that picks the method for the next character.

 A token is a list of its kind, the text that it was read from, and the
 line that it starts on:

    {'IDENTIFIER', 'main', 1}

 The kinds are those of `smush.lexer`: `COMMENT`, `IDENTIFIER`, `NUMBER`,
 `PUNCTUATION`, `STRING` and `WHITESPACE`.  A `STRING` is a string or a
 character in quotes, or the name of a header in angle brackets after
 `#include`, so that a `//` or a `/*` in a path is not a comment.  One in
 quotes that is not closed on its line is the text to the end of the line, so
 that an apostrophe in the text of a preprocessor directive, as in
 `#error can't build`, is not an error.  White space has the ends of lines
 in it, as it does for Lua, but a backslash and a newline are a token of
 their own, and a newline in a comment is in the `COMMENT`, as neither ends
 the line that a preprocessor directive is on.  Every character of the
 source is in a token, so the text of the tokens, joined, is the source.

 @module smush.clexer
]]


local minify = require 'smush.minify'

local _ENV = require 'std.normalize' {
   'string.find',
   'string.sub',
   Scanner = require 'std.prototype.scanner'.prototype,
   charset = require 'std.prototype.scanner'.charset,
}


local DIGIT = '0123456789'
local IDENT = '_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

local isdigit = charset(DIGIT)
local isident = charset(IDENT)
local isidnum = charset(IDENT .. DIGIT)
local isspace = charset ' \t\r\n\f\v'
local isquote = charset [["']]


-- The operators of more than one character, by their length.
local OPERATORS = {[3] = {}, [2] = {}}
for op in ([[... <<= >>=]]):gmatch '%S+' do OPERATORS[3][op] = true end
for op in ([[-> ++ -- << >> <= >= == != && || += -= *= /= %= &= |= ^= ##]]):gmatch '%S+' do
   OPERATORS[2][op] = true
end

-- The directives that are followed by the name of a header.
local INCLUDES = {include = true, include_next = true, import = true}

-- The prefixes that make a string or a character wide.
local PREFIX = {L = true, u = true, U = true, u8 = true}


-- The method of the lexer that reads a token from each character that it
-- starts with, and `punctuation` for the rest.
local START = {['\\'] = 'backslash', ['.'] = 'dot', ['/'] = 'comment', ['<'] = 'angle'}
for c in next, isspace do START[c] = 'whitespace' end
for c in next, isident do START[c] = 'identifier' end
for c in next, isdigit do START[c] = 'number' end
for c in next, isquote do START[c] = 'shortstring' end


-- The text from *start* to the cursor of *self*.
local function since(self, start)
   return sub(self.text, start, self.pos - 1)
end


-- What the *token* that *self* has read means for the next one: whether
-- it is at the start of a line, after a `#` that started one, or after the
-- directive that is followed by the name of a header.
local function track(self, token)
   local kind, text = token[1], token[2]
   if minify.linebreak(token) then
      self.bol, self.hash, self.include = true, false, false
   elseif not minify.trivia(token) then
      self.include = self.hash == true and kind == 'IDENTIFIER' and INCLUDES[text] == true
      self.hash = self.bol ~= false and text == '#'
      self.bol = false
   end
   return token
end


-- Whether the character is not one that ends a string or is an escape.
local function plain(quote)
   return function(c)
      return c ~= quote and c ~= '\\' and c ~= '\n'
   end
end


-- Read the rest of a string or character in quotes, from *start*, after any
-- prefix, with the cursor at the opening quote.
local function quoted(self, start)
   local quote = self:next()
   while true do
      self:skip(plain(quote))
      local c = self:peek()
      if c == quote then
         self:next()
         break
      elseif c == '\\' then
         -- A backslash then a new line, of any kind, is escaped.
         self:next(self:lookahead '\\\r\n' and 3 or 2)
      else
         break
      end
   end
   return since(self, start)
end


return {
   --- CLexer prototype object.
   -- @object prototype
   -- @string[opt='CLexer'] _type object name
   -- @see std.prototype.scanner.prototype
   prototype = Scanner {
      _type = 'CLexer',

      __index = {
         --- White space, with the ends of lines in it.
         -- @function prototype:whitespace
         -- @treturn table a `WHITESPACE` token
         whitespace = function(self)
            local line = self:line()
            return {'WHITESPACE', self:take(isspace), line}
         end,

         --- A backslash and the end of the line, which carries a line on,
         -- or the backslash if it is not one.
         -- @function prototype:backslash
         -- @treturn table a `WHITESPACE` or `PUNCTUATION` token
         backslash = function(self)
            local line = self:line()
            local text = self:match '\\[ \t\r\f\v]*\n'
            if text == nil then
               return {'PUNCTUATION', self:next(), line}
            end
            return {'WHITESPACE', text, line}
         end,

         --- An identifier, or a keyword, or the prefix of a string.
         -- @function prototype:identifier
         -- @treturn table an `IDENTIFIER` or `STRING` token
         identifier = function(self)
            local line, start = self:line(), self.pos
            local name = self:take(isidnum)
            if PREFIX[name] and isquote[self:peek()] then
               return {'STRING', quoted(self, start), line}
            end
            return {'IDENTIFIER', name, line}
         end,

         --- A number, as the preprocessor reads one: from a digit, or a
         -- point and a digit, with the letters, digits and points that
         -- follow it, and a sign after an exponent, so that a malformed
         -- number is one token for the compiler to refuse.
         -- @function prototype:number
         -- @treturn table a `NUMBER` token
         number = function(self)
            local line, start = self:line(), self.pos
            while true do
               local c = self:peek()
               if c ~= nil and find('eEpP', c, 1, true) then
                  self:next()
                  if self:peek() == '+' or self:peek() == '-' then
                     self:next()
                  end
               elseif c ~= nil and (isidnum[c] or c == '.') then
                  self:next()
               else
                  break
               end
            end
            return {'NUMBER', since(self, start), line}
         end,

         --- A number that starts with a point, or the point.
         -- @function prototype:dot
         -- @treturn table a `NUMBER` or `PUNCTUATION` token
         dot = function(self)
            if isdigit[self:peek(1)] then
               return self:number()
            end
            return self:punctuation()
         end,

         --- A string or a character in quotes, with its escapes, or the
         -- rest of the line if the quote is not closed on it.
         -- @function prototype:shortstring
         -- @treturn table a `STRING` token
         shortstring = function(self)
            local line, start = self:line(), self.pos
            return {'STRING', quoted(self, start), line}
         end,

         --- The name of a header, in angle brackets on the line of an
         -- include, or the bracket if it is not one.
         -- @function prototype:angle
         -- @treturn table a `STRING` or `PUNCTUATION` token
         angle = function(self)
            local line = self:line()
            local text = self.include and self:match '<[^>\n]*>'
            if not text then
               return self:punctuation()
            end
            return {'STRING', text, line}
         end,

         --- A comment, in `/* */`, or from `//` to the end of the line,
         -- which a backslash at the end of the line carries on, or the
         -- slash if it is not one.
         -- @function prototype:comment
         -- @treturn table a `COMMENT` or `PUNCTUATION` token
         comment = function(self)
            local line, start = self:line(), self.pos
            if self:lookahead '/*' then
               if self:match '/%*.-%*/' == nil then
                  self:error('unfinished comment', start)
               end
            elseif self:lookahead '//' then
               repeat
                  local text = self:match '[^\n]*'
                  local carried = find(text, '\\[ \t\r\f\v]*$') and self:peek() == '\n'
                  if carried then
                     self:next()
                  end
               until not carried
            else
               return self:punctuation()
            end
            return {'COMMENT', since(self, start), line}
         end,

         --- An operator, or a character that is not part of any other
         -- token.
         -- @function prototype:punctuation
         -- @treturn table a `PUNCTUATION` token
         punctuation = function(self)
            local line = self:line()
            for n = 3, 2, -1 do
               local text = sub(self.text, self.pos, self.pos + n - 1)
               if OPERATORS[n][text] then
                  return {'PUNCTUATION', self:next(n), line}
               end
            end
            return {'PUNCTUATION', self:next(), line}
         end,

         --- The next token.
         -- @function prototype:token
         -- @treturn table|nil the token, or `nil` at the end of the source
         token = function(self)
            local c = self:peek()
            if c ~= nil then
               return track(self, self[START[c] or 'punctuation'](self))
            end
         end,

         --- All the tokens.
         -- @function prototype:tokens
         -- @treturn table the tokens that are left, in a list
         tokens = function(self)
            local r = {}
            for token in self.token, self do
               r[#r + 1] = token
            end
            return r
         end,
      },
   },
}
