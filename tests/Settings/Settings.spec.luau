--!strict
local AntiExploit = require("@shared/AntiExploit")
local Hooks = require("@shared/UI/Hooks")
local Log = require("@shared/Util/Log")
local Net = require("@shared/Net")
local Settings = require("@shared/Settings")
local Strings = require("@shared/Strings")
local T = require("@shared/Test")
local Theme = require("@shared/UI/Theme")
local World = require("../Data/World")

local expect = T.expect

local restoreLog: () -> () = function() end
T.beforeEach(function()
	local _
	_, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
	Theme.setPalette("off")
	Hooks.setHapticsEnabled(true)
end)

local function fakeAudio()
	local volumes: { [string]: number } = {}
	return {
		volumes = volumes,
		setVolume = function(_self: any, name: string, v: number)
			volumes[name] = v
		end,
	}
end

local function setup(schema: Settings.Schema?)
	local world = World.new()
	local server = world:server("A")
	local loop = Net.Loopback.new()
	local registry = AntiExploit.newRegistry({
		now = function()
			return world.clock:now()
		end,
	})
	local serverCtx = Net.newContext({
		side = "server",
		transport = loop.server,
		task = world.clock.task,
		clock = function()
			return world.clock:clock()
		end,
		strikes = registry,
	})
	local s = schema or Settings.schema()
	local settingsServer = Settings.Server.new({ store = server.store, schema = s, context = serverCtx })
	server.store:bindPlayers()

	local function join(userId: number)
		local player = server:join(userId)
		local audio = fakeAudio()
		local vfx = { scale = 1, flashes = true }
		function vfx.setShakeScale(_self: any, v: number)
			vfx.scale = v
		end
		function vfx.setFlashesEnabled(_self: any, v: boolean)
			vfx.flashes = v
		end
		local clientCtx = Net.newContext({
			side = "client",
			transport = loop:connect(player),
			task = world.clock.task,
			clock = function()
				return world.clock:clock()
			end,
		})
		local client = Settings.Client.new({
			schema = s,
			context = clientCtx,
			audio = audio,
			vfx = vfx,
			task = world.clock.task,
		})
		return player, client, audio, vfx
	end

	return world, server, settingsServer, join, loop
end

T.describe("Settings.schema", function()
	T.it("validates and snaps values per kind", function()
		local schema = Settings.schema()
		expect({ schema:validate("musicVolume", 0.33) } :: { any }).toEqual({ true, 0.35 } :: { any })
		expect({ schema:validate("musicVolume", 7) } :: { any }).toEqual({ true, 1 } :: { any })
		expect((schema:validate("musicVolume", 0 / 0))).toBe(false)
		expect((schema:validate("flashes", "yes"))).toBe(false)
		expect((schema:validate("colorblind", "protanopia"))).toBe(true)
		expect((schema:validate("colorblind", "sepia"))).toBe(false)
		expect((schema:validate("nope", true))).toBe(false)
	end)

	T.it("normalizes saved data: drops unknown keys, resets bad values, fills missing", function()
		local schema = Settings.schema()
		local values, changed = schema:normalize({ musicVolume = 0.2, colorblind = "sepia", old = 1 })
		expect(changed).toBe(true)
		expect(values.musicVolume).toBe(0.2)
		expect(values.colorblind).toBe("off")
		expect(values.old).toBeNil()
		expect(values.flashes).toBe(true)
		local again, changedAgain = schema:normalize(values)
		expect(again).toEqual(values)
		expect(changedAgain).toBe(false)
	end)

	T.it("lets a game set control options, add settings and remove built-ins", function()
		local schema = Settings.schema({
			override = { controls = { options = { "classic", "tap" } } },
			add = { { id = "autoSprint", kind = "toggle", default = false, section = "game" } :: any },
			remove = { "uiSounds" },
		})
		expect(schema.byId.controls.default).toBe("classic")
		expect(schema.byId.autoSprint).toBeTruthy()
		expect(schema.byId.uiSounds).toBeNil()
		expect(function()
			Settings.schema({ override = { nope = { default = 1 } } })
		end).toThrow("unknown setting")
		expect(function()
			Settings.schema({
				add = { { id = "x", kind = "choice", default = "a", options = { "b" }, section = "game" } :: any },
			})
		end).toThrow("default must be one of its options")
	end)
end)

