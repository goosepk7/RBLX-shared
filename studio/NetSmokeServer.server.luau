--!strict
--[[
	NetSmokeServer: drives the Studio smoke test for Net over real remotes.

	Open NetSmoke.rbxl (built from studio/netsmoke.project.json) and press Play. Run (F8) starts
	no client, so the test waits and then fails. The Output ends with "NET SMOKE: PASS (n checks)"
	or a FAIL summary that names each failed check, and the verdict is left in workspace's
	"NetSmoke" attribute. Lines starting "NET SMOKE  log" are Net's own reports, expected ones
	included (the Boom handler error, the kill switch warning).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetSmoke = require(ReplicatedStorage.NetSmoke)

local Shared = NetSmoke.Shared
local Net = Shared.Net
local Log = Shared.Util.Log
local AntiExploit = Shared.AntiExploit
local Probes = NetSmoke.Probes
local Remotes = NetSmoke.Remotes
local waitFor = NetSmoke.waitFor

type RemoteMetrics = typeof(Net.getMetrics()[""])
type LogEntry = { level: "info" | "warn" | "error", scope: string, message: string }
type Outcome = { description: string, err: string? }

local function firstLine(text: string): string
	return string.split(text, "\n")[1]
end

local logged: { LogEntry } = {}
Log.setSink(function(entry)
	table.insert(logged, entry)
	print(string.format("NET SMOKE  log   [%s] %s", entry.level, firstLine(entry.message)))
end)

--[[ Raw probe remotes. The client looks for them by name. ]]

local function rawRemote(name: string, parent: Instance): RemoteEvent
	local remote = Instance.new("RemoteEvent") -- lint-ignore: remote-outside-net
	remote.Name = name
	remote.Parent = parent
	return remote
end

local probeFolder = Instance.new("Folder")
probeFolder.Name = NetSmoke.PROBE_FOLDER
local probeUp = rawRemote("Up", probeFolder)
local probeDown = rawRemote("Down", probeFolder)
local probeReport = rawRemote("Report", probeFolder)
probeFolder.Parent = ReplicatedStorage

--[[ Results ]]

type Result = { name: string, ok: boolean, detail: string }
local results: { Result } = {}

local function check(name: string, ok: boolean, detail: string?)
	local text = detail or ""
	table.insert(results, { name = name, ok = ok, detail = text })
	if ok then
		print("NET SMOKE  ok    " .. name)
	else
		warn("NET SMOKE  FAIL  " .. name .. (if text ~= "" then " (" .. text .. ")" else ""))
	end
end

local function metrics(remote: string): RemoteMetrics
	return Net.getMetrics()[NetSmoke.NAMESPACE .. "." .. remote]
end

local function counts(m: RemoteMetrics): string
	local dropped = m.dropped
	return string.format(
		"received %d, accepted %d, malformed %d, rate limited %d, disabled %d, wrong direction %d, handler errors %d",
		m.received,
		m.accepted,
		dropped.malformed,
		dropped.rateLimited,
		dropped.disabled,
		dropped.wrongDirection,
		m.handlerErrors
	)
end

local function strikes(player: Player, category: string): number
	local record = AntiExploit.default():getRecord(player)
	return if record then record.byCategory[category] or 0 else 0
end

local function wasLogged(level: string, text: string): boolean
	for _, entry in logged do
		if entry.level == level and string.find(entry.message, text, 1, true) then
			return true
		end
	end
	return false
end

--[[ What arrives. Only the first client to report is under test. ]]

local testPlayer: Player? = nil
local done: { [string]: boolean } = {}

Remotes.Report:connect(function(player: Player, report: any)
	if testPlayer == nil then
		testPlayer = player
	end
	if player ~= testPlayer then
		return
	end
	if report.check ~= nil then
		check("client: " .. report.check, report.ok, report.detail)
	else
		done[report.step] = true
	end
end)

local arrivals: { [string]: { any } } = { Ping = {}, Strict = {}, Lossy = {}, Toggle = {}, Flood = {} }

local function collect(name: string): (Player, any) -> ()
	return function(player: Player, payload: any)
		if player == testPlayer then
			table.insert(arrivals[name], payload)
		end
	end
end

Remotes.Ping:connect(collect("Ping"))
Remotes.Strict:connect(collect("Strict"))
Remotes.Lossy:connect(collect("Lossy"))
Remotes.Toggle:connect(collect("Toggle"))
Remotes.Flood:connect(collect("Flood"))

Remotes.Echo:handle(function(_player: Player, text: string): string
	return "echo:" .. text
end)

Remotes.Boom:handle(function(_player: Player, explode: boolean): boolean
	if explode then
		error('boom (expected: the smoke checks that a handler error reaches the client as "error")')
	end
	return false
end)

Remotes.Slow:handle(function(_player: Player, seconds: number): boolean
	task.wait(seconds)
	return true
end)

local outcomes: { up: { [string]: Outcome }, down: { [string]: Outcome } } = { up = {}, down = {} }

probeUp.OnServerEvent:Connect(function(player: Player, name: unknown, value: any) -- lint-ignore: remote-outside-net
	if player == testPlayer and type(name) == "string" then
		outcomes.up[name] = { description = Probes.describe(value) }
	end
end)

-- The client reports what arrived from the server, and probes it could not send at all.
probeReport.OnServerEvent:Connect( -- lint-ignore: remote-outside-net
	function(player: Player, direction: unknown, name: unknown, description: unknown, err: unknown)
		if player ~= testPlayer or type(name) ~= "string" or type(description) ~= "string" then
			return
		end
		local bucket = if direction == "up" then outcomes.up elseif direction == "down" then outcomes.down else nil
		if bucket then
			bucket[name] = { description = description, err = if type(err) == "string" then err else nil }
		end
	end
)

--[[ Steps ]]

local function step(player: Player, name: string, seconds: number?): boolean
	local limit = seconds or 10
	done[name] = nil
	Remotes.Step:fire(player, { step = name })
	local finished = waitFor(limit, function()
		return done[name] == true
	end)
	if not finished then
		check(name .. ": the client finished the step", false, string.format("no answer within %d s", limit))
	end
	return finished
end

local function count(map: { [string]: any }): number
	local total = 0
	for _ in map do
		total += 1
	end
	return total
end

local function compareProbes(direction: string, bucket: { [string]: Outcome })
	local copy = Probes.viaLoopback(Net.Loopback)
	local env = NetSmoke.probeEnv()
	for _, probe in Probes.LIST do
		local label = string.format("wire, %s: %s", direction, probe.name)
		local expected = Probes.expected(copy, probe, env)
		local outcome = bucket[probe.name]
		if outcome == nil then
			check(label .. " arrived", false, "nothing arrived; Net.Loopback delivers " .. expected)
			continue
		end
		local actual = outcome.description
		local detail = string.format("Roblox delivered %s; Net.Loopback delivers %s", actual, expected)
		if outcome.err then
			detail ..= " (send error: " .. firstLine(outcome.err) .. ")"
		end
		if probe.info then
			print(
				string.format(
					"NET SMOKE  info  %s (%s): %s",
					label,
					if actual == expected then "same" else "differs",
					detail
				)
			)
		else
			check(string.format("%s matches Net.Loopback: %s", label, probe.rule), actual == expected, detail)
		end
	end
end

local function layout()
	local netFolder = ReplicatedStorage:FindFirstChild(Net.RobloxTransport.FOLDER_NAME)
	local namespaceFolder = if netFolder then netFolder:FindFirstChild(NetSmoke.NAMESPACE) else nil
	local wrong: { string } = {}
	for name, className in NetSmoke.EXPECTED_CLASSES do
		local remote = if namespaceFolder then namespaceFolder:FindFirstChild(name) else nil
		if remote == nil then
			table.insert(wrong, name .. " is missing")
		elseif remote.ClassName ~= className then
			table.insert(wrong, name .. " is a " .. remote.ClassName)
		end
	end
	table.sort(wrong)
	check(
		string.format(
			"server: every remote exists under ReplicatedStorage.%s.%s with its class",
			Net.RobloxTransport.FOLDER_NAME,
			NetSmoke.NAMESPACE
		),
		#wrong == 0,
		table.concat(wrong, ", ")
	)
end

local function run(player: Player)
	-- A valid event, through Net on both sides.
	step(player, "ping")
	waitFor(3, function()
		return #arrivals.Ping >= 1
	end)
	local ping = arrivals.Ping[1]
	check(
		"server: Ping arrived once, from this player, with its payload",
		#arrivals.Ping == 1 and type(ping) == "table" and ping.n == 7 and ping.text == "hello",
		Probes.describe(arrivals.Ping)
	)

	-- A modified client: wrong type, an extra argument, no argument, then one valid payload.
	step(player, "malformed")
	waitFor(3, function()
		return metrics("Strict").received >= 4
	end)
	local strict = metrics("Strict")
	check(
		"server: the three malformed Strict payloads were dropped and the valid one delivered",
		strict.received == 4
			and strict.dropped.malformed == 3
			and strict.accepted == 1
			and #arrivals.Strict == 1
			and arrivals.Strict[1] == 0.25,
		counts(strict)
	)
	check(
		"server: each malformed payload struck the sender",
		strikes(player, "net.malformed") == 3,
		string.format("%d net.malformed strikes", strikes(player, "net.malformed"))
	)
	check(
		"server: three strikes flagged the player (the default registry does not kick)",
		AntiExploit.default():isFlagged(player)
	)

	-- UnreliableRemoteEvent both ways. Drops are allowed; none arriving is not.
	step(player, "lossy")
	local lossyArrived = waitFor(3, function()
		return #arrivals.Lossy >= 1
	end)
	check("server: unreliable client events arrive", lossyArrived, string.format("%d of 5 arrived", #arrivals.Lossy))
	for index = 1, 5 do
		Remotes.Burst:fire(player, index)
	end
	step(player, "burst")

	-- Functions: a value, a handler error, a timeout, and a raw invoke with a bad request.
	step(player, "functions", 15)
	local boom = metrics("Boom")
	check("server: Boom's handler error was counted", boom.handlerErrors == 1, counts(boom))
	check("server: Boom's handler error was logged", wasLogged("error", "NetSmoke.Boom handler errored"))
	local echo = metrics("Echo")
	check(
		"server: the raw invoke with a bad request was dropped as malformed",
		echo.accepted == 1 and echo.dropped.malformed == 1,
		counts(echo)
	)

	-- Kill switch: off, then on again.
	Net.setEnabled("NetSmoke.Toggle", false, "smoke test")
	local netFolder = ReplicatedStorage:FindFirstChild(Net.RobloxTransport.FOLDER_NAME)
	local namespaceFolder = if netFolder then netFolder:FindFirstChild(NetSmoke.NAMESPACE) else nil
	local toggle = if namespaceFolder then namespaceFolder:FindFirstChild("Toggle") else nil
	check(
		"server: switching Toggle off sets its Disabled attribute",
		toggle ~= nil and toggle:GetAttribute(Net.RobloxTransport.DISABLED_ATTRIBUTE) == true
	)
	step(player, "killOff")
	waitFor(3, function()
		return metrics("Toggle").dropped.disabled >= 1
	end)
	local off = metrics("Toggle")
	check(
		"server: traffic on a disabled remote is dropped before its handler",
		off.dropped.disabled == 1 and #arrivals.Toggle == 0,
		counts(off)
	)
	Net.setEnabled("NetSmoke.Toggle", true)
	check(
		"server: switching Toggle on clears Disabled",
		toggle ~= nil and toggle:GetAttribute(Net.RobloxTransport.DISABLED_ATTRIBUTE) == nil
	)
	step(player, "killOn")
	waitFor(3, function()
		return #arrivals.Toggle >= 1
	end)
	check(
		"server: Toggle delivers again once switched on",
		#arrivals.Toggle == 1 and arrivals.Toggle[1] == 3,
		Probes.describe(arrivals.Toggle)
	)

	-- Rate limit: the client stops itself at the burst; a raw flood is dropped on the server.
	step(player, "flood")
	waitFor(3, function()
		return metrics("Flood").received >= 20
	end)
	local flood = metrics("Flood")
	check(
		"server: the rate limit admits about one burst of the flood and drops the rest",
		flood.received >= 20
			and flood.accepted >= 5
			and flood.accepted <= 8
			and flood.dropped.rateLimited == flood.received - flood.accepted
			and #arrivals.Flood == flood.accepted,
		counts(flood)
	)

	-- A client firing a server-to-client remote.
	step(player, "wrongWay")
	waitFor(3, function()
		return metrics("Broadcast").dropped.wrongDirection >= 1
	end)
	local broadcast = metrics("Broadcast")
	check(
		"server: a client firing a server-to-client remote is dropped and struck",
		broadcast.dropped.wrongDirection == 1 and strikes(player, "net.wrongDirection") == 1,
		counts(broadcast)
	)

	Remotes.Broadcast:fireAll("hello everyone")
	step(player, "broadcast")
	check("server: Broadcast counted its send", metrics("Broadcast").sent == 1, counts(metrics("Broadcast")))

	-- Roblox's argument rules against Net.Loopback's, client to server...
	step(player, "probesUp")
	waitFor(5, function()
		return count(outcomes.up) >= #Probes.LIST
	end)
	compareProbes("client to server", outcomes.up)

	-- ...and server to client.
	local env = NetSmoke.probeEnv()
	for _, probe in Probes.LIST do
		local ok, err = NetSmoke.try(probeDown.FireClient, probeDown, player, probe.name, probe.build(env))
		if not ok then
			outcomes.down[probe.name] = { description = Probes.ERROR, err = err }
		end
	end
	waitFor(5, function()
		return count(outcomes.down) >= #Probes.LIST
	end)
	compareProbes("server to client", outcomes.down)

	step(player, "logs")
	local unexpected: { string } = {}
	for _, entry in logged do
		if entry.level == "error" and not string.find(entry.message, "NetSmoke.Boom handler errored", 1, true) then
			table.insert(unexpected, firstLine(entry.message))
		end
	end
	check("server: Net logged no errors besides Boom's", #unexpected == 0, table.concat(unexpected, " | "))
end

local function finish()
	local failed: { string } = {}
	for _, result in results do
		if not result.ok then
			table.insert(failed, result.name)
		end
	end
	workspace:SetAttribute("NetSmoke", if #failed == 0 then "PASS" else "FAIL")
	if #failed == 0 then
		print(string.format("NET SMOKE: PASS (%d checks)", #results))
	else
		warn(string.format("NET SMOKE: FAIL (%d of %d checks failed)", #failed, #results))
		for _, name in failed do
			warn("NET SMOKE:   " .. name)
		end
	end
	Log.setSink(nil)
end

local function main()
	print("NET SMOKE  waiting for a client (press Play; Run starts no client)")
	layout()
	local ready = waitFor(60, function()
		return done.ready == true
	end)
	local player = testPlayer
	if not ready or player == nil then
		check("a client loaded the remotes and reported ready", false, "no client reported within 60 s")
	else
		run(player)
	end
	finish()
end

main()
