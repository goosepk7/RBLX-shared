--!strict
--[[
	Non-cryptographic hashes for change detection and checksums: FNV-1a in 32 and 64 bits,
	computed exactly with doubles (no precision loss), so lune and Roblox agree byte for byte.

		Hash.fnv1a32("abc")       --> 440920331
		Hash.hex32(Hash.fnv1a32(s)) --> "1a47e90b"
		Hash.fnv1a64("abc")       --> "e71fa2190541574b" (hex, 16 characters)

	Use them to notice that data changed (a blueprint edited, a save corrupted), not to stop
	someone determined to forge a collision.
]]

local Hash = {}

local TWO32 = 4294967296
local OFFSET32 = 2166136261
-- FNV 64-bit offset basis 0xcbf29ce484222325 as two 32-bit limbs.
local OFFSET64_HI = 0xCBF29CE4
local OFFSET64_LO = 0x84222325

--- FNV-1a, 32-bit. `seed` replaces the offset basis (default 2166136261).
function Hash.fnv1a32(data: string, seed: number?): number
	local h = seed or OFFSET32
	for i = 1, #data do
		h = bit32.bxor(h, string.byte(data, i))
		-- h * 16777619 = h * 2^24 + h * 403 (mod 2^32); both terms stay exact in a double.
		h = (bit32.lshift(h, 24) + h * 403) % TWO32
	end
	return h
end

--- FNV-1a, 64-bit, as 16 lowercase hex characters.
function Hash.fnv1a64(data: string): string
	local hi, lo = OFFSET64_HI, OFFSET64_LO
	for i = 1, #data do
		lo = bit32.bxor(lo, string.byte(data, i))
		-- (hi:lo) * 0x100000001b3 = (hi:lo) * 0x1b3 + (lo << 40)  (mod 2^64)
		local loProduct = lo * 0x1B3 -- < 2^41: exact
		local carry = loProduct // TWO32
		local newLo = loProduct % TWO32
		local newHi = (hi * 0x1B3 + carry + bit32.lshift(lo, 8)) % TWO32
		hi, lo = newHi, newLo
	end
	return string.format("%08x%08x", hi, lo)
end

function Hash.hex32(value: number): string
	return string.format("%08x", value % TWO32)
end

return Hash