T.describe("Settings server and client", function()
	T.it("sends saved settings on load and applies them on the client", function()
		local world, _server, _settings, join = setup()
		world:seed(1, World.document({ coins = 0, inventory = {}, settings = { musicVolume = 0.2, flashes = false } }))
		local _player, client, audio, vfx = join(1)
		world.clock:advance(1)
		expect(client:isReady()).toBe(true)
		expect(client:get("musicVolume")).toBe(0.2)
		expect(audio.volumes.music).toBe(0.2)
		expect(vfx.flashes).toBe(false)
	end)

	T.it("applies a change at once and saves it after the value settles", function()
		local world, server, settings, join = setup()
		local player, client, audio = join(1)
		world.clock:advance(1)
		for _, v in { 0.1, 0.2, 0.3, 0.4 } do
			client:set("musicVolume", v)
			world.clock:advance(0.1)
		end
		expect(audio.volumes.music).toBe(0.4)
		expect(settings:get(player, "musicVolume")).toBe(0.6) -- not sent yet
		world.clock:advance(0.5)
		expect(settings:get(player, "musicVolume")).toBe(0.4)
		server:leave(player)
		world.clock:advance(1)
		expect(world:stored(1).data.settings.musicVolume).toBe(0.4)
	end)

	T.it("routes comfort and accessibility settings", function()
		local world, _server, _settings, join = setup()
		local _player, client, audio, vfx = join(1)
		world.clock:advance(1)
		client:set("cameraShake", 0)
		client:set("uiSounds", false)
		client:set("haptics", false)
		client:set("colorblind", "deuteranopia")
		expect(vfx.scale).toBe(0)
		expect(audio.volumes.ui).toBe(0)
		expect(Theme.getPalette()).toBe("deuteranopia")
		client:set("sfxVolume", 0.5)
		expect(audio.volumes.sfx).toBe(0.5)
		expect(audio.volumes.ui).toBe(0) -- UI sounds stay off
		client:set("uiSounds", true)
		expect(audio.volumes.ui).toBe(0.5)
	end)

	T.it("refuses a value outside the schema and puts the client back", function()
		local world, _server, settings, join, loop = setup()
		local player, client = join(1)
		world.clock:advance(1)
		local changes = 0
		settings.Changed:Connect(function()
			changes += 1
		end)
		-- A modified client sends a string where a number belongs.
		loop:injectFromClient(player, "RBLXSettings.Set", { id = "musicVolume", value = "loud" })
		world.clock:advance(0.1)
		expect(settings:get(player, "musicVolume")).toBe(0.6)
		expect(changes).toBe(0)
		expect(client:get("musicVolume")).toBe(0.6)
	end)

	T.it("fires Changed on the server for game logic", function()
		local schema = Settings.schema({ override = { controls = { options = { "classic", "tap" } } } })
		local world, _server, settings, join = setup(schema)
		local seen: { string } = {}
		settings.Changed:Connect(function(_player: any, id: string, value: any)
			table.insert(seen, id .. "=" .. tostring(value))
		end)
		local _player, client = join(1)
		world.clock:advance(1)
		client:set("controls", "tap")
		world.clock:advance(1)
		expect(seen).toEqual({ "controls=tap" })
	end)
end)

T.describe("Settings strings", function()
	T.it("every built-in setting, option, hint and section has a label in Shared.Strings", function()
		local en = Strings.en
		local missing: { string } = {}
		local function need(key: string)
			if en[key] == nil then
				table.insert(missing, key)
			end
		end
		for _, def in Settings.schema().list do
			need("settings." .. def.id)
			if def.hint then
				need(def.hint)
			end
			if def.kind == "choice" then
				for _, option in def.options :: { string } do
					need("settings." .. def.id .. "." .. option)
				end
			end
		end
		for _, section in Settings.SECTIONS do
			need("settings.section." .. section)
		end
		expect(missing).toEqual({})
	end)
end)
