--[[
 Smush the source, Luke!
 Copyright (C) 2014-2026 Gary V. Vaughan
]]
--[[--
 Lua Lexer.

 Reads the tokens of Lua source, which `smush` writes again without the
 comments and white space that it does not need.  A `LuaLexer` is a
 `Scanner` of the text of the source, with a method that reads each kind
 of token, and one that picks the method for the next character.

 A token is a list of its kind, the text that it was read from, and the
 line that it starts on:

    {'IDENTIFIER', 'print', 1}

 The kinds are `COMMENT`, `IDENTIFIER`, `NUMBER`, `PUNCTUATION`, `STRING`
 and `WHITESPACE`.  Every character of the source is in a token, so the
 text of the tokens, joined, is the source.

 @module smush.lexer
]]


local _ENV = require 'std.normalize' {
   'string.find',
   'string.sub',
   Scanner = require 'std.prototype.scanner'.prototype,
   charset = require 'std.prototype.scanner'.charset,
}


local DIGIT = '0123456789'
local IDENT = '_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

local isdigit = charset(DIGIT)
local isxdigit = charset(DIGIT .. 'abcdefABCDEF')
local isident = charset(IDENT)
local isidnum = charset(IDENT .. DIGIT)
local isspace = charset ' \t\r\n\f\v'
local isquote = charset [["']]


-- The method of the lexer that reads a token from each character that it
-- starts with, and `punctuation` for the rest.
local START = {}
for c in next, isspace do START[c] = 'whitespace' end
for c in next, isident do START[c] = 'identifier' end
for c in next, isdigit do START[c] = 'number' end
for c in next, isquote do START[c] = 'shortstring' end
START['['] = 'longstring'
START['-'] = 'comment'


-- The text from *start* to the cursor of *self*.
local function since(self, start)
   return sub(self.text, start, self.pos - 1)
end


-- Whether the character is not one that ends a string or is an escape.
local function plain(quote)
   return function(c)
      return c ~= quote and c ~= '\\' and c ~= '\n'
   end
end


return {
   --- LuaLexer prototype object.
   -- @object prototype
   -- @string[opt='LuaLexer'] _type object name
   -- @see std.prototype.scanner.prototype
   prototype = Scanner {
      _type = 'LuaLexer',

      __index = {
         --- White space.
         -- @function prototype:whitespace
         -- @treturn table a `WHITESPACE` token
         whitespace = function(self)
            local line = self:line()
            return {'WHITESPACE', self:take(isspace), line}
         end,

         --- An identifier, or a keyword.
         -- @function prototype:identifier
         -- @treturn table an `IDENTIFIER` token
         identifier = function(self)
            local line = self:line()
            return {'IDENTIFIER', self:take(isidnum), line}
         end,

         --- A number, as Lua's own lexer reads one: decimal or hexadecimal,
         -- with a fraction and an exponent, and any letters that follow it,
         -- so that a malformed number is one token for Lua to refuse.
         -- @function prototype:number
         -- @treturn table a `NUMBER` token
         number = function(self)
            local line, start = self:line(), self.pos
            local expo = self:match '0[xX]' and 'pP' or 'eE'
            while true do
               local c = self:peek()
               if c ~= nil and find(expo, c, 1, true) then
                  self:next()
                  if self:peek() == '+' or self:peek() == '-' then
                     self:next()
                  end
               elseif c ~= nil and (isxdigit[c] or c == '.') then
                  self:next()
               else
                  break
               end
            end
            self:take(isident)
            return {'NUMBER', since(self, start), line}
         end,

         --- A string in quotes, with its escapes.
         -- @function prototype:shortstring
         -- @treturn table a `STRING` token
         shortstring = function(self)
            local line, start, quote = self:line(), self.pos, self:next()
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
                  self:error('unfinished string', start)
               end
            end
            return {'STRING', since(self, start), line}
         end,

         --- A string in long brackets, or the bracket if it is not one.
         -- @function prototype:longstring
         -- @treturn table a `STRING` or `PUNCTUATION` token
         longstring = function(self)
            local line, start = self:line(), self.pos
            local level = self:match '%[(=*)%['
            if level == nil then
               return {'PUNCTUATION', self:next(), line}
            elseif self:match('.-%]' .. level .. '%]') == nil then
               self:error('unfinished long string', start)
            end
            return {'STRING', since(self, start), line}
         end,

         --- A comment, to the end of the line or to its long brackets, or
         -- the minus if it is not one.
         -- @function prototype:comment
         -- @treturn table a `COMMENT` or `PUNCTUATION` token
         comment = function(self)
            local line, start = self:line(), self.pos
            if not self:lookahead '--' then
               return {'PUNCTUATION', self:next(), line}
            end
            local level = self:match '%-%-%[(=*)%['
            if level == nil then
               self:match '%-%-[^\n]*'
            elseif self:match('.-%]' .. level .. '%]') == nil then
               self:error('unfinished long comment', start)
            end
            return {'COMMENT', since(self, start), line}
         end,

         --- A character that is not part of any other token.
         -- @function prototype:punctuation
         -- @treturn table a `PUNCTUATION` token
         punctuation = function(self)
            local line = self:line()
            return {'PUNCTUATION', self:next(), line}
         end,

         --- The next token.
         -- @function prototype:token
         -- @treturn table|nil the token, or `nil` at the end of the source
         token = function(self)
            local c = self:peek()
            if c ~= nil then
               return self[START[c] or 'punctuation'](self)
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
