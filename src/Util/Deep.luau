--!strict
--[[
	Deep table helpers shared by framework modules.
]]

local Deep = {}

-- Structural copy of plain data. Metatables are not copied; cycles are preserved.
function Deep.copy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local seen: { [any]: any } = {}
	local function copy(source: any): any
		if type(source) ~= "table" then
			return source
		end
		local existing = seen[source]
		if existing then
			return existing
		end
		local result = {}
		seen[source] = result
		for key, child in source do
			result[key] = copy(child)
		end
		return result
	end
	return copy(value)
end

-- Freezes a table and every table inside it. Returns the same table.
function Deep.freeze<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local function freeze(t: any)
		if table.isfrozen(t) then
			return
		end
		for _, child in t do
			if type(child) == "table" then
				freeze(child)
			end
		end
		table.freeze(t)
	end
	freeze(value)
	return value
end

-- Deep structural equality for plain data.
function Deep.equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not Deep.equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- True when `t` is a table whose keys are exactly 1..n (an empty table counts as an array).
function Deep.isArray(t: { [any]: any }): boolean
	local count = 0
	for _ in t do
		count += 1
	end
	for index = 1, count do
		if t[index] == nil then
			return false
		end
	end
	return true
end

return Deep
