--!strict
--[[
	Net.Schema: payload validators for remotes (§3.3: type, range, enum).

	  local S = Net.Schema
	  S.number({ min = 0, max = 1 })                -- finite numbers only, NaN/inf always rejected
	  S.integer({ min = 1, max = 10 })
	  S.string({ maxLength = 32 })                  -- valid UTF-8, <= maxLength bytes (default 256)
	  S.enum({ "wood", "steel", "carbon" })
	  S.struct({ item = S.string(), qty = S.integer({ min = 1, max = 99 }) })
	  S.array(S.integer(), { maxLength = 16 })
	  S.optional(S.vector3({ maxMagnitude = 5000 }))

	Every schema is a table with `check(value) -> (ok, reason?)`. Checks never error and do a
	bounded amount of work on hostile input (collections stop at their size limit).

	Typing: primitive schemas carry their Luau type (S.number() is Schema<number>). Structs,
	unions and custom schemas are Schema<any>; annotate them where you declare the remote:

	  local PurchaseRequest: Net.Schema<{ item: string, qty: number }> = S.struct({ ... })
]]

local Log = require("../Util/Log")

export type Schema<T> = {
	kind: string,
	-- Human-readable description used in rejection reasons, e.g. "integer[1, 10]".
	describe: string,
	check: (value: unknown) -> (boolean, string?),
	-- True when Schema.any() appears anywhere inside. Client-to-server remotes refuse such
	-- schemas unless they pass `allowAny = true`.
	containsAny: boolean,
	-- Phantom field carrying T for the type checker. Always nil at runtime.
	_type: T?,
}

export type NumberOptions = {
	min: number?,
	max: number?,
	integer: boolean?,
}

export type StringOptions = {
	minLength: number?,
	-- Maximum length in bytes. Default 256.
	maxLength: number?,
	-- Lua pattern the whole string must match (anchor it yourself: "^%w+$").
	pattern: string?,
}

export type ArrayOptions = {
	minLength: number?,
	-- Default 64.
	maxLength: number?,
}

export type MapOptions = {
	-- Default 64.
	maxEntries: number?,
}

export type StructOptions = {
	-- Accept keys that are not declared. Default false: unknown keys are malformed.
	allowExtra: boolean?,
}

export type InstanceOptions = {
	-- The instance must be a descendant of this (e.g. workspace). Strongly recommended.
	descendantOf: Instance?,
}

export type VectorOptions = {
	maxMagnitude: number?,
}

local DEFAULT_STRING_MAX = 256
local DEFAULT_COLLECTION_MAX = 64

