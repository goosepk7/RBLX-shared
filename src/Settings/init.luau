--!strict
--[[
	Settings (brief §4, §5.5): per-player settings, saved in the profile, changed instantly.

	  -- Shared (both sides): one schema, so client and server agree on every setting.
	  local schema = Shared.Settings.schema({
	      override = { controls = { options = { "auto", "classic", "tap" } } },
	  })

	  -- Server
	  local settings = Shared.Settings.Server.new({ store = Profiles, schema = schema })
	  settings.Changed:Connect(function(player, id, value) end) -- e.g. control scheme

	  -- Client
	  local settings = Shared.Settings.Client.new({ schema = schema, audio = audio, vfx = vfx, loc = loc })
	  settings:set("musicVolume", 0.4) -- applies now, saves a moment later

	The server owns the saved values (`profile.data.settings`): it validates every change
	against the schema and sends the client a snapshot when the profile loads, or when a change
	was refused. The client applies a change the moment the player makes it (volume moves as the
	slider moves), then sends it after a short pause so a dragged slider is one message.

	Built-in settings: music and sound volume, UI sounds, camera shake (0 = off), flashes,
	vibration, colorblind palette, control scheme (options set by the game) and language. Games
	add their own with `schema({ add = { ... } })` and react through `Changed` or `appliers`.
]]

local Hooks = require("./UI/Hooks")
local Log = require("./Util/Log")
local Net = require("./Net")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Theme = require("./UI/Theme")

export type Kind = "toggle" | "slider" | "choice"
export type Section = "audio" | "comfort" | "accessibility" | "controls" | "language" | "game"
export type Value = boolean | number | string

export type Definition = {
	id: string,
	kind: Kind,
	default: Value,
	section: Section,
	min: number?, -- sliders
	max: number?,
	step: number?,
	options: { string }?, -- choices
	label: string?, -- Loc key; default "settings.<id>"
	hint: string?, -- Loc key for a caption under the label
}

export type Override = {
	default: Value?,
	options: { string }?,
	min: number?,
	max: number?,
	step: number?,
	label: string?,
	hint: string?,
}

export type SchemaOptions = {
	add: { Definition }?,
	override: { [string]: Override }?,
	remove: { string }?,
}

export type Schema = {
	list: { Definition },
	byId: { [string]: Definition },
	ids: { string },
	defaults: (self: Schema) -> { [string]: Value },
	validate: (self: Schema, id: string, value: any) -> (boolean, Value?),
	normalize: (self: Schema, saved: any) -> ({ [string]: Value }, boolean),
}

local Settings = {}

Settings.DEFINITIONS = table.freeze({
	{ id = "musicVolume", kind = "slider", default = 0.6, min = 0, max = 1, step = 0.05, section = "audio" },
	{ id = "sfxVolume", kind = "slider", default = 0.8, min = 0, max = 1, step = 0.05, section = "audio" },
	{ id = "uiSounds", kind = "toggle", default = true, section = "audio" },
	{
		id = "cameraShake",
		kind = "slider",
		default = 1,
		min = 0,
		max = 1,
		step = 0.25,
		section = "comfort",
		hint = "settings.cameraShake.hint",
	},
	{ id = "flashes", kind = "toggle", default = true, section = "comfort", hint = "settings.flashes.hint" },
	{ id = "haptics", kind = "toggle", default = true, section = "comfort" },
	{
		id = "colorblind",
		kind = "choice",
		default = "off",
		options = { "off", "deuteranopia", "protanopia", "tritanopia" },
		section = "accessibility",
	},
	-- Games set the options (and add their labels "settings.controls.<option>").
	{ id = "controls", kind = "choice", default = "auto", options = { "auto" }, section = "controls" },
	{
		id = "language",
		kind = "choice",
		default = "auto",
		options = { "auto", "en", "pt-br", "es" },
		section = "language",
	},
} :: { Definition })

Settings.SECTIONS = { "audio", "comfort", "accessibility", "controls", "language", "game" } :: { Section }

local ID_PATTERN = "^%a[%w_]*$"
local MAX_ID = 32
local MAX_STRING = 32

