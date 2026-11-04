--!strict
--[[
	NetSmoke.Probes: payloads that exercise Roblox's remote argument rules, and a describer that
	turns whatever arrived into a string two sides can compare.

	The smoke sends each probe over a raw RemoteEvent in both directions and compares the
	description of what Roblox delivered with what Net.Loopback delivers for the same value. A
	mismatch means LoopbackTransport (and so every lune test of a remote) disagrees with the real
	wire for that kind of value.

	Pure Luau with no requires, so tests/Net/NetSmokeProbes.spec.luau runs it under lune.
]]

-- Values the probes need from the running side (an Instance both sides can see, a Vector3).
export type Env = {
	instance: any,
	vector: any?,
}

export type Probe = {
	name: string,
	-- The rule the probe checks, shown when it fails.
	rule: string,
	-- Informational probes report what Roblox did without passing or failing the run: the rule
	-- they look at is not one Net.Loopback claims to follow.
	info: boolean,
	build: (env: Env) -> any,
}

-- Passes a value through a wire and returns (true, delivered) or (false, error).
export type Copier = (value: any) -> (boolean, any)

local Probes = {}

-- The description used when sending the value raised an error.
Probes.ERROR = "error"

local LIST: { Probe } = {
	{
		name = "nested",
		rule = "arrays, dictionaries, numbers, strings, booleans, Instances and Vector3s arrive unchanged",
		info = false,
		build = function(env: Env): any
			return { list = { 1, 2, 3 }, map = { a = "x", b = true }, n = 1.5, inst = env.instance, v = env.vector }
		end,
	},
	{
		name = "shared",
		rule = "a table referenced twice arrives as two separate copies",
		info = false,
		build = function(_env: Env): any
			local inner = { 1 }
			return { a = inner, b = inner }
		end,
	},
	{
		name = "functions",
		rule = "functions arrive as nil",
		info = false,
		build = function(_env: Env): any
			return { keep = 1, fn = function() end }
		end,
	},
	{
		name = "threads",
		rule = "threads arrive as nil",
		info = false,
		build = function(_env: Env): any
			return { keep = 1, co = coroutine.create(function() end) }
		end,
	},
	{
		name = "keys",
		rule = "keys that are neither strings nor numbers arrive as strings",
		info = false,
		build = function(env: Env): any
			local keys: { [any]: string } = {}
			keys[true] = "boolean"
			keys[env.instance] = "instance"
			keys[{}] = "table"
			return keys
		end,
	},
	{
		name = "mixed",
		rule = "a table with both number and string keys keeps only its number keys",
		info = false,
		build = function(_env: Env): any
			-- selene: allow(mixed_table)
			return { 10, 20, extra = "dropped" }
		end,
	},
	{
		name = "metatable",
		rule = "metatables are stripped",
		info = false,
		build = function(_env: Env): any
			return setmetatable({ v = 1 }, {
				__index = function()
					return "from the metatable"
				end,
			})
		end,
	},
	{
		name = "cyclic",
		rule = "sending a table that contains itself errors",
		info = false,
		build = function(_env: Env): any
			local cycle: { [string]: any } = {}
			cycle.self = cycle
			return cycle
		end,
	},
	{
		name = "sparse",
		rule = "an array with a hole (not a documented rule; this records what Roblox does)",
		info = true,
		build = function(_env: Env): any
			return { [1] = "a", [3] = "c" }
		end,
	},
}

Probes.LIST = LIST

function Probes.get(name: string): Probe?
	for _, probe in LIST do
		if probe.name == name then
			return probe
		end
	end
	return nil
end

-- Memory addresses differ between the two sides and between runs.
local function normalize(text: string): string
	return (string.gsub(text, "0x%x+", "0x?"))
end

local KEY_RANK: { [string]: number } = { number = 1, string = 2 }

local function keyLabel(key: any): string
	local kind = typeof(key)
	if kind == "number" then
		return "[" .. tostring(key) .. "]"
	elseif kind == "string" then
		return "[" .. string.format("%q", normalize(key)) .. "]"
	end
	return "[<" .. kind .. ": " .. normalize(tostring(key)) .. ">]"
end

local function keyBefore(a: any, b: any): boolean
	local rankA, rankB = KEY_RANK[typeof(a)] or 3, KEY_RANK[typeof(b)] or 3
	if rankA ~= rankB then
		return rankA < rankB
	end
	if rankA == 1 or rankA == 2 then
		return a < b
	end
	return keyLabel(a) < keyLabel(b)
end

--[[
	A canonical string for a value: keys sorted, addresses blanked, `mt` before a table that has
	a metatable, and `<ref n>` where a table already described (the nth one) appears again, so
	shared references and cycles are visible and never recurse.

	  Probes.describe({ b = true, 10 })  --> {[1]=10, ["b"]=true}
]]
function Probes.describe(value: any): string
	local seen: { [any]: number } = {}
	local count = 0
	local function visit(current: any): string
		local kind = typeof(current)
		if kind == "nil" or kind == "boolean" or kind == "number" then
			return tostring(current)
		elseif kind == "string" then
			return string.format("%q", normalize(current))
		elseif kind == "Instance" then
			return "<Instance: " .. current:GetFullName() .. ">"
		elseif kind ~= "table" then
			return "<" .. kind .. ": " .. normalize(tostring(current)) .. ">"
		end
		local index = seen[current]
		if index then
			return "<ref " .. tostring(index) .. ">"
		end
		count += 1
		seen[current] = count
		local keys: { any } = {}
		for key in current do
			table.insert(keys, key)
		end
		table.sort(keys, keyBefore)
		local parts: { string } = {}
		for _, key in keys do
			table.insert(parts, keyLabel(key) .. "=" .. visit(current[key]))
		end
		local prefix = if getmetatable(current) ~= nil then "mt" else ""
		return prefix .. "{" .. table.concat(parts, ", ") .. "}"
	end
	return visit(value)
end

-- What `copy` delivers for the probe, described.
function Probes.expected(copy: Copier, probe: Probe, env: Env): string
	local ok, delivered = copy(probe.build(env))
	return if ok then Probes.describe(delivered) else Probes.ERROR
end

--[[
	A Copier that sends values through a Net.Loopback (pass Net.Loopback), the way a remote
	argument travels in lune tests.
]]
function Probes.viaLoopback(Loopback: any): Copier
	local loop = Loopback.new()
	local endpoint = loop.server:createEndpoint("NetSmokeProbe", "Copy", "event")
	local delivered: any = nil
	endpoint:onEvent(function(_player: any, ...: any)
		delivered = table.pack(...)
	end)
	return function(value: any): (boolean, any)
		delivered = nil
		local ok, err = pcall(loop.injectFromClient, loop, nil, "NetSmokeProbe.Copy", value)
		if not ok then
			return false, err
		end
		return true, if delivered then delivered[1] else nil
	end
end

return Probes
