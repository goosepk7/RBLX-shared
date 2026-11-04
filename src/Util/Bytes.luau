--!strict
--[[
	Compact binary encoding for save formats and share codes: a growable writer and a bounded
	reader over Luau buffers. Integers are LEB128 varints (`uint`), zigzag varints for signed
	values (`int`), or fixed 8/32-bit; strings carry a varint byte length.

		local w = Bytes.writer()
		w:uint(3); w:int(-12); w:str("Starter")
		local data = w:toString()

		local r = Bytes.reader(data)
		local n, x, name = r:uint(), r:int(), r:str(32)
		if r:failed() then ... end -- truncated, oversized or malformed input

	The reader never errors on bad input: every read returns a value (0 or "" once it has
	failed) and sets `failed()`, so a decoder can read a whole record and check once. Varints
	are capped at 5 bytes and 2^32 - 1, and `str` takes the longest length the caller accepts,
	so a hostile code can't make the decoder allocate or loop without bound.
]]

local Bytes = {}

local MAX_UINT = 4294967295 -- 2^32 - 1
local MAX_INT = 2147483647 -- 2^31 - 1

export type Writer = {
	byte: (self: Writer, value: number) -> (),
	u32: (self: Writer, value: number) -> (),
	uint: (self: Writer, value: number) -> (),
	int: (self: Writer, value: number) -> (),
	str: (self: Writer, value: string) -> (),
	raw: (self: Writer, value: string) -> (),
	length: (self: Writer) -> number,
	toString: (self: Writer) -> string,
}

export type Reader = {
	byte: (self: Reader) -> number,
	u32: (self: Reader) -> number,
	uint: (self: Reader, max: number?) -> number,
	int: (self: Reader, min: number?, max: number?) -> number,
	str: (self: Reader, maxLength: number) -> string,
	raw: (self: Reader, length: number) -> string,
	remaining: (self: Reader) -> number,
	position: (self: Reader) -> number,
	failed: (self: Reader) -> boolean,
	fail: (self: Reader) -> (),
}

local function checkInteger(value: number, min: number, max: number, what: string)
	if value ~= value or value % 1 ~= 0 or value < min or value > max then
		error(`Util.Bytes: {what} must be an integer in [{min}, {max}], got {value}`, 3)
	end
end

--- A writer that grows as needed. Writing a value out of range errors: an encoder bug, not
--- bad input.
function Bytes.writer(initialCapacity: number?): Writer
	local buf = buffer.create(math.max(16, initialCapacity or 256))
	local size = 0

	local function reserve(extra: number)
		local capacity = buffer.len(buf)
		if size + extra <= capacity then
			return
		end
		while capacity < size + extra do
			capacity *= 2
		end
		local grown = buffer.create(capacity)
		buffer.copy(grown, 0, buf, 0, size)
		buf = grown
	end

	local writer = {}

	function writer.byte(_self: Writer, value: number)
		checkInteger(value, 0, 255, "byte")
		reserve(1)
		buffer.writeu8(buf, size, value)
		size += 1
	end

	function writer.u32(_self: Writer, value: number)
		checkInteger(value, 0, MAX_UINT, "u32")
		reserve(4)
		-- Big-endian, so the bytes read the same in any tool.
		buffer.writeu8(buf, size, bit32.rshift(value, 24))
		buffer.writeu8(buf, size + 1, bit32.band(bit32.rshift(value, 16), 0xFF))
		buffer.writeu8(buf, size + 2, bit32.band(bit32.rshift(value, 8), 0xFF))
		buffer.writeu8(buf, size + 3, bit32.band(value, 0xFF))
		size += 4
	end

	function writer.uint(_self: Writer, value: number)
		checkInteger(value, 0, MAX_UINT, "uint")
		reserve(5)
		local v = value
		while v >= 0x80 do
			buffer.writeu8(buf, size, 0x80 + v % 0x80)
			size += 1
			v = v // 0x80
		end
		buffer.writeu8(buf, size, v)
		size += 1
	end

	function writer.int(self: Writer, value: number)
		checkInteger(value, -MAX_INT - 1, MAX_INT, "int")
		-- Zigzag: 0, -1, 1, -2, 2 ... -> 0, 1, 2, 3, 4 so small magnitudes stay one byte.
		self:uint(if value >= 0 then value * 2 else -value * 2 - 1)
	end

	function writer.raw(_self: Writer, value: string)
		local n = #value
		reserve(n)
		buffer.writestring(buf, size, value)
		size += n
	end

	function writer.str(self: Writer, value: string)
		self:uint(#value)
		self:raw(value)
	end

	function writer.length(_self: Writer): number
		return size
	end

	function writer.toString(_self: Writer): string
		return buffer.readstring(buf, 0, size)
	end

	return (writer :: any) :: Writer
end

--- A reader over `data`. Reads past the end, oversized varints and over-long strings fail.
function Bytes.reader(data: string): Reader
	local buf = buffer.fromstring(data)
	local size = buffer.len(buf)
	local pos = 0
	local bad = false

	local reader = {}

	function reader.fail(_self: Reader)
		bad = true
	end

	function reader.failed(_self: Reader): boolean
		return bad
	end

	function reader.remaining(_self: Reader): number
		return size - pos
	end

	function reader.position(_self: Reader): number
		return pos
	end

	function reader.byte(_self: Reader): number
		if bad or pos >= size then
			bad = true
			return 0
		end
		local value = buffer.readu8(buf, pos)
		pos += 1
		return value
	end

	function reader.u32(self: Reader): number
		if bad or size - pos < 4 then
			bad = true
			return 0
		end
		local a, b, c, d = self:byte(), self:byte(), self:byte(), self:byte()
		return ((a * 256 + b) * 256 + c) * 256 + d
	end

	function reader.uint(self: Reader, max: number?): number
		local value = 0
		local scale = 1
		for _ = 1, 5 do
			local b = self:byte()
			if bad then
				return 0
			end
			value += (b % 0x80) * scale
			if b < 0x80 then
				if value > (max or MAX_UINT) then
					bad = true
					return 0
				end
				return value
			end
			scale *= 0x80
		end
		bad = true -- a sixth continuation byte: not a value this format writes
		return 0
	end

	function reader.int(self: Reader, min: number?, max: number?): number
		local z = self:uint()
		if bad then
			return 0
		end
		local value = if z % 2 == 0 then z // 2 else -(z + 1) // 2
		if value < (min or -MAX_INT - 1) or value > (max or MAX_INT) then
			bad = true
			return 0
		end
		return value
	end

	function reader.raw(_self: Reader, length: number): string
		if bad or length < 0 or size - pos < length then
			bad = true
			return ""
		end
		local value = buffer.readstring(buf, pos, length)
		pos += length
		return value
	end

	function reader.str(self: Reader, maxLength: number): string
		local n = self:uint(maxLength)
		if bad then
			return ""
		end
		return self:raw(n)
	end

	return (reader :: any) :: Reader
end

return Bytes
