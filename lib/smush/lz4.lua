--[[
 Smush the source, Luke!
 Copyright (C) 2026 Gary V. Vaughan
]]

--[[--
 Compress with the LZ4 block format.

 An LZ4 block has no header and no checksum.  It is a run of sequences,
 each some literal bytes followed by a copy of bytes from earlier in the
 output.  The C in `host/barfx.c` decompresses it in a few lines, which
 is why a barf can use it: smush, which has this compressor, writes the
 barf, and the C that unpacks it needs only a decompressor.

 Unlike the rest of smush, this module uses loops that update tables in
 place.  For each byte of its input, a compressor looks up and records
 where the four bytes from there were last seen, and a fold that builds
 a new table at every step takes time that grows with the square of the
 input length.  The functions still take and return plain values, and
 keep no state between calls.

 @module smush.lz4
]]

local byte, char, sub = string.byte, string.char, string.sub
local concat, min, floor = table.concat, math.min, math.floor

-- A match starts at most this far back, so its offset fits in two bytes.
local WINDOW = 65535
-- LZ4 requires the last five bytes of a block to be literals, and no
-- match to start in the last twelve.
local LAST_LITERALS, LAST_MATCH = 5, 12


-- The bytes of *s* as a list of numbers.
local function bytes(s)
   local list, n = {}, #s
   for i = 1, n, 4096 do
      local chunk = {byte(s, i, min(i + 4095, n))}
      for j = 1, #chunk do
         list[i + j - 1] = chunk[j]
      end
   end
   return list
end


-- Append the extra bytes of a length that does not fit in four bits;
-- *n* is the part of the length beyond 15.
local function extra(out, n)
   while n >= 255 do
      out[#out + 1] = '\255'
      n = n - 255
   end
   out[#out + 1] = char(n)
end


--- Compress a string.
-- @string data what to compress
-- @int[opt=64] depth how many earlier places of the same four bytes to
--    try for the longest match; more is smaller but slower
-- @treturn string the block
local function compress(data, depth)
   depth = depth or 64
   local n, b = #data, bytes(data)
   local head, prev, out = {}, {}, {}
   local anchor, i, limit = 1, 1, n - LAST_MATCH

   -- Write the literals from *anchor* to *last*, then, if *len* is
   -- given, a match of *len* bytes from *off* bytes back.
   local function emit(last, len, off)
      local literals = last - anchor + 1
      local matched = len and len - 4 or 0
      out[#out + 1] = char(min(literals, 15) * 16 + min(matched, 15))
      if literals >= 15 then
         extra(out, literals - 15)
      end
      out[#out + 1] = sub(data, anchor, last)
      if len then
         out[#out + 1] = char(off % 256, floor(off / 256))
         if matched >= 15 then
            extra(out, matched - 15)
         end
      end
   end

   -- The four bytes at *at*, as one number to use as a table key.
   local function key(at)
      return b[at] + b[at + 1] * 256 + b[at + 2] * 65536 +
         b[at + 3] * 16777216
   end

   while i <= limit do
      local k = key(i)
      local candidate, best, best_off, tries = head[k], 0, 0, depth
      while candidate and tries > 0 and i - candidate <= WINDOW do
         local l = 4
         while i + l <= n - LAST_LITERALS and
               b[candidate + l] == b[i + l] do
            l = l + 1
         end
         if l > best then
            best, best_off = l, i - candidate
         end
         candidate, tries = prev[candidate], tries - 1
      end
      prev[i], head[k] = head[k], i
      if best >= 4 then
         emit(i - 1, best, best_off)
         for j = i + 1, min(i + best - 1, limit) do
            local kj = key(j)
            prev[j], head[kj] = head[kj], j
         end
         i = i + best
         anchor = i
      else
         i = i + 1
      end
   end
   emit(n)
   return concat(out)
end


return {
   compress = compress,
}
