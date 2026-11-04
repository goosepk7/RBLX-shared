--!strict
--[[
	Audio (brief §4, §5.7): SFX with pooling and variations, music crossfade, per-category
	volume, and the UI kit's default sounds.

	  local audio = Shared.Audio.new()            -- client; sounds live under SoundService
	  audio:bindKit()                              -- kit clicks, toasts, pops play from here
	  audio:define("stilts.footfall_wood", { asset = "sfx_stilts_wood", variants = 4, pitchJitter = 0.06 })
	  audio:play("stilts.footfall_wood")
	  audio:playAt("stilts.splash", character.HumanoidRootPart)
	  audio:playMusic("music_world1")              -- crossfades from whatever is playing
	  audio:setVolume("music", 0.4)                -- Settings drives these

	Sounds are named definitions over manifest assets, so code says what happens ("ui.click")
	and the manifest says which file plays. A definition with `variants = n` plays
	`<asset>_1` .. `<asset>_n` at random and never the same one twice in a row. Assets still
	pending upload play nothing (counted in `getDiagnostics().silent`), so nothing breaks before
	the owner runs the uploader.

	Categories: "music", "sfx", "ui", "ambient", each a SoundGroup whose volume is
	category x master. Works under lune with injected `createInstance`, `task` and `assets`.
]]

local Assets = require("./Assets")
local Hooks = require("./UI/Hooks")
local Log = require("./Util/Log")
local Roblox = require("./Util/Roblox")

export type Category = "music" | "sfx" | "ui" | "ambient"
export type VolumeName = Category | "master"

export type SoundDef = {
	asset: string, -- manifest name, or the base of `<asset>_<n>` when `variants` is set
	category: Category?, -- default "sfx"
	volume: number?, -- 0..1 before the category volume, default 0.5
	variants: number?,
	pitchJitter: number?, -- PlaybackSpeed varies by up to +/- this, default 0
	maxInstances: number?, -- pooled copies that can overlap, default 4
	looped: boolean?,
}

export type PlayOptions = {
	volume: number?,
	pitch: number?,
}

export type MusicOptions = {
	fade: number?, -- seconds, default 1.5
	volume: number?,
}

export type Options = {
	parent: Instance?, -- default SoundService
	sounds: { [string]: SoundDef }?, -- merged over Audio.DEFAULT_SOUNDS
	volumes: { [VolumeName]: number }?,
	createInstance: ((className: string) -> any)?,
	task: any?,
	random: (() -> number)?, -- [0, 1)
	assets: { get: (name: string) -> string }?,
	fadeStep: number?, -- seconds between fade steps, default 1/30
}

export type Diagnostics = {
	pools: number,
	instances: number,
	plays: number,
	silent: number,
	stolen: number,
	music: string?,
	volumes: { [string]: number },
}

export type Audio = {
	define: (self: Audio, name: string, def: SoundDef) -> (),
	has: (self: Audio, name: string) -> boolean,
	play: (self: Audio, name: string, options: PlayOptions?) -> any,
	playAt: (self: Audio, name: string, parent: Instance, options: PlayOptions?) -> any,
	playMusic: (self: Audio, name: string, options: MusicOptions?) -> (),
	stopMusic: (self: Audio, fade: number?) -> (),
	currentMusic: (self: Audio) -> string?,
	setVolume: (self: Audio, name: VolumeName, value: number) -> (),
	getVolume: (self: Audio, name: VolumeName) -> number,
	bindKit: (self: Audio) -> () -> (),
	getDiagnostics: (self: Audio) -> Diagnostics,
	destroy: (self: Audio) -> (),
}

local Audio = {}

Audio.CATEGORIES = { "music", "sfx", "ui", "ambient" } :: { Category }

