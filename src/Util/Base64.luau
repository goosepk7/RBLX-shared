--!strict
--[[
	Base64 (RFC 4648) for share codes and binary saves. `url = true` uses the URL-safe alphabet
	(`-` and `_` instead of `+` and `/`), which survives chat apps, forums and file names, and
	is what players copy and paste.

		local code = Base64.encode(bytes, { url = true, pad = false })
		local back = Base64.decode(code, { url = true }) -- nil when the text isn't valid Base64

	Decoding is strict: characters outside the alphabet, an impossible length or non-zero
	trailing bits return nil, so a mistyped code is rejected instead of decoding to garbage.
	Padding is optional on input. Strip whitespace before decoding if the text came from a
	player (`string.gsub(text, "%s", "")`).
]]

local Base64 = {}

export type Options = { url: boolean?, pad: boolean? }

local STANDARD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local function tables(alphabet: string): ({ string }, { [number]: number })
	local encode: { string } = {}
	local decode: { [number]: number } = {}
	for i = 1, #alphabet do
		local c = string.sub(alphabet, i, i)
		encode[i - 1] = c
		decode[string.byte(c)] = i - 1
	end
	return encode, decode
end

local STANDARD_ENCODE, STANDARD_DECODE = tables(STANDARD)
local URL_ENCODE, URL_DECODE = tables(URL)
local PAD = string.byte("=")

function Base64.encode(data: string, options: Options?): string
	local o: Options = options or {}
	local enc = if o.url then URL_ENCODE else STANDARD_ENCODE
	local pad = if o.pad == nil then not o.url else o.pad
	local out: { string } = table.create(math.ceil(#data / 3) * 4)
	local n = #data
	for i = 1, n - 2, 3 do
		local a, b, c = string.byte(data, i, i + 2)
		local v = a * 65536 + b * 256 + c
		table.insert(out, enc[v // 262144])
		table.insert(out, enc[(v // 4096) % 64])
		table.insert(out, enc[(v // 64) % 64])
		table.insert(out, enc[v % 64])
	end
	local rest = n % 3
	if rest == 1 then
		local a = string.byte(data, n)
		table.insert(out, enc[a // 4])
		table.insert(out, enc[(a % 4) * 16])
		if pad then
			table.insert(out, "==")
		end
	elseif rest == 2 then
		local a, b = string.byte(data, n - 1, n)
		local v = a * 256 + b
		table.insert(out, enc[v // 1024])
		table.insert(out, enc[(v // 16) % 64])
		table.insert(out, enc[(v % 16) * 4])
		if pad then
			table.insert(out, "=")
		end
	end
	return table.concat(out)
end

--- The decoded bytes, or nil when `text` isn't valid Base64 in the chosen alphabet.
function Base64.decode(text: string, options: Options?): string?
	local o: Options = options or {}
	local dec = if o.url then URL_DECODE else STANDARD_DECODE
	local n = #text
	-- Optional padding: at most two "=" at the end, and only where padding belongs.
	while n > 0 and string.byte(text, n) == PAD do
		n -= 1
	end
	if #text - n > 2 or (#text ~= n and #text % 4 ~= 0) then
		return nil
	end
	if n % 4 == 1 then
		return nil -- one leftover character can't hold a byte
	end
	-- Six-bit values of the unpadded text; any character outside the alphabet rejects it.
	local values: { number } = table.create(n)
	for i = 1, n do
		local v = dec[string.byte(text, i)]
		if v == nil then
			return nil
		end
		values[i] = v
	end
	local out: { string } = table.create(n // 4 + 1)
	local i = 1
	while i + 3 <= n do
		local v = ((values[i] * 64 + values[i + 1]) * 64 + values[i + 2]) * 64 + values[i + 3]
		table.insert(out, string.char(v // 65536, (v // 256) % 256, v % 256))
		i += 4
	end
	local rest = n - i + 1
	if rest == 2 then
		-- 12 bits hold one byte; the low 4 must be zero in a canonical encoding.
		local v = values[i] * 64 + values[i + 1]
		if v % 16 ~= 0 then
			return nil
		end
		table.insert(out, string.char(v // 16))
	elseif rest == 3 then
		-- 18 bits hold two bytes; the low 2 must be zero.
		local v = (values[i] * 64 + values[i + 1]) * 64 + values[i + 2]
		if v % 4 ~= 0 then
			return nil
		end
		table.insert(out, string.char(v // 1024, (v // 4) % 256))
	end
	return table.concat(out)
end

return Base64
