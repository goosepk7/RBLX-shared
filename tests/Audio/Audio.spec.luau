--!strict
local Audio = require("@shared/Audio")
local Hooks = require("@shared/UI/Hooks")
local Log = require("@shared/Util/Log")
local Rng = require("@shared/Sim/Rng")
local T = require("@shared/Test")

local expect = T.expect

local restoreLog: () -> () = function() end
T.beforeEach(function()
	local _
	_, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
	Hooks.setSoundHandler(nil)
end)

local function setup(pending: { [string]: boolean }?)
	local fakes = T.Fakes.Instances.new()
	local clock = T.Clock.new()
	local rng = Rng.new("audio-spec")
	local audio = Audio.new({
		createInstance = fakes.create,
		parent = fakes.create("SoundService") :: any,
		task = clock.task,
		random = function()
			return rng:next()
		end,
		assets = {
			get = function(name: string): string
				if pending and pending[name] then
					return ""
				end
				return "rbxassetid://" .. name
			end,
		},
	})
	return audio, fakes, clock
end

T.describe("Audio", function()
	T.it("plays a defined sound through its category group", function()
		local audio, fakes = setup()
		local sound = audio:play("ui.open")
		expect(sound.SoundId).toBe("rbxassetid://sfx_ui_open")
		expect(sound.IsPlaying).toBe(true)
		expect(sound.SoundGroup.Name).toBe("RBLXAudio_ui")
		expect(fakes:count("SoundGroup")).toBe(1)
	end)

	T.it("never plays the same variation twice in a row", function()
		local audio = setup()
		local last = ""
		for _ = 1, 40 do
			local sound = audio:play("ui.click")
			expect(sound.SoundId).never.toBe(last)
			expect(sound.SoundId).toMatch("^rbxassetid://sfx_ui_click_[1-4]$")
			last = sound.SoundId
			sound:Stop()
		end
	end)

	T.it("pools copies, reuses finished ones and restarts the oldest when all are busy", function()
		local audio, fakes = setup()
		audio:define("t.boom", { asset = "boom", maxInstances = 2 })
		local a = audio:play("t.boom")
		local b = audio:play("t.boom")
		expect(a).never.toBe(b)
		local c = audio:play("t.boom") -- both busy: a started first
		expect(c).toBe(a)
		expect(audio:getDiagnostics().stolen).toBe(1)
		b:Stop()
		expect(audio:play("t.boom")).toBe(b)
		expect(fakes:count("Sound")).toBe(2)
	end)

	T.it("stays silent for assets pending upload and counts them", function()
		local audio = setup({ sfx_ui_open = true })
		expect(audio:play("ui.open")).toBeNil()
		expect(audio:getDiagnostics().silent).toBe(1)
	end)

	T.it("warns once for an unknown sound name", function()
		local audio = setup()
		local logs, restore = Log.capture()
		expect(audio:play("nope")).toBeNil()
		expect(audio:play("nope")).toBeNil()
		restore()
		expect(#logs).toBe(1)
	end)

	T.it("sets group volume to category x master", function()
		local audio = setup()
		local sound = audio:play("fx.win")
		audio:setVolume("sfx", 0.5)
		audio:setVolume("master", 0.5)
		expect(sound.SoundGroup.Volume).toBeNear(0.25)
		audio:setVolume("sfx", 3)
		expect(audio:getVolume("sfx")).toBe(1)
	end)

	T.it("crossfades music between two decks", function()
		local audio, fakes, clock = setup()
		audio:playMusic("music_hub", { fade = 1, volume = 0.5 })
		clock:advance(1.1)
		local decks = fakes:all("Sound")
		local hub = decks[1]
		expect(hub.Volume).toBeNear(0.5)
		audio:playMusic("music_world1", { fade = 1, volume = 0.4 })
		clock:advance(0.5)
		local world = fakes:all("Sound")[2]
		expect(hub.Volume).toBeNear(0.25, 0.03)
		expect(world.Volume).toBeNear(0.2, 0.03)
		clock:advance(0.6)
		expect(hub.IsPlaying).toBe(false)
		expect(world.Volume).toBeNear(0.4)
		expect(audio:currentMusic()).toBe("music_world1")
		-- Same track again is a no-op; switching back reuses the first deck.
		audio:playMusic("music_world1")
		audio:playMusic("music_hub", { fade = 0.5 })
		clock:advance(0.6)
		expect(fakes:count("Sound")).toBe(2)
		expect(hub.IsPlaying).toBe(true)
		audio:stopMusic(0.2)
		clock:advance(0.3)
		expect(hub.IsPlaying).toBe(false)
		expect(audio:currentMusic()).toBeNil()
	end)

	T.it("a newer fade cancels an older one's stop", function()
		local audio, fakes, clock = setup()
		audio:playMusic("a", { fade = 1 })
		clock:advance(1.1)
		audio:playMusic("b", { fade = 1 })
		clock:advance(0.3)
		audio:playMusic("a", { fade = 1 }) -- back to the first deck before it stopped
		clock:advance(1.5)
		local first = fakes:all("Sound")[1]
		expect(first.IsPlaying).toBe(true)
		expect(first.Volume).toBeNear(0.5)
	end)

	T.it("positional sounds parent to the target and clean up when they end", function()
		local audio, fakes, clock = setup()
		local part = fakes.create("Part")
		local sound = audio:playAt("fx.checkpoint", part :: any)
		expect(sound.Parent).toBe(part)
		sound:finish()
		expect(sound.Destroyed).toBe(true)
		local other = audio:playAt("fx.checkpoint", part :: any)
		clock:advance(11) -- Ended never fired
		expect(other.Destroyed).toBe(true)
		expect(audio:getDiagnostics().instances).toBe(0)
	end)

	T.it("answers the UI kit's sound hooks", function()
		local audio = setup()
		local unbind = audio:bindKit()
		Hooks.sound("toast")
		Hooks.sound("click")
		expect(audio:getDiagnostics().plays).toBe(2)
		unbind()
		expect(Hooks.hasSoundHandler()).toBe(false)
	end)

	T.it("has a default definition for every kit sound, each in the manifest", function()
		local manifest = require("@lune/serde").decode("json", require("@lune/fs").readFile("assets/manifest.json"))
		local names: { [string]: boolean } = {}
		for _, entry in manifest.assets do
			names[entry.name] = entry.kind == "audio"
		end
		local kit = { "click", "hover", "open", "close", "success", "fail", "thump", "pop", "tab", "toast" }
		for _, name in kit do
			expect(Audio.DEFAULT_SOUNDS["ui." .. name]).toBeTruthy()
		end
		for name, def in Audio.DEFAULT_SOUNDS do
			local n = def.variants or 0
			if n > 1 then
				for i = 1, n do
					if not names[def.asset .. "_" .. i] then
						error(`{name}: {def.asset}_{i} is not an audio entry in the manifest`)
					end
				end
			elseif not names[def.asset] then
				error(`{name}: {def.asset} is not an audio entry in the manifest`)
			end
		end
	end)
end)