--- The framework's sound set (tools/sfx_gen.py). `ui.*` are what the kit raises through
--- UI.Hooks; `fx.*` are the §5.7 feedback moments games trigger.
Audio.DEFAULT_SOUNDS = table.freeze({
	["ui.click"] = { asset = "sfx_ui_click", category = "ui", volume = 0.5, variants = 4, pitchJitter = 0.03 },
	["ui.hover"] = { asset = "sfx_ui_hover", category = "ui", volume = 0.25, variants = 3, maxInstances = 2 },
	["ui.open"] = { asset = "sfx_ui_open", category = "ui", volume = 0.45 },
	["ui.close"] = { asset = "sfx_ui_close", category = "ui", volume = 0.4 },
	["ui.tab"] = { asset = "sfx_ui_tab", category = "ui", volume = 0.45 },
	["ui.toast"] = { asset = "sfx_ui_toast", category = "ui", volume = 0.4 },
	["ui.pop"] = { asset = "sfx_ui_pop", category = "ui", volume = 0.45, variants = 3, pitchJitter = 0.04 },
	["ui.success"] = { asset = "sfx_ui_success", category = "ui", volume = 0.55 },
	["ui.fail"] = { asset = "sfx_ui_fail", category = "ui", volume = 0.5 },
	["ui.thump"] = { asset = "sfx_ui_thump", category = "ui", volume = 0.7, maxInstances = 2 },
	["fx.purchase"] = { asset = "sfx_purchase", category = "sfx", volume = 0.6 },
	["fx.win"] = { asset = "sfx_win", category = "sfx", volume = 0.6 },
	["fx.checkpoint"] = { asset = "sfx_checkpoint", category = "sfx", volume = 0.5 },
	["fx.unlock"] = { asset = "sfx_unlock", category = "sfx", volume = 0.7, maxInstances = 1 },
	["fx.fail"] = { asset = "sfx_fail", category = "sfx", volume = 0.6 },
} :: { [string]: SoundDef })

local DEFAULT_VOLUMES: { [VolumeName]: number } = {
	master = 1,
	music = 0.6,
	sfx = 0.8,
	ui = 0.8,
	ambient = 0.7,
}

type Pooled = { sound: any, startedAt: number }
type Deck = { sound: any, name: string, generation: number }

local function clamp01(v: number): number
	if v ~= v then
		return 0
	end
	return math.clamp(v, 0, 1)
end

