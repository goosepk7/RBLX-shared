--!strict
local Base64 = require("@shared/Util/Base64")
local Bytes = require("@shared/Util/Bytes")
local Hash = require("@shared/Util/Hash")
local Sim = require("@shared/Sim")
local T = require("@shared/Test")

local expect = T.expect

local function randomBytes(rng: any, n: number): string
	local out = table.create(n)
	for i = 1, n do
		out[i] = string.char(rng:int(0, 255))
	end
	return table.concat(out)
end

T.describe("Util.Base64", function()
	T.it("matches the RFC 4648 test vectors", function()
		local vectors = {
			{ "", "" },
			{ "f", "Zg==" },
			{ "fo", "Zm8=" },
			{ "foo", "Zm9v" },
			{ "foob", "Zm9vYg==" },
			{ "fooba", "Zm9vYmE=" },
			{ "foobar", "Zm9vYmFy" },
		}
		for _, v in vectors do
			expect(Base64.encode(v[1])).toBe(v[2])
			expect(Base64.decode(v[2])).toBe(v[1])
		end
	end)

	T.it("uses - and _ in the URL alphabet, without padding by default", function()
		local data = string.char(0xFB, 0xFF, 0xBF)
		expect(Base64.encode(data)).toBe("+/+/")
		expect(Base64.encode(data, { url = true })).toBe("-_-_")
		expect(Base64.encode("f", { url = true })).toBe("Zg")
		expect(Base64.encode("f", { url = true, pad = true })).toBe("Zg==")
		expect(Base64.decode("-_-_", { url = true })).toBe(data)
		expect(Base64.decode("+/+/", { url = true })).toBeNil()
	end)

	T.it("round-trips random bytes of every length", function()
		local rng = Sim.Rng.new("base64")
		for n = 0, 70 do
			local data = randomBytes(rng, n)
			expect(Base64.decode(Base64.encode(data))).toBe(data)
			expect(Base64.decode(Base64.encode(data, { url = true }), { url = true })).toBe(data)
		end
	end)

	T.it("accepts missing padding and rejects malformed text", function()
		expect(Base64.decode("Zg")).toBe("f")
		expect(Base64.decode("Zm8")).toBe("fo")
		expect(Base64.decode("Z")).toBeNil() -- one leftover character
		expect(Base64.decode("Zg=")).toBeNil() -- padded but not a multiple of 4
		expect(Base64.decode("Zg===")).toBeNil()
		expect(Base64.decode("Zm9v!")).toBeNil()
		expect(Base64.decode("Zm 9v")).toBeNil()
		expect(Base64.decode("Zh==")).toBeNil() -- non-zero trailing bits: not a canonical encoding
	end)
end)

