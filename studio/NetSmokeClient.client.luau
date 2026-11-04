--!strict
--[[
	NetSmokeClient: the client half of the Studio smoke test for Net. It does each step that
	NetSmokeServer names and reports what it saw; the verdict prints on the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local NetSmoke = require(ReplicatedStorage.NetSmoke)

local Shared = NetSmoke.Shared
local Net = Shared.Net
local Log = Shared.Util.Log
local Probes = NetSmoke.Probes
local Remotes = NetSmoke.Remotes
local waitFor = NetSmoke.waitFor

local function firstLine(text: string): string
	return string.split(text, "\n")[1]
end

local errorsLogged: { string } = {}
Log.setSink(function(entry)
	print(string.format("NET SMOKE  log   [%s] %s", entry.level, firstLine(entry.message)))
	if entry.level == "error" then
		table.insert(errorsLogged, firstLine(entry.message))
	end
end)

local function child(parent: Instance, name: string): Instance
	local found = parent:WaitForChild(name, 30)
	if found == nil then
		error(string.format("NetSmoke: %s.%s did not replicate within 30 s", parent:GetFullName(), name))
	end
	return found :: Instance
end

local namespaceFolder = child(child(ReplicatedStorage, Net.RobloxTransport.FOLDER_NAME), NetSmoke.NAMESPACE)
local probeFolder = child(ReplicatedStorage, NetSmoke.PROBE_FOLDER)
local probeUp = child(probeFolder, "Up") :: RemoteEvent
local probeDown = child(probeFolder, "Down") :: RemoteEvent
local probeReport = child(probeFolder, "Report") :: RemoteEvent

local currentStep = "ready"

local function report(check: string, ok: boolean, detail: string?)
	Remotes.Report:fire({ step = currentStep, check = check, ok = ok, detail = string.sub(detail or "", 1, 500) })
end

-- The server checks the same layout on its side; this proves it replicated.
do
	local wrong: { string } = {}
	for name, className in NetSmoke.EXPECTED_CLASSES do
		local remote = namespaceFolder:WaitForChild(name, 10)
		if remote == nil then
			table.insert(wrong, name .. " never replicated")
		elseif remote.ClassName ~= className then
			table.insert(wrong, name .. " is a " .. remote.ClassName)
		end
	end
	table.sort(wrong)
	report("every remote replicated with its class", #wrong == 0, table.concat(wrong, ", "))
end

local burstCount = 0
Remotes.Burst:connect(function(_index: number)
	burstCount += 1
end)

local broadcasts: { string } = {}
Remotes.Broadcast:connect(function(text: string)
	table.insert(broadcasts, text)
end)

probeDown.OnClientEvent:Connect(function(name: unknown, value: any) -- lint-ignore: remote-outside-net
	if type(name) == "string" then
		probeReport:FireServer("down", name, Probes.describe(value)) -- lint-ignore: remote-outside-net
	end
end)

local steps: { [string]: () -> () } = {}

function steps.ping()
	report("Ping:fire sends a valid payload", Remotes.Ping:fire({ n = 7, text = "hello" }))
end

-- A modified client: raw FireServer calls skip Net's client-side checks.
function steps.malformed()
	local strict = child(namespaceFolder, "Strict") :: RemoteEvent
	strict:FireServer("seven") -- lint-ignore: remote-outside-net
	strict:FireServer(0.5, "extra") -- lint-ignore: remote-outside-net
	strict:FireServer() -- lint-ignore: remote-outside-net
	strict:FireServer(0.25) -- lint-ignore: remote-outside-net
end

function steps.lossy()
	local sent = 0
	for index = 1, 5 do
		if Remotes.Lossy:fire(index) then
			sent += 1
		end
	end
	report("Lossy:fire sends on an UnreliableRemoteEvent", sent == 5, string.format("%d of 5 sent", sent))
end

function steps.burst()
	local arrived = waitFor(3, function()
		return burstCount >= 1
	end)
	report("unreliable server events arrive", arrived, string.format("%d of 5 arrived", burstCount))
end

function steps.functions()
	local echo: any = Remotes.Echo:invokeAsync("hi")
	report(
		"Echo:invokeAsync returns the handler's value",
		echo.ok == true and echo.value == "echo:hi",
		Probes.describe(echo)
	)

	local boom: any = Remotes.Boom:invokeAsync(true)
	report(
		'Boom:invokeAsync turns a handler error into "error"',
		boom.ok == false and boom.error == "error",
		Probes.describe(boom)
	)

	local started = os.clock()
	local slow: any = Remotes.Slow:invokeAsync(1, 0.3)
	local elapsed = os.clock() - started
	report(
		"Slow:invokeAsync gives up at its 0.3 s timeout",
		slow.ok == false and slow.error == "timeout" and elapsed < 0.9,
		string.format("%s after %.2f s", Probes.describe(slow), elapsed)
	)

	local echoRemote = child(namespaceFolder, "Echo") :: RemoteFunction
	local accepted, code = echoRemote:InvokeServer(42) -- lint-ignore: remote-outside-net
	report(
		'a raw invoke with a bad request gets false, "invalid"',
		accepted == false and code == "invalid",
		Probes.describe({ accepted, code })
	)
end

function steps.killOff()
	local toggle = child(namespaceFolder, "Toggle") :: RemoteEvent
	local replicated = waitFor(5, function()
		return toggle:GetAttribute(Net.RobloxTransport.DISABLED_ATTRIBUTE) == true
	end)
	report("the Disabled attribute replicated", replicated)
	report("Toggle:fire refuses while the remote is disabled", Remotes.Toggle:fire(1) == false)
	toggle:FireServer(2) -- lint-ignore: remote-outside-net
end

function steps.killOn()
	local toggle = child(namespaceFolder, "Toggle") :: RemoteEvent
	local cleared = waitFor(5, function()
		return toggle:GetAttribute(Net.RobloxTransport.DISABLED_ATTRIBUTE) == nil
	end)
	report("switching Toggle on cleared Disabled here", cleared)
	report("Toggle:fire sends again once switched on", Remotes.Toggle:fire(3) == true)
end

function steps.flood()
	local sent = 0
	for index = 1, 8 do
		if Remotes.Flood:fire(index) then
			sent += 1
		end
	end
	report("Flood:fire stops at the remote's burst of 5", sent == 5, string.format("%d of 8 sent", sent))
	local flood = child(namespaceFolder, "Flood") :: RemoteEvent
	for index = 1, 15 do
		flood:FireServer(100 + index) -- lint-ignore: remote-outside-net
	end
end

function steps.wrongWay()
	local broadcast = child(namespaceFolder, "Broadcast") :: RemoteEvent
	broadcast:FireServer("not allowed") -- lint-ignore: remote-outside-net
end

function steps.broadcast()
	local arrived = waitFor(3, function()
		return table.find(broadcasts, "hello everyone") ~= nil
	end)
	report("Broadcast:fireAll reached this client", arrived, Probes.describe(broadcasts))
end

function steps.probesUp()
	local env = NetSmoke.probeEnv()
	for _, probe in Probes.LIST do
		local ok, err = NetSmoke.try(probeUp.FireServer, probeUp, probe.name, probe.build(env))
		if not ok then
			probeReport:FireServer("up", probe.name, Probes.ERROR, err) -- lint-ignore: remote-outside-net
		end
	end
end

function steps.logs()
	report("Net logged no errors on the client", #errorsLogged == 0, table.concat(errorsLogged, " | "))
end

Remotes.Step:connect(function(payload: any)
	local name: string = payload.step
	currentStep = name
	local run = steps[name]
	if run == nil then
		report("knows the step " .. name, false, "this client has no such step")
	else
		local ok, err = NetSmoke.try(run)
		if not ok then
			report(name .. " ran without erroring", false, err)
		end
	end
	Remotes.Report:fire({ step = name, ok = true, detail = "" })
end)

Remotes.Report:fire({ step = "ready", ok = true, detail = "" })