function Audio.new(options: Options?): Audio
	local opts: Options = options or {}
	local createInstance: (string) -> any = opts.createInstance
		or function(className: string): any
			return Instance.new(className :: any)
		end
	local taskLib: any = opts.task
	local random: () -> number = opts.random or math.random
	local assets: { get: (string) -> string } = opts.assets or Assets
	local fadeStep = opts.fadeStep or 1 / 30
	local parent: any = opts.parent

	local defs: { [string]: SoundDef } = table.clone(Audio.DEFAULT_SOUNDS :: { [string]: SoundDef })
	local extra: { [string]: SoundDef } = opts.sounds or {}
	for name, def in extra do
		defs[name] = def
	end

	local volumes: { [string]: number } = table.clone(DEFAULT_VOLUMES :: any)
	local initial: { [string]: number } = (opts.volumes or {}) :: any
	for name, value in initial do
		volumes[name] = clamp01(value)
	end

	local groups: { [string]: any } = {}
	local pools: { [string]: { Pooled } } = {}
	local lastVariant: { [string]: number } = {}
	local warned: { [string]: boolean } = {}
	local plays, silent, stolen, instances = 0, 0, 0, 0
	local decks: { [number]: Deck } = {}
	local activeDeck = 0 -- 0 = no music
	local unbindKit: (() -> ())? = nil
	local destroyed = false
	local ticks = 0 -- monotonic play counter (pool ages)

	local audio = {} :: Audio

	local function warnOnce(key: string, message: string)
		if not warned[key] then
			warned[key] = true
			Log.warn("Audio", message)
		end
	end

	local function root(): any
		if parent == nil then
			parent = Roblox.service("SoundService")
		end
		return parent
	end

	local function groupFor(category: Category): any
		local group = groups[category]
		if group == nil then
			group = createInstance("SoundGroup")
			group.Name = "RBLXAudio_" .. category
			group.Volume = volumes[category] * volumes.master
			group.Parent = root()
			groups[category] = group
		end
		return group
	end

	local function applyVolumes()
		for category, group in groups do
			group.Volume = volumes[category] * volumes.master
		end
	end

	local function newSound(def: SoundDef, uri: string, into: any): any
		local category: Category = def.category or "sfx"
		local sound = createInstance("Sound")
		sound.SoundId = uri
		sound.Looped = def.looped == true
		sound.SoundGroup = groupFor(category)
		sound.Parent = into or groupFor(category)
		instances += 1
		return sound
	end

	-- The asset to play for `def` this time, or nil (with a warning) if there's none.
	local function pickAsset(name: string, def: SoundDef): string
		local n = def.variants or 0
		if n <= 1 then
			return if n == 1 then def.asset .. "_1" else def.asset
		end
		local index = math.floor(random() * n) + 1
		if index == lastVariant[name] then
			index = index % n + 1
		end
		lastVariant[name] = index
		return def.asset .. "_" .. tostring(index)
	end

	local function resolve(name: string): (SoundDef?, string?, string?)
		local def = defs[name]
		if def == nil then
			warnOnce("def:" .. name, `unknown sound "{name}"; define it with audio:define`)
			return nil, nil, nil
		end
		local asset = pickAsset(name, def)
		local uri = assets.get(asset)
		if uri == "" then
			silent += 1
			return def, asset, nil -- pending upload: Assets already warned once
		end
		return def, asset, uri
	end

	local function pitchFor(def: SoundDef, options: PlayOptions?): number
		local jitter = def.pitchJitter or 0
		local pitch = if options and options.pitch then options.pitch else 1
		if jitter > 0 then
			pitch *= 1 + (random() * 2 - 1) * jitter
		end
		return pitch
	end

	function audio.define(_self: Audio, name: string, def: SoundDef)
		assert(type(def.asset) == "string" and #def.asset > 0, "Audio:define needs an asset name")
		if def.category ~= nil then
			assert(table.find(Audio.CATEGORIES, def.category) ~= nil, "Audio:define: unknown category")
		end
		defs[name] = def
	end

	function audio.has(_self: Audio, name: string): boolean
		return defs[name] ~= nil
	end

	function audio.play(_self: Audio, name: string, playOptions: PlayOptions?): any
		if destroyed then
			return nil
		end
		local def, asset, uri = resolve(name)
		if def == nil or asset == nil or uri == nil then
			return nil
		end
		local pool = pools[asset]
		if pool == nil then
			pool = {}
			pools[asset] = pool
		end
		local chosen: Pooled? = nil
		for _, item in pool do
			if not item.sound.IsPlaying then
				chosen = item
				break
			end
		end
		if chosen == nil then
			if #pool < (def.maxInstances or 4) then
				chosen = { sound = newSound(def, uri, nil), startedAt = 0 }
				table.insert(pool, chosen :: Pooled)
			else
				-- All busy: restart the one that started longest ago.
				local oldest = pool[1]
				for _, item in pool do
					if item.startedAt < oldest.startedAt then
						oldest = item
					end
				end
				oldest.sound:Stop()
				chosen = oldest
				stolen += 1
			end
		end
		local item = chosen :: Pooled
		ticks += 1
		item.startedAt = ticks
		local sound = item.sound
		sound.Volume = clamp01(if playOptions and playOptions.volume then playOptions.volume else def.volume or 0.5)
		sound.PlaybackSpeed = pitchFor(def, playOptions)
		sound.TimePosition = 0
		sound:Play()
		plays += 1
		return sound
	end

	function audio.playAt(_self: Audio, name: string, target: Instance, playOptions: PlayOptions?): any
		if destroyed then
			return nil
		end
		local def, _asset, uri = resolve(name)
		if def == nil or uri == nil then
			return nil
		end
		-- Positional sounds are one-shots parented to the part or attachment, so they follow it
		-- and fall off with distance. They clean themselves up when done.
		local sound = newSound(def, uri, target)
		sound.Volume = clamp01(if playOptions and playOptions.volume then playOptions.volume else def.volume or 0.5)
		sound.PlaybackSpeed = pitchFor(def, playOptions)
		sound.Looped = false
		local done = false
		local function cleanup()
			if not done then
				done = true
				instances -= 1
				sound:Destroy()
			end
		end
		sound.Ended:Once(cleanup)
		taskLib = taskLib or Roblox.task()
		taskLib.delay(10, cleanup) -- in case Ended never fires (destroyed parent, failed load)
		sound:Play()
		plays += 1
		return sound
	end

	-- Fades deck `index` from its current volume to `target` over `seconds`, then calls `after`.
	-- A newer fade on the same deck supersedes this one.
	local function fade(index: number, target: number, seconds: number, after: (() -> ())?)
		local deck = decks[index]
		if deck == nil then
			return
		end
		deck.generation += 1
		local generation = deck.generation
		local sound = deck.sound
		local start = sound.Volume
		if seconds <= 0 then
			sound.Volume = target
			if after then
				after()
			end
			return
		end
		taskLib = taskLib or Roblox.task()
		taskLib.spawn(function()
			local elapsed = 0
			while elapsed < seconds do
				taskLib.wait(fadeStep)
				elapsed += fadeStep
				if deck.generation ~= generation or destroyed then
					return
				end
				local alpha = math.min(1, elapsed / seconds)
				sound.Volume = start + (target - start) * alpha
			end
			sound.Volume = target
			if after then
				after()
			end
		end)
	end

	function audio.playMusic(_self: Audio, name: string, musicOptions: MusicOptions?)
		if destroyed then
			return
		end
		local current = if activeDeck > 0 then decks[activeDeck] else nil
		if current and current.name == name then
			return
		end
		local seconds = if musicOptions and musicOptions.fade then musicOptions.fade else 1.5
		local def = defs[name]
		if def == nil then
			-- Music is usually named straight from the manifest: "music_world1".
			def = { asset = name, category = "music", volume = 0.5, looped = true }
			defs[name] = def
		end
		local musicDef = def :: SoundDef
		local uri = assets.get(musicDef.asset)
		-- Fade out what's playing even if the new track is pending, so state stays consistent.
		if current then
			local old = current
			fade(activeDeck, 0, seconds, function()
				old.sound:Stop()
			end)
		end
		local nextIndex = if activeDeck == 1 then 2 else 1
		local deck = decks[nextIndex]
		if deck == nil then
			local sound = newSound({ asset = musicDef.asset, category = "music", looped = true }, uri, nil)
			deck = { sound = sound, name = name, generation = 0 }
			decks[nextIndex] = deck
		end
		local d = deck :: Deck
		d.name = name
		d.sound.SoundId = uri
		d.sound.Looped = true
		d.sound.Volume = 0
		activeDeck = nextIndex
		if uri == "" then
			silent += 1
			return
		end
		d.sound.TimePosition = 0
		d.sound:Play()
		plays += 1
		local target =
			clamp01(if musicOptions and musicOptions.volume then musicOptions.volume else musicDef.volume or 0.5)
		fade(nextIndex, target, seconds, nil)
	end

	function audio.stopMusic(_self: Audio, seconds: number?)
		if activeDeck == 0 then
			return
		end
		local index = activeDeck
		local deck = decks[index] :: Deck
		activeDeck = 0
		fade(index, 0, seconds or 1, function()
			deck.sound:Stop()
		end)
	end

	function audio.currentMusic(_self: Audio): string?
		local deck = if activeDeck > 0 then decks[activeDeck] else nil
		return if deck then deck.name else nil
	end

	function audio.setVolume(_self: Audio, name: VolumeName, value: number)
		assert(DEFAULT_VOLUMES[name] ~= nil, "Audio:setVolume: unknown volume " .. tostring(name))
		volumes[name] = clamp01(value)
		applyVolumes()
	end

	function audio.getVolume(_self: Audio, name: VolumeName): number
		return volumes[name]
	end

	function audio.bindKit(self: Audio): () -> ()
		if unbindKit then
			unbindKit()
		end
		Hooks.setSoundHandler(function(kitSound: Hooks.SoundName)
			self:play("ui." .. kitSound)
		end)
		local unbind = function()
			Hooks.setSoundHandler(nil)
			unbindKit = nil
		end
		unbindKit = unbind
		return unbind
	end

	function audio.getDiagnostics(_self: Audio): Diagnostics
		local poolCount = 0
		for _ in pools do
			poolCount += 1
		end
		return {
			pools = poolCount,
			instances = instances,
			plays = plays,
			silent = silent,
			stolen = stolen,
			music = audio:currentMusic(),
			volumes = table.clone(volumes),
		}
	end

	function audio.destroy(_self: Audio)
		destroyed = true
		if unbindKit then
			unbindKit()
		end
		for _, pool in pools do
			for _, item in pool do
				item.sound:Destroy()
			end
		end
		table.clear(pools)
		for _, deck in decks do
			if deck then
				deck.sound:Destroy()
			end
		end
		for _, group in groups do
			group:Destroy()
		end
		table.clear(groups)
	end

	return audio
end

return Audio