T.describe("Util.Bytes", function()
	T.it("round-trips every kind of value", function()
		local w = Bytes.writer(4)
		w:byte(0)
		w:byte(255)
		w:u32(0xDEADBEEF)
		for _, v in { 0, 1, 127, 128, 300, 16383, 16384, 4294967295 } do
			w:uint(v)
		end
		for _, v in { 0, -1, 1, -64, 63, -65, 64, -2147483648, 2147483647 } do
			w:int(v)
		end
		w:str("Starter")
		w:str("")
		w:str("Guaraná 🚗")
		local r = Bytes.reader(w:toString())
		expect(r:byte()).toBe(0)
		expect(r:byte()).toBe(255)
		expect(r:u32()).toBe(0xDEADBEEF)
		for _, v in { 0, 1, 127, 128, 300, 16383, 16384, 4294967295 } do
			expect(r:uint()).toBe(v)
		end
		for _, v in { 0, -1, 1, -64, 63, -65, 64, -2147483648, 2147483647 } do
			expect(r:int()).toBe(v)
		end
		expect(r:str(64)).toBe("Starter")
		expect(r:str(64)).toBe("")
		expect(r:str(64)).toBe("Guaraná 🚗")
		expect(r:remaining()).toBe(0)
		expect(r:failed()).toBe(false)
	end)

	T.it("keeps small numbers to one byte", function()
		local w = Bytes.writer()
		w:uint(127)
		w:int(-64)
		w:int(63)
		expect(w:length()).toBe(3)
		w:uint(128)
		expect(w:length()).toBe(5)
	end)

	T.it("fails, never errors, on truncated or hostile input", function()
		local w = Bytes.writer()
		w:str("hello")
		local data = w:toString()
		local truncated = Bytes.reader(string.sub(data, 1, 3))
		expect(truncated:str(64)).toBe("")
		expect(truncated:failed()).toBe(true)
		-- Reads after a failure keep returning zero values.
		expect(truncated:uint()).toBe(0)
		expect(truncated:byte()).toBe(0)

		local tooLong = Bytes.reader(data)
		expect(tooLong:str(4)).toBe("")
		expect(tooLong:failed()).toBe(true)

		-- Six continuation bytes: no varint this format writes is that long.
		local endless = Bytes.reader(string.rep(string.char(0xFF), 8))
		expect(endless:uint()).toBe(0)
		expect(endless:failed()).toBe(true)

		local capped = Bytes.reader(data)
		expect(capped:uint(4)).toBe(0) -- the length 5 is over the cap
		expect(capped:failed()).toBe(true)

		local w2 = Bytes.writer()
		w2:int(-500)
		local ranged = Bytes.reader(w2:toString())
		expect(ranged:int(-100, 100)).toBe(0)
		expect(ranged:failed()).toBe(true)
	end)

	T.it("rejects values an encoder should never write", function()
		local w = Bytes.writer()
		expect(function()
			w:byte(256)
		end).toThrow("byte")
		expect(function()
			w:uint(-1)
		end).toThrow("uint")
		expect(function()
			w:uint(1.5)
		end).toThrow("uint")
		expect(function()
			w:int(0 / 0)
		end).toThrow("int")
	end)

	T.it("grows past its initial capacity", function()
		local w = Bytes.writer(16)
		for i = 1, 1000 do
			w:uint(i)
		end
		local r = Bytes.reader(w:toString())
		for i = 1, 1000 do
			expect(r:uint()).toBe(i)
		end
		expect(r:failed()).toBe(false)
	end)
end)

T.describe("Util.Hash", function()
	T.it("matches the published FNV-1a vectors", function()
		expect(Hash.fnv1a32("")).toBe(0x811C9DC5)
		expect(Hash.fnv1a32("a")).toBe(0xE40C292C)
		expect(Hash.fnv1a32("abc")).toBe(440920331) -- the value the module header shows
		expect(Hash.fnv1a32("foobar")).toBe(0xBF9CF968)
		expect(Hash.fnv1a64("")).toBe("cbf29ce484222325")
		expect(Hash.fnv1a64("a")).toBe("af63dc4c8601ec8c")
		expect(Hash.fnv1a64("abc")).toBe("e71fa2190541574b")
		expect(Hash.fnv1a64("foobar")).toBe("85944171f73967e8")
	end)

	T.it("formats 32-bit values as 8 hex characters", function()
		expect(Hash.hex32(0)).toBe("00000000")
		expect(Hash.hex32(0xBF9CF968)).toBe("bf9cf968")
	end)

	T.it("changes when one byte changes", function()
		local rng = Sim.Rng.new("hash")
		for _ = 1, 50 do
			local data = randomBytes(rng, rng:int(1, 200))
			local i = rng:int(1, #data)
			local flipped = string.sub(data, 1, i - 1)
				.. string.char((string.byte(data, i) + 1) % 256)
				.. string.sub(data, i + 1)
			expect(Hash.fnv1a64(flipped)).never.toBe(Hash.fnv1a64(data))
			expect(Hash.fnv1a32(flipped)).never.toBe(Hash.fnv1a32(data))
		end
	end)
end)
