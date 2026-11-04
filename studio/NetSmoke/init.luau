--!strict
--[[
	NetSmoke: the shared half of the Studio smoke test for Net over real remotes
	(Net.RobloxTransport), which lune can't run. Both NetSmokeServer and NetSmokeClient require
	it; requiring it binds the "NetSmoke" namespace on that side.

	The server drives a list of steps over Step; the client does each one and answers on Report
	with its own checks and a done marker. See docs/TOOLING.md#studio-smoke-test-for-net.
]]

local Shared = require(script.Parent.Packages.RBLXShared)
local Probes = require("@self/Probes")

local Net = Shared.Net
local S = Net.Schema

local NetSmoke = {}

NetSmoke.Shared = Shared
NetSmoke.Probes = Probes
NetSmoke.NAMESPACE = "NetSmoke"
-- Raw remotes for the wire-rule probes live here, outside Net on purpose: the probes send
-- values Net's schemas would refuse.
NetSmoke.PROBE_FOLDER = "NetSmokeProbe"

-- What RobloxTransport should create for each remote below.
local EXPECTED_CLASSES: { [string]: string } = table.freeze({
	Step = "RemoteEvent",
	Report = "RemoteEvent",
	Ping = "RemoteEvent",
	Strict = "RemoteEvent",
	Lossy = "UnreliableRemoteEvent",
	Toggle = "RemoteEvent",
	Flood = "RemoteEvent",
	Echo = "RemoteFunction",
	Boom = "RemoteFunction",
	Slow = "RemoteFunction",
	Broadcast = "RemoteEvent",
	Burst = "UnreliableRemoteEvent",
})
NetSmoke.EXPECTED_CLASSES = EXPECTED_CLASSES

NetSmoke.Remotes = Net.namespace("NetSmoke", {
	-- Control: the server names a step; the client reports checks (with `check`) and then a done
	-- marker (without it) for that step.
	Step = Net.serverEvent(S.struct({ step = S.string({ maxLength = 32 }) })),
	Report = Net.clientEvent(
		S.struct({
			step = S.string({ maxLength = 32 }),
			check = S.optional(S.string({ maxLength = 120 })),
			ok = S.boolean(),
			detail = S.string({ maxLength = 500 }),
		}),
		{ rateLimit = { rate = 50, burst = 50 } }
	),

	-- Under test.
	Ping = Net.clientEvent(S.struct({ n = S.integer({ min = 0, max = 1000 }), text = S.string({ maxLength = 32 }) })),
	Strict = Net.clientEvent(S.number({ min = 0, max = 1 })),
	Lossy = Net.clientEvent(S.integer({ min = 1, max = 100 }), { unreliable = true }),
	Toggle = Net.clientEvent(S.integer({ min = 0, max = 100 })),
	Flood = Net.clientEvent(S.integer({ min = 0, max = 1000 }), { rateLimit = { rate = 5, burst = 5 } }),
	Echo = Net.clientFunction(S.string({ maxLength = 32 }), S.string({ maxLength = 64 })),
	Boom = Net.clientFunction(S.boolean(), S.boolean()),
	Slow = Net.clientFunction(S.number({ min = 0, max = 5 }), S.boolean()),
	Broadcast = Net.serverEvent(S.string({ maxLength = 32 })),
	Burst = Net.serverEvent(S.integer({ min = 1, max = 100 }), { unreliable = true }),
})

-- What the probes use on this side.
function NetSmoke.probeEnv(): Probes.Env
	return { instance = workspace, vector = Vector3.new(1, 2, 3) }
end

-- pcall that always hands back the error message. (Luau types pcall of a function with no
-- results as returning only the boolean.)
function NetSmoke.try(fn: (...any) -> ...any, ...: any): (boolean, string?)
	local results = table.pack(pcall(fn, ...))
	if results[1] then
		return true, nil
	end
	return false, tostring(results[2])
end

-- Polls `condition` every frame-ish until it holds or `seconds` pass.
function NetSmoke.waitFor(seconds: number, condition: () -> boolean): boolean
	local deadline = os.clock() + seconds
	while not condition() do
		if os.clock() >= deadline then
			return false
		end
		task.wait(0.05)
	end
	return true
end

return NetSmoke