local Schema = {}

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Short, log-safe description of a received value (never echoes long strings).
local function describeValue(value: any): string
	local kind = typeof(value)
	if kind == "number" then
		return "number " .. tostring(value)
	elseif kind == "string" then
		return "string (" .. tostring(#value) .. " bytes)"
	elseif kind == "boolean" then
		return tostring(value)
	end
	return kind
end

local function expected(describe: string, value: any): (boolean, string?)
	return false, "expected " .. describe .. ", got " .. describeValue(value)
end

local function rangeText(min: number?, max: number?): string
	if min == nil and max == nil then
		return ""
	end
	return "["
		.. (if min ~= nil then tostring(min) else "-inf")
		.. ", "
		.. (if max ~= nil then tostring(max) else "inf")
		.. "]"
end

local function make<T>(
	kind: string,
	describe: string,
	check: (value: any) -> (boolean, string?),
	containsAny: boolean?
): Schema<T>
	return table.freeze({
		kind = kind,
		describe = describe,
		check = check,
		containsAny = containsAny == true,
	}) :: any
end

local function anyInside(schemas: { Schema<any> }): boolean
	for _, schema in schemas do
		if schema.containsAny then
			return true
		end
	end
	return false
end

function Schema.number(options: NumberOptions?): Schema<number>
	local opts: NumberOptions = options or {}
	local min, max = opts.min, opts.max
	local integer = opts.integer == true
	assert(min == nil or isFinite(min), "Schema.number: min must be finite")
	assert(max == nil or isFinite(max), "Schema.number: max must be finite")
	assert(min == nil or max == nil or min <= max, "Schema.number: min is greater than max")
	local describe = (if integer then "integer" else "number") .. rangeText(min, max)
	return make("number", describe, function(value: any): (boolean, string?)
		if type(value) ~= "number" then
			return expected(describe, value)
		end
		if not isFinite(value) then
			return false, "expected finite " .. describe .. ", got " .. tostring(value)
		end
		if integer and value ~= math.floor(value) then
			return expected(describe, value)
		end
		if (min ~= nil and value < min) or (max ~= nil and value > max) then
			return false, "expected " .. describe .. ", got out-of-range " .. tostring(value)
		end
		return true, nil
	end)
end

function Schema.integer(options: NumberOptions?): Schema<number>
	local opts: NumberOptions = options or {}
	return Schema.number({ min = opts.min, max = opts.max, integer = true })
end

function Schema.string(options: StringOptions?): Schema<string>
	local opts: StringOptions = options or {}
	local minLength = opts.minLength or 0
	local maxLength = opts.maxLength or DEFAULT_STRING_MAX
	local pattern = opts.pattern
	assert(minLength >= 0 and maxLength >= minLength, "Schema.string: invalid length bounds")
	local describe = "string[" .. tostring(minLength) .. ".." .. tostring(maxLength) .. " bytes]"
	return make("string", describe, function(value: any): (boolean, string?)
		if type(value) ~= "string" then
			return expected(describe, value)
		end
		local length = #value
		if length < minLength or length > maxLength then
			return expected(describe, value)
		end
		if utf8.len(value) == nil then
			return false, "expected valid UTF-8 " .. describe
		end
		if pattern ~= nil and string.find(value, pattern) == nil then
			return false, "string does not match the required pattern"
		end
		return true, nil
	end)
end

function Schema.boolean(): Schema<boolean>
	return make("boolean", "boolean", function(value: any): (boolean, string?)
		if type(value) ~= "boolean" then
			return expected("boolean", value)
		end
		return true, nil
	end)
end

function Schema.literal<T>(literal: T): Schema<T>
	local describe = "literal " .. tostring(literal)
	return make("literal", describe, function(value: any): (boolean, string?)
		if value ~= literal then
			return expected(describe, value)
		end
		return true, nil
	end)
end

-- One of a fixed list of strings or numbers.
function Schema.enum<T>(values: { T }): Schema<T>
	assert(#values > 0, "Schema.enum: needs at least one value")
	local allowed: { [any]: boolean } = {}
	local names: { string } = {}
	for _, v in values do
		local kind = type(v)
		assert(kind == "string" or kind == "number" or kind == "boolean", "Schema.enum: values must be primitives")
		allowed[v] = true
		table.insert(names, tostring(v))
	end
	local describe = "one of {" .. table.concat(names, ", ") .. "}"
	return make("enum", describe, function(value: any): (boolean, string?)
		local kind = type(value)
		if (kind == "string" or kind == "number" or kind == "boolean") and allowed[value] then
			return true, nil
		end
		return expected(describe, value)
	end)
end

function Schema.optional<T>(inner: Schema<T>): Schema<T?>
	local describe = inner.describe .. "?"
	local check = inner.check
	return make("optional", describe, function(value: any): (boolean, string?)
		if value == nil then
			return true, nil
		end
		return check(value)
	end, inner.containsAny)
end

-- No payload: the remote takes no arguments.
function Schema.none(): Schema<nil>
	return make("none", "no payload", function(value: any): (boolean, string?)
		if value ~= nil then
			return expected("no payload", value)
		end
		return true, nil
	end)
end

-- Anything at all. Client-to-server remotes refuse it (anywhere in their payload schema) unless
-- they pass `allowAny = true`; prefer a precise schema.
function Schema.any(): Schema<any>
	return make("any", "any", function(_value: any): (boolean, string?)
		return true, nil
	end, true)
end

function Schema.array<T>(item: Schema<T>, options: ArrayOptions?): Schema<{ T }>
	local opts: ArrayOptions = options or {}
	local minLength = opts.minLength or 0
	local maxLength = opts.maxLength or DEFAULT_COLLECTION_MAX
	assert(minLength >= 0 and maxLength >= minLength, "Schema.array: invalid length bounds")
	local describe = "array<" .. item.describe .. ">[" .. tostring(minLength) .. ".." .. tostring(maxLength) .. "]"
	local check = item.check
	return make("array", describe, function(value: any): (boolean, string?)
		if type(value) ~= "table" then
			return expected(describe, value)
		end
		local count = 0
		for key in value do
			count += 1
			if count > maxLength then
				return false, "array longer than " .. tostring(maxLength)
			end
			if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
				return false, "array has a non-index key"
			end
		end
		if count < minLength then
			return false, "array shorter than " .. tostring(minLength)
		end
		for index = 1, count do
			local element = value[index]
			if element == nil then
				return false, "array has a hole at " .. tostring(index)
			end
			local ok, reason = check(element)
			if not ok then
				return false, "item " .. tostring(index) .. ": " .. tostring(reason)
			end
		end
		return true, nil
	end, item.containsAny)
end

function Schema.map<K, V>(key: Schema<K>, value: Schema<V>, options: MapOptions?): Schema<{ [K]: V }>
	local opts: MapOptions = options or {}
	local maxEntries = opts.maxEntries or DEFAULT_COLLECTION_MAX
	local describe = "map<" .. key.describe .. ", " .. value.describe .. ">[" .. tostring(maxEntries) .. "]"
	local checkKey, checkValue = key.check, value.check
	return make("map", describe, function(candidate: any): (boolean, string?)
		if type(candidate) ~= "table" then
			return expected(describe, candidate)
		end
		local count = 0
		for k, v in candidate do
			count += 1
			if count > maxEntries then
				return false, "map has more than " .. tostring(maxEntries) .. " entries"
			end
			local okKey, keyReason = checkKey(k)
			if not okKey then
				return false, "key: " .. tostring(keyReason)
			end
			local okValue, valueReason = checkValue(v)
			if not okValue then
				return false, "value at " .. describeValue(k) .. ": " .. tostring(valueReason)
			end
		end
		return true, nil
	end, key.containsAny or value.containsAny)
end

function Schema.struct(fields: { [string]: Schema<any> }, options: StructOptions?): Schema<any>
	local opts: StructOptions = options or {}
	local allowExtra = opts.allowExtra == true
	local names: { string } = {}
	local fieldList: { Schema<any> } = {}
	for name, field in fields do
		assert(type(name) == "string", "Schema.struct: field names must be strings")
		assert(
			type(field) == "table" and type(field.check) == "function",
			"Schema.struct: field " .. name .. " is not a schema"
		)
		table.insert(names, name)
		table.insert(fieldList, field)
	end
	table.sort(names)
	local parts: { string } = {}
	for _, name in names do
		table.insert(parts, name .. ": " .. fields[name].describe)
	end
	local describe = "{ " .. table.concat(parts, ", ") .. " }"
	return make("struct", describe, function(value: any): (boolean, string?)
		if type(value) ~= "table" then
			return expected("struct", value)
		end
		if not allowExtra then
			-- Stops at the first undeclared key, so a hostile table costs at most (fields + 1) steps.
			for key in value do
				if type(key) ~= "string" or fields[key] == nil then
					return false, "unexpected field " .. describeValue(key)
				end
			end
		end
		for _, name in names do
			local ok, reason = fields[name].check(value[name])
			if not ok then
				return false, "field '" .. name .. "': " .. tostring(reason)
			end
		end
		return true, nil
	end, anyInside(fieldList))
end

-- Valid when any of the given schemas accepts the value.
function Schema.union(...: Schema<any>): Schema<any>
	local options = { ... }
	assert(#options >= 2, "Schema.union: needs at least two schemas")
	local parts: { string } = {}
	for _, option in options do
		table.insert(parts, option.describe)
	end
	local describe = table.concat(parts, " | ")
	return make("union", describe, function(value: any): (boolean, string?)
		for _, option in options do
			if option.check(value) then
				return true, nil
			end
		end
		return expected(describe, value)
	end, anyInside(options))
end

function Schema.instance(className: string?, options: InstanceOptions?): Schema<Instance>
	local opts: InstanceOptions = options or {}
	local ancestor = opts.descendantOf
	local describe = "Instance" .. (if className then "<" .. className .. ">" else "")
	return make("instance", describe, function(value: any): (boolean, string?)
		if typeof(value) ~= "Instance" then
			return expected(describe, value)
		end
		if className ~= nil and not value:IsA(className) then
			return false, "expected " .. describe .. ", got " .. value.ClassName
		end
		if ancestor ~= nil and not value:IsDescendantOf(ancestor) then
			return false, "instance is outside the allowed container"
		end
		return true, nil
	end)
end

function Schema.vector3(options: VectorOptions?): Schema<Vector3>
	local opts: VectorOptions = options or {}
	local maxMagnitude = opts.maxMagnitude
	local describe = "Vector3" .. (if maxMagnitude then "[|v| <= " .. tostring(maxMagnitude) .. "]" else "")
	return make("vector3", describe, function(value: any): (boolean, string?)
		if typeof(value) ~= "Vector3" then
			return expected(describe, value)
		end
		if not (isFinite(value.X) and isFinite(value.Y) and isFinite(value.Z)) then
			return false, "Vector3 has a non-finite component"
		end
		if maxMagnitude ~= nil and value.Magnitude > maxMagnitude then
			return false, "Vector3 magnitude " .. tostring(value.Magnitude) .. " exceeds " .. tostring(maxMagnitude)
		end
		return true, nil
	end)
end

function Schema.vector2(options: VectorOptions?): Schema<Vector2>
	local opts: VectorOptions = options or {}
	local maxMagnitude = opts.maxMagnitude
	local describe = "Vector2" .. (if maxMagnitude then "[|v| <= " .. tostring(maxMagnitude) .. "]" else "")
	return make("vector2", describe, function(value: any): (boolean, string?)
		if typeof(value) ~= "Vector2" then
			return expected(describe, value)
		end
		if not (isFinite(value.X) and isFinite(value.Y)) then
			return false, "Vector2 has a non-finite component"
		end
		if maxMagnitude ~= nil and value.Magnitude > maxMagnitude then
			return false, "Vector2 magnitude exceeds " .. tostring(maxMagnitude)
		end
		return true, nil
	end)
end

function Schema.cframe(options: VectorOptions?): Schema<CFrame>
	local opts: VectorOptions = options or {}
	local maxMagnitude = opts.maxMagnitude
	local describe = "CFrame"
	return make("cframe", describe, function(value: any): (boolean, string?)
		if typeof(value) ~= "CFrame" then
			return expected(describe, value)
		end
		for _, component in { value:GetComponents() } do
			if not isFinite(component) then
				return false, "CFrame has a non-finite component"
			end
		end
		if maxMagnitude ~= nil and value.Position.Magnitude > maxMagnitude then
			return false, "CFrame position exceeds " .. tostring(maxMagnitude)
		end
		return true, nil
	end)
end

function Schema.color3(): Schema<Color3>
	return make("color3", "Color3", function(value: any): (boolean, string?)
		if typeof(value) ~= "Color3" then
			return expected("Color3", value)
		end
		for _, channel in { value.R, value.G, value.B } do
			if not isFinite(channel) or channel < 0 or channel > 1 then
				return false, "Color3 channel out of range"
			end
		end
		return true, nil
	end)
end

-- An item of one Roblox enum, e.g. Schema.enumItem(Enum.KeyCode). Pass the Enum at call time.
function Schema.enumItem(enumType: Enum): Schema<EnumItem>
	local describe = "EnumItem<" .. tostring(enumType) .. ">"
	return make("enumItem", describe, function(value: any): (boolean, string?)
		if typeof(value) ~= "EnumItem" or value.EnumType ~= enumType then
			return expected(describe, value)
		end
		return true, nil
	end)
end

-- Escape hatch for checks the built-ins cannot express. `check` must not error or yield; if it
-- does, that is a bug in the check, so it is reported and the value is rejected.
function Schema.custom(describe: string, check: (value: any) -> (boolean, string?)): Schema<any>
	return make("custom", describe, function(value: any): (boolean, string?)
		local ok, valid, reason = pcall(check, value)
		if not ok then
			Log.error("Net.Schema", "custom check '" .. describe .. "' errored: " .. tostring(valid))
			return false, "custom check errored"
		end
		if valid then
			return true, nil
		end
		return false, reason or ("failed " .. describe)
	end)
end

-- Convenience: validate a value against a schema.
function Schema.validate<T>(schema: Schema<T>, value: unknown): (boolean, string?)
	return schema.check(value)
end

-- True when `value` looks like a schema built by this module.
function Schema.isSchema(value: any): boolean
	return type(value) == "table" and type(value.kind) == "string" and type(value.check) == "function"
end

return Schema
