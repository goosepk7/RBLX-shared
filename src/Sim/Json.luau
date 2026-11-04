--!strict
--[[
	Deterministic JSON encoder (sorted object keys, stable number formatting) so sim outputs
	diff cleanly between runs. Encoding only; tools that read JSON use @lune/serde.

	Arrays are tables with keys 1..n and no others; empty tables encode as [] unless passed in
	Json.object({}). NaN and infinities are rejected (JSON cannot represent them).
]]

local Json = {}

local objectTags: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Marks a table to always encode as an object, even when empty.
function Json.object<T>(t: T): T
	objectTags[t] = true
	return t
end

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(s: string): string
	local escaped = string.gsub(s, '[%c"\\]', function(c: string): string
		return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. escaped .. '"'
end

local function encodeNumber(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		error("Json: cannot encode NaN or infinity")
	end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	-- Luau's tostring gives the shortest representation that round-trips.
	return tostring(n)
end

local function isArray(t: { [any]: any }): boolean
	if objectTags[t] then
		return false
	end
	local count = 0
	for key in t do
		if type(key) ~= "number" then
			return false
		end
		count += 1
	end
	for i = 1, count do
		if t[i] == nil then
			return false
		end
	end
	return true
end

local function encode(value: any, indent: string?, depth: number, seen: { [any]: boolean }): string
	local kind = type(value)
	if value == nil then
		return "null"
	elseif kind == "boolean" then
		return if value then "true" else "false"
	elseif kind == "number" then
		return encodeNumber(value)
	elseif kind == "string" then
		return encodeString(value)
	elseif kind == "table" then
		if seen[value] then
			error("Json: cannot encode a cyclic table")
		end
		seen[value] = true
		local newline = if indent then "\n" .. string.rep(indent, depth + 1) else ""
		local closing = if indent then "\n" .. string.rep(indent, depth) else ""
		local separator = if indent then ": " else ":"
		local out: { string } = {}
		local result: string
		if isArray(value) then
			if #value == 0 then
				seen[value] = nil
				return "[]"
			end
			for _, item in value do
				table.insert(out, newline .. encode(item, indent, depth + 1, seen))
			end
			result = "[" .. table.concat(out, ",") .. closing .. "]"
		else
			local keys: { string } = {}
			for key in value do
				if type(key) ~= "string" and type(key) ~= "number" then
					error("Json: object keys must be strings or numbers, got " .. type(key))
				end
				table.insert(keys, tostring(key))
			end
			table.sort(keys)
			if #keys == 0 then
				seen[value] = nil
				return "{}"
			end
			for _, key in keys do
				local child = value[key]
				if child == nil then
					child = value[tonumber(key)]
				end
				table.insert(out, newline .. encodeString(key) .. separator .. encode(child, indent, depth + 1, seen))
			end
			result = "{" .. table.concat(out, ",") .. closing .. "}"
		end
		seen[value] = nil
		return result
	end
	error("Json: cannot encode value of type " .. kind)
end

function Json.encode(value: any, pretty: boolean?): string
	return encode(value, if pretty then "  " else nil, 0, {})
end

return Json
