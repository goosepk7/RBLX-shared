--!strict
--[[
	Data.Serialize: checks that a value can be stored in a DataStore, and estimates its size.

	DataStores keep JSON. A value that JSON can't represent faithfully either errors on save or
	is silently changed, so Data checks every profile before writing it and reports the exact
	path of the first problem:

	  local ok, path, reason = Serialize.check(profile.data)
	  -- false, "data.inventory[3]", "Vector3 can't be stored; save its X, Y, Z numbers"

	Storable: nil, booleans, finite numbers, valid UTF-8 strings, arrays (keys 1..n with no
	holes) and dictionaries with UTF-8 string keys, nested to any depth without cycles.
]]

local Serialize = {}

-- Roblox's per-key limit (characters of encoded JSON). The sizes check() estimates leave out JSON
-- escapes (a quote or control character in a string takes 2 to 6 characters), so they run low:
-- don't trust one near this limit. Data warns at half of it.
Serialize.MAX_SIZE = 4_194_303

local function isArray(t: { [any]: any }): (boolean, number)
	local count = 0
	for _ in t do
		count += 1
	end
	for index = 1, count do
		if t[index] == nil then
			return false, count
		end
	end
	return true, count
end

local function describeKey(key: any): string
	if type(key) == "string" then
		return key
	end
	return "[" .. tostring(key) .. "]"
end

--[[
	Returns (true, nil, nil, size) for a storable value, otherwise (false, path, reason, nil).
	`size` approximates the encoded JSON length in characters (escapes are not counted).
]]
function Serialize.check(value: any, rootName: string?): (boolean, string?, string?, number?)
	local onPath: { [any]: boolean } = {}
	local failedPath: string? = nil
	local failedReason: string? = nil

	local function fail(path: string, reason: string): number
		if failedPath == nil then
			failedPath = path
			failedReason = reason
		end
		return 0
	end

	local function walk(current: any, path: string): number
		if failedPath ~= nil then
			return 0
		end
		local kind = typeof(current)
		if kind == "nil" then
			return 4
		elseif kind == "boolean" then
			return if current then 4 else 5
		elseif kind == "number" then
			if current ~= current then
				return fail(path, "NaN can't be stored")
			elseif current == math.huge or current == -math.huge then
				return fail(path, "infinity can't be stored")
			end
			return #tostring(current)
		elseif kind == "string" then
			if utf8.len(current) == nil then
				return fail(path, "string is not valid UTF-8 (DataStores reject it)")
			end
			return #current + 2
		elseif kind == "table" then
			if onPath[current] then
				return fail(path, "table contains itself")
			end
			if getmetatable(current) ~= nil then
				return fail(path, "table has a metatable, which DataStores drop")
			end
			onPath[current] = true
			local array, count = isArray(current)
			local size = 2
			if array then
				for index = 1, count do
					size += walk(current[index], path .. "[" .. tostring(index) .. "]") + 1
				end
			else
				for key, child in current do
					if type(key) ~= "string" then
						onPath[current] = nil
						return fail(
							path,
							"table mixes array and dictionary keys, has holes, or has a non-string key ("
								.. describeKey(key)
								.. ")"
						)
					end
					if utf8.len(key) == nil then
						onPath[current] = nil
						return fail(path, "has a key that is not valid UTF-8 (DataStores reject it)")
					end
					size += #key + 3 + walk(child, path .. "." .. key) + 1
				end
			end
			onPath[current] = nil
			return size
		elseif kind == "Vector3" or kind == "Vector2" or kind == "CFrame" or kind == "Color3" then
			return fail(path, kind .. " can't be stored; save its components as numbers")
		elseif kind == "Instance" then
			return fail(path, "Instances can't be stored; save an id or name instead")
		elseif kind == "EnumItem" then
			return fail(path, "EnumItems can't be stored; save the item's Name")
		end
		return fail(path, kind .. " can't be stored")
	end

	local size = walk(value, rootName or "value")
	if failedPath ~= nil then
		return false, failedPath, failedReason, nil
	end
	return true, nil, nil, size
end

-- Approximate encoded size in characters, or nil when the value can't be stored.
function Serialize.estimateSize(value: any): number?
	local ok, _, _, size = Serialize.check(value)
	return if ok then size else nil
end

return Serialize