local function checkDefinition(def: Definition)
	assert(
		type(def.id) == "string" and #def.id <= MAX_ID and string.find(def.id, ID_PATTERN),
		"Settings: bad id " .. tostring(def.id)
	)
	assert(table.find(Settings.SECTIONS, def.section), `Settings: {def.id} has unknown section {tostring(def.section)}`)
	if def.kind == "toggle" then
		assert(type(def.default) == "boolean", `Settings: {def.id} default must be a boolean`)
	elseif def.kind == "slider" then
		local min, max = def.min, def.max
		assert(type(min) == "number" and type(max) == "number" and max > min, `Settings: {def.id} needs min < max`)
		assert(type(def.default) == "number", `Settings: {def.id} default must be a number`)
	elseif def.kind == "choice" then
		local options = def.options
		assert(type(options) == "table" and #options >= 1, `Settings: {def.id} needs options`)
		for _, option in options do
			assert(type(option) == "string" and #option <= MAX_STRING, `Settings: {def.id} option too long`)
		end
		assert(table.find(options, def.default :: any), `Settings: {def.id} default must be one of its options`)
	else
		error(`Settings: {def.id} has unknown kind {tostring(def.kind)}`)
	end
end

local function snap(def: Definition, n: number): number
	local min, max = def.min :: number, def.max :: number
	local v = math.clamp(n, min, max)
	local step = def.step
	if step and step > 0 then
		v = min + math.floor((v - min) / step + 0.5) * step
		v = math.floor(v * 1e6 + 0.5) / 1e6
	end
	return math.clamp(v, min, max)
end

--- Builds the schema both sides use. `add` appends game settings, `override` changes built-ins
--- (most often `controls.options`), `remove` drops built-ins a game doesn't want.
function Settings.schema(options: SchemaOptions?): Schema
	local opts: SchemaOptions = options or {}
	local removed: { [string]: boolean } = {}
	local removeList: { string } = opts.remove or {}
	for _, id in removeList do
		removed[id] = true
	end
	local list: { Definition } = {}
	local byId: { [string]: Definition } = {}
	local overrides: { [string]: Override } = opts.override or {}
	local function addOne(def: Definition)
		local copy: Definition = table.clone(def)
		local o = overrides[copy.id]
		if o then
			for key, value in o :: any do
				(copy :: any)[key] = value
			end
			if o.options and o.default == nil and not table.find(o.options, copy.default :: any) then
				copy.default = o.options[1]
			end
		end
		checkDefinition(copy)
		assert(byId[copy.id] == nil, "Settings: duplicate id " .. copy.id)
		byId[copy.id] = copy
		table.insert(list, copy)
	end
	for _, def in Settings.DEFINITIONS do
		if not removed[def.id] then
			addOne(def)
		end
	end
	local added: { Definition } = opts.add or {}
	for _, def in added do
		addOne(def)
	end
	for id in overrides do
		assert(byId[id], "Settings: override for unknown setting " .. id)
	end
	local ids: { string } = {}
	for _, def in list do
		table.insert(ids, def.id)
	end

	local schema = { list = list, byId = byId, ids = ids } :: Schema

	function schema.defaults(_self: Schema): { [string]: Value }
		local out: { [string]: Value } = {}
		for _, def in list do
			out[def.id] = def.default
		end
		return out
	end

	function schema.validate(_self: Schema, id: string, value: any): (boolean, Value?)
		local def = byId[id]
		if def == nil then
			return false, nil
		end
		if def.kind == "toggle" then
			if type(value) == "boolean" then
				return true, value
			end
		elseif def.kind == "slider" then
			if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
				return true, snap(def, value)
			end
		elseif def.kind == "choice" then
			if type(value) == "string" and table.find(def.options :: { string }, value) then
				return true, value
			end
		end
		return false, nil
	end

	-- Saved values for current settings, with defaults for missing or invalid ones. The second
	-- result says whether anything had to change (unknown keys dropped, bad values reset).
	function schema.normalize(self: Schema, saved: any): ({ [string]: Value }, boolean)
		local out = self:defaults()
		local changed = type(saved) ~= "table"
		if type(saved) == "table" then
			for key, value in saved do
				local ok, normalized = self:validate(key, value)
				if ok then
					out[key] = normalized :: Value
					if normalized ~= value then
						changed = true
					end
				else
					changed = true
				end
			end
			for _, def in list do
				if saved[def.id] == nil then
					changed = true
				end
			end
		end
		return out, changed
	end

	return schema
end

local S = Net.Schema

local function valueSchema()
	return S.union(S.boolean(), S.number({ min = -1e9, max = 1e9 }), S.string({ maxLength = MAX_STRING }))
end

--- The Net remotes for a schema. Both sides call this with the same schema.
function Settings.remotes(schema: Schema, options: { context: any? }?): any
	return Net.namespace("RBLXSettings", {
		Set = Net.clientEvent(
			S.struct({ id = S.enum(schema.ids), value = valueSchema() }),
			{ rateLimit = { rate = 6, burst = 16 } }
		),
		-- The client asks once on start: its scripts may run after the profile loaded.
		Request = Net.clientEvent(S.none(), { rateLimit = { rate = 1, burst = 3 } }),
		Snapshot = Net.serverEvent(S.map(S.string({ maxLength = MAX_ID }), valueSchema(), { maxEntries = 64 })),
	}, { context = options and options.context })
end

--[[ Server ]]

export type ServerOptions = {
	store: any, -- Data.Store
	schema: Schema?,
	field: string?, -- default "settings"
	remotes: any?, -- default Settings.remotes(schema)
	context: any?, -- Net context for the default remotes (tests)
	players: any?,
}

export type Server = {
	schema: Schema,
	remotes: any,
	Changed: Signal.Signal<Player, string, Value>,
	get: (self: Server, player: Player, id: string) -> Value?,
	getAll: (self: Server, player: Player) -> { [string]: Value }?,
	set: (self: Server, player: Player, id: string, value: Value) -> boolean,
}

local Server = {}

function Server.new(options: ServerOptions): Server
	local schema = options.schema or Settings.schema()
	local field = options.field or "settings"
	local store = options.store
	local remotes = options.remotes or Settings.remotes(schema, { context = options.context })

	local server = { schema = schema, remotes = remotes, Changed = Signal.new() } :: Server

	local function profileOf(player: Player): any
		local profile = store:get(player)
		if profile == nil or not profile:isActive() then
			return nil
		end
		return profile
	end

	local function valuesOf(player: Player): { [string]: Value }?
		local profile = profileOf(player)
		if profile == nil then
			return nil
		end
		local saved = profile.data[field]
		local values, changed = schema:normalize(saved)
		if changed then
			profile.data[field] = values
		end
		return profile.data[field]
	end

	local function sendSnapshot(player: Player)
		local values = valuesOf(player)
		if values then
			remotes.Snapshot:fire(player, values)
		end
	end

	function server.get(_self: Server, player: Player, id: string): Value?
		local values = valuesOf(player)
		return if values then values[id] else nil
	end

	function server.getAll(_self: Server, player: Player): { [string]: Value }?
		local values = valuesOf(player)
		return if values then table.clone(values) else nil
	end

	function server.set(self: Server, player: Player, id: string, value: Value): boolean
		local values = valuesOf(player)
		if values == nil then
			return false
		end
		local ok, normalized = schema:validate(id, value)
		if not ok then
			return false
		end
		if values[id] ~= normalized then
			values[id] = normalized :: Value
			self.Changed:Fire(player, id, normalized :: Value)
		end
		return true
	end

	remotes.Set:connect(function(player: Player, payload: { id: string, value: Value })
		if profileOf(player) == nil then
			return
		end
		if not server:set(player, payload.id, payload.value) then
			-- Out of range or the wrong type for this setting (an old client, or a modified one):
			-- put the client back on the saved values.
			Log.info("Settings", `refused {payload.id} = {tostring(payload.value)} from {player.Name}`)
			sendSnapshot(player)
		end
	end)

	remotes.Request:connect(function(player: Player)
		sendSnapshot(player)
	end)

	store.Loaded:Connect(function(player: Player)
		sendSnapshot(player)
	end)
	local players: any = options.players
	if players then
		for _, player in players:GetPlayers() do
			sendSnapshot(player)
		end
	end

	return server
end

Settings.Server = Server

--[[ Client ]]

export type ClientOptions = {
	schema: Schema?,
	remotes: any?,
	context: any?,
	audio: any?, -- Shared.Audio instance
	vfx: any?, -- Shared.VFX instance
	loc: any?, -- the game's Loc
	localeId: string?, -- Players.LocalPlayer.LocaleId, for language = "auto"
	appliers: { [string]: (Value) -> () }?, -- game settings
	task: any?,
	sendDelay: number?, -- seconds a value must sit still before it's sent, default 0.4
}

export type Client = {
	schema: Schema,
	remotes: any,
	Changed: Signal.Signal<string, Value>,
	Ready: Signal.Signal<>,
	isReady: (self: Client) -> boolean,
	get: (self: Client, id: string) -> Value,
	set: (self: Client, id: string, value: Value) -> boolean,
	flush: (self: Client) -> (),
	reset: (self: Client, section: Section?) -> (),
	apply: (self: Client) -> (),
}

local Client = {}

function Client.new(options: ClientOptions?): Client
	local opts: ClientOptions = options or {}
	local schema = opts.schema or Settings.schema()
	local remotes = opts.remotes or Settings.remotes(schema, { context = opts.context })
	local sendDelay = opts.sendDelay or 0.4
	local taskLib: any = opts.task or Roblox.task()
	local values = schema:defaults()
	local ready = false
	local pending: { [string]: Value } = {}
	local generation = 0

	local client = {
		schema = schema,
		remotes = remotes,
		Changed = Signal.new(),
		Ready = Signal.new(),
	} :: Client

	local appliers: { [string]: (Value) -> () } = {}

	local function applyUiVolume()
		if opts.audio then
			local on = values.uiSounds ~= false
			opts.audio:setVolume("ui", if on then values.sfxVolume :: number else 0)
		end
	end

	appliers.musicVolume = function(v: Value)
		if opts.audio then
			opts.audio:setVolume("music", v :: number)
		end
	end
	appliers.sfxVolume = function(v: Value)
		if opts.audio then
			opts.audio:setVolume("sfx", v :: number)
			opts.audio:setVolume("ambient", v :: number)
		end
		applyUiVolume()
	end
	appliers.uiSounds = function()
		applyUiVolume()
	end
	appliers.cameraShake = function(v: Value)
		if opts.vfx then
			opts.vfx:setShakeScale(v :: number)
		end
	end
	appliers.flashes = function(v: Value)
		if opts.vfx then
			opts.vfx:setFlashesEnabled(v :: boolean)
		end
	end
	appliers.haptics = function(v: Value)
		Hooks.setHapticsEnabled(v :: boolean)
	end
	appliers.colorblind = function(v: Value)
		Theme.setPalette(v :: any)
	end
	appliers.language = function(v: Value)
		if opts.loc then
			opts.loc:setLocale(if v == "auto" then opts.localeId or "en" else v :: string)
		end
	end
	local extraAppliers: { [string]: (Value) -> () } = opts.appliers or {}
	for id, fn in extraAppliers do
		appliers[id] = fn
	end

	local function applyOne(id: string)
		local fn = appliers[id]
		if fn and schema.byId[id] then
			fn(values[id])
		end
	end

	function client.apply(_self: Client)
		for _, def in schema.list do
			applyOne(def.id)
		end
	end

	function client.isReady(_self: Client): boolean
		return ready
	end

	function client.get(_self: Client, id: string): Value
		local value = values[id]
		if value == nil then
			error("Settings: unknown setting " .. id, 2)
		end
		return value
	end

	function client.flush(_self: Client)
		generation += 1
		for id, value in pending do
			remotes.Set:fire({ id = id, value = value })
		end
		table.clear(pending)
	end

	function client.set(self: Client, id: string, value: Value): boolean
		local ok, normalized = schema:validate(id, value)
		if not ok then
			Log.warn("Settings", `ignored invalid value for {id}: {tostring(value)}`)
			return false
		end
		if values[id] == normalized then
			return true
		end
		values[id] = normalized :: Value
		applyOne(id)
		self.Changed:Fire(id, normalized :: Value)
		pending[id] = normalized :: Value
		generation += 1
		local mine = generation
		taskLib.delay(sendDelay, function()
			if generation == mine then
				self:flush()
			end
		end)
		return true
	end

	function client.reset(self: Client, section: Section?)
		for _, def in schema.list do
			if section == nil or def.section == section then
				self:set(def.id, def.default)
			end
		end
	end

	remotes.Snapshot:connect(function(snapshot: { [string]: Value })
		local normalized = schema:normalize(snapshot)
		for _, def in schema.list do
			local id = def.id
			-- A change still waiting to be sent wins over an older snapshot.
			if pending[id] == nil and values[id] ~= normalized[id] then
				values[id] = normalized[id]
				applyOne(id)
				client.Changed:Fire(id, values[id])
			end
		end
		if not ready then
			ready = true
			client:apply()
			client.Ready:Fire()
		end
	end)

	-- Apply defaults now, so audio and comfort settings are right before the first snapshot,
	-- then ask for the saved ones (the profile may have loaded before this script ran).
	client:apply()
	remotes.Request:fire(nil)
	return client
end

Settings.Client = Client
Settings.Screen = require("@self/Screen")

return Settings
