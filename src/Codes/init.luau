--!strict
--[[
	Codes: redeemable codes with start and expiry times, a global use limit, one redemption per
	player and a reward (brief §4, §11 launch codes). Codes come from config, or are added at
	runtime by the owner through the Admin panel (stored in a DataStore, so no deploy is needed).

	  local codes = Shared.Codes.new({
	  	economy = economy,
	  	shop = shop,
	  	codes = {
	  		{ code = "RELEASE", reward = { currencies = { Wins = 50 } }, expiresAt = 1767225600 },
	  		{ code = "TALLER", reward = { items = { "trail_spark" } }, maxUses = 10000 },
	  	},
	  })
	  codes:bindStore(Profiles)
	  codes:start()                                        -- loads runtime codes, keeps them fresh
	  local ok, failure, applied = codes:redeemAsync(player, "  release ")

	  -- Admin panel, any server:
	  codes:createAsync({ code = "SORRY", reward = { currencies = { Wins = 100 } }, expiresAt = os.time() + 86400 })

	Codes are case-insensitive: letters, digits and underscores, 3-24 characters. Rewards pay with
	the "code" reason (a grant by default: exact, and never raising lifetime totals such as
	Stilts height). Wrong guesses count: after `maxFailures` in `failureWindow` seconds a player
	waits `lockoutSeconds`.

	Failures: "invalid" (not a code shape), "unknown" (no such code, or not started yet),
	"expired", "redeemed" (this player already did), "exhausted" (global uses gone),
	"requirements", "tooManyAttempts", "busy" (a redemption is already running for this player),
	"unavailable" (the DataStore failed; try again), "notLoaded".
]]

local Log = require("./Util/Log")
local Remotes = require("./Remotes")
local Rewards = require("./Rewards")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Slots = require("./Util/Slots")
local Types = require("./Types")

export type CodeDef = {
	code: string,
	reward: Types.Reward,
	-- os.time() bounds. Before startsAt the code reads as unknown.
	startsAt: number?,
	expiresAt: number?,
	-- Redemptions across every server and player. Nil = unlimited.
	maxUses: number?,
	-- Extra condition, e.g. a world unlocked. Config codes only (runtime codes can't hold
	-- functions).
	requires: ((who: any) -> (boolean, string?))?,
	disabled: boolean?,
	-- Owner's note for the Admin list ("Discord 10k members").
	note: string?,
	-- "config" or "runtime" (set by Codes).
	source: string?,
	createdAt: number?,
}

export type Options = {
	economy: any,
	shop: any?,
	codes: { CodeDef }?,
	field: string?,
	-- Economy reason for currency rewards. Default "code" (a grant).
	reason: string?,
	-- Runtime codes. Defaults: DataStore "RBLXShared_Codes", key "Codes", refresh every 120 s,
	-- and a refresh on a miss if the cache is older than 10 s.
	storeName: string?,
	key: string?,
	refreshInterval: number?,
	missRefreshAge: number?,
	maxFailures: number?,
	failureWindow: number?,
	lockoutSeconds: number?,
	-- Dependencies. `dataStoreService = false` turns runtime codes off.
	dataStoreService: any?,
	messagingService: any?,
	task: any?,
	now: (() -> number)?,
	clock: (() -> number)?,
	players: any?,
}

export type State = {
	-- Code -> os.time() redeemed.
	redeemed: { [string]: number },
}

export type Codes = {
	-- (player?, userId, code, applied)
	Redeemed: Signal.Signal<any, number, string, Rewards.Applied>,

	bindStore: (self: Codes, store: any) -> (),
	attach: (self: Codes, who: any, data: any) -> (),
	detach: (self: Codes, who: any) -> (),
	isAttached: (self: Codes, who: any) -> boolean,
	-- Loads runtime codes and keeps them fresh (refresh loop and change pings). Yields once.
	start: (self: Codes) -> (),

	-- Upper-cased and trimmed, or nil when the text can't be a code.
	normalize: (self: Codes, text: string) -> string?,
	-- The active definition for a code (config first, then runtime), or nil.
	lookup: (self: Codes, code: string) -> CodeDef?,
	hasRedeemed: (self: Codes, who: any, code: string) -> boolean,
	redeemAsync: (self: Codes, who: any, text: string) -> (boolean, string?, Rewards.Applied?),

	-- Admin (runtime codes). Each yields and returns (ok, err?).
	refreshAsync: (self: Codes) -> (boolean, string?),
	createAsync: (self: Codes, def: CodeDef) -> (boolean, string?),
	disableAsync: (self: Codes, code: string) -> (boolean, string?),
	-- Every code, config and runtime, with uses so far for limited ones.
	listAsync: (self: Codes) -> { { def: CodeDef, uses: number? } },
	usesAsync: (self: Codes, code: string) -> (number?, string?),

	-- Server: binds this module's remotes (Remotes.codes) and wires the handlers. Once, at startup.
	bindNet: (self: Codes, context: any?) -> any,
}

local CODE_PATTERN = "^[A-Z0-9_]+$"
local MIN_LENGTH = 3
local MAX_LENGTH = 24
local TOPIC = "RBLXShared.Codes"

local Codes = {}

function Codes.newState(): State
	return { redeemed = {} }
end

function Codes.repair(state: any): State
	local out = Codes.newState()
	if type(state) == "table" and type(state.redeemed) == "table" then
		for code, at in state.redeemed do
			if type(code) == "string" and type(at) == "number" and at == at then
				out.redeemed[code] = at
			end
		end
	end
	return out
end

-- Upper-cases, trims and checks the shape (pure).
function Codes.normalize(text: any): string?
	if type(text) ~= "string" or #text > 64 then
		return nil
	end
	local code = string.upper((string.gsub(text, "^%s+", "")))
	code = (string.gsub(code, "%s+$", ""))
	if #code < MIN_LENGTH or #code > MAX_LENGTH or not string.match(code, CODE_PATTERN) then
		return nil
	end
	return code
end

-- Problems with a definition, as strings; empty when valid.
function Codes.validate(def: any, target: Rewards.Target?): { string }
	local problems: { string } = {}
	if type(def) ~= "table" then
		return { "code definition must be a table" }
	end
	if Codes.normalize(def.code) ~= def.code then
		table.insert(problems, "code must be 3-24 upper-case letters, digits or underscores")
	end
	for _, problem in Rewards.validate(def.reward, target) do
		table.insert(problems, "reward." .. problem)
	end
	if Rewards.isEmpty(def.reward) then
		table.insert(problems, "reward is empty")
	end
	for _, key in { "startsAt", "expiresAt", "maxUses" } do
		local v = def[key]
		if v ~= nil and (type(v) ~= "number" or v ~= v or v < 0) then
			table.insert(problems, key .. " must be a number >= 0")
		end
	end
	if def.maxUses ~= nil and type(def.maxUses) == "number" and def.maxUses ~= math.floor(def.maxUses) then
		table.insert(problems, "maxUses must be a whole number")
	end
	if def.requires ~= nil and type(def.requires) ~= "function" then
		table.insert(problems, "requires must be a function")
	end
	return problems
end

function Codes.new(options: Options): Codes
	local economy = options.economy
	assert(economy ~= nil, "Codes.new: economy is required")
	local target: Rewards.Target = { economy = economy, shop = options.shop }
	local reason = options.reason or "code"
	Rewards.requireReason(economy, reason, "Codes.new")
	local now: () -> number = options.now or os.time
	local clock: () -> number = options.clock or os.clock
	local storeName = options.storeName or "RBLXShared_Codes"
	local key = options.key or "Codes"
	local refreshInterval = options.refreshInterval or 120
	local missRefreshAge = options.missRefreshAge or 10
	local maxFailures = options.maxFailures or 8
	local failureWindow = options.failureWindow or 600
	local lockoutSeconds = options.lockoutSeconds or 300

	local configCodes: { [string]: CodeDef } = {}
	local configList: { CodeDef } = options.codes or {}
	for _, def in configList do
		local problems = Codes.validate(def, target)
		assert(#problems == 0, "Codes.new: " .. tostring(def.code) .. ": " .. table.concat(problems, "; "))
		assert(configCodes[def.code] == nil, "Codes.new: duplicate code " .. def.code)
		local copy = table.clone(def)
		copy.source = "config"
		configCodes[def.code] = copy
	end

	local runtimeCodes: { [string]: CodeDef } = {}
	local loadedAt: number? = nil
	local slots = Slots.new(options.field or "codes", Codes.newState, Codes.repair)
	local busy: { [number]: boolean } = {}
	local failures: { [number]: { times: { number }, lockedUntil: number? } } = {}

	local codes = { Redeemed = Signal.new() } :: Codes

	local function dataStoreService(): any?
		local dss = options.dataStoreService
		if dss == false then
			return nil
		end
		if dss == nil and Roblox.isRoblox() then
			dss = Roblox.service("DataStoreService")
		end
		return dss
	end

	local function codeStore(): any?
		local dss = dataStoreService()
		return if dss then dss:GetDataStore(storeName) else nil
	end

	local function usesKey(code: string): string
		return "Uses_" .. code
	end

	local function messaging(): any?
		local service = options.messagingService
		if service == false then
			return nil
		end
		if service == nil and Roblox.isRoblox() then
			service = Roblox.service("MessagingService")
		end
		return service
	end

	local function readDocument(value: any): { [string]: CodeDef }
		local out: { [string]: CodeDef } = {}
		if type(value) ~= "table" or type(value.codes) ~= "table" then
			return out
		end
		for code, def in value.codes do
			local problems = Codes.validate(def, target)
			if type(code) == "string" and #problems == 0 and def.code == code then
				local copy = table.clone(def)
				copy.source = "runtime"
				out[code] = copy
			else
				Log.warn("Codes", "skipping stored code " .. tostring(code) .. ": " .. table.concat(problems, "; "))
			end
		end
		return out
	end

	local function active(def: CodeDef?): CodeDef?
		if def == nil or def.disabled then
			return nil
		end
		if def.startsAt and now() < (def.startsAt :: number) then
			return nil
		end
		return def
	end

	local function noteFailure(userId: number)
		local record = failures[userId]
		if record == nil then
			record = { times = {} }
			failures[userId] = record
		end
		local r = record :: { times: { number }, lockedUntil: number? }
		local t = clock()
		table.insert(r.times, t)
		while #r.times > 0 and t - r.times[1] > failureWindow do
			table.remove(r.times, 1)
		end
		if #r.times >= maxFailures then
			r.lockedUntil = t + lockoutSeconds
			r.times = {}
		end
	end

	local function lockedOut(userId: number): boolean
		local record = failures[userId]
		return record ~= nil and record.lockedUntil ~= nil and clock() < (record.lockedUntil :: number)
	end

	function codes.bindStore(self: Codes, store: any)
		slots:bindStore(store)
		local players = options.players
		if players == nil and Roblox.isRoblox() then
			players = Roblox.service("Players")
		end
		if players then
			players.PlayerRemoving:Connect(function(player: any)
				failures[player.UserId] = nil
			end)
			for _, player in players:GetPlayers() do
				local profile = store:get(player)
				if profile and not slots:isAttached(player) then
					self:attach(player, function()
						return profile.data
					end)
				end
			end
		end
	end

	function codes.attach(_self: Codes, who: any, data: any)
		slots:attach(who, data)
	end

	function codes.detach(_self: Codes, who: any)
		slots:detach(who)
	end

	function codes.isAttached(_self: Codes, who: any): boolean
		return slots:isAttached(who)
	end

	function codes.refreshAsync(_self: Codes): (boolean, string?)
		local store = codeStore()
		if store == nil then
			loadedAt = clock()
			return true, nil
		end
		local ok, value = pcall(function()
			return store:GetAsync(key)
		end)
		if not ok then
			Log.warn("Codes", "couldn't load runtime codes: " .. tostring(value))
			return false, tostring(value)
		end
		runtimeCodes = readDocument(value)
		loadedAt = clock()
		return true, nil
	end

	function codes.start(self: Codes)
		self:refreshAsync()
		if codeStore() == nil then
			return
		end
		local taskLib: any = options.task or Roblox.task()
		taskLib.spawn(function()
			while true do
				taskLib.wait(refreshInterval)
				self:refreshAsync()
			end
		end)
		local service = messaging()
		if service then
			local ok, err = pcall(function()
				service:SubscribeAsync(TOPIC, function()
					taskLib.spawn(function()
						self:refreshAsync()
					end)
				end)
			end)
			if not ok then
				Log.warn("Codes", "change pings unavailable, polling only: " .. tostring(err))
			end
		end
	end

	function codes.normalize(_self: Codes, text: string): string?
		return Codes.normalize(text)
	end

	function codes.lookup(_self: Codes, code: string): CodeDef?
		return active(configCodes[code]) or active(runtimeCodes[code])
	end

	function codes.hasRedeemed(_self: Codes, who: any, code: string): boolean
		local state = slots:get(who)
		return state ~= nil and state.redeemed[code] ~= nil
	end

	local function claimUse(def: CodeDef): (boolean, string?)
		local store = codeStore()
		if store == nil then
			return true, nil
		end
		local max = def.maxUses :: number
		local exhausted = false
		local ok, err = pcall(function()
			store:UpdateAsync(usesKey(def.code), function(current: any): any
				local used = if type(current) == "number" then current else 0
				if used >= max then
					exhausted = true
					return nil
				end
				exhausted = false
				return used + 1
			end)
		end)
		if not ok then
			Log.warn("Codes", "couldn't claim a use of " .. def.code .. ": " .. tostring(err))
			return false, "unavailable"
		end
		if exhausted then
			return false, "exhausted"
		end
		return true, nil
	end

	function codes.redeemAsync(self: Codes, who: any, text: string): (boolean, string?, Rewards.Applied?)
		local userId = Slots.userIdOf(who)
		local state = slots:get(who)
		if userId == nil or state == nil or not economy:isAttached(who) then
			return false, "notLoaded", nil
		end
		if lockedOut(userId) then
			return false, "tooManyAttempts", nil
		end
		local code = Codes.normalize(text)
		if code == nil then
			noteFailure(userId)
			return false, "invalid", nil
		end
		if busy[userId] then
			return false, "busy", nil
		end
		busy[userId] = true
		local function finish(
			ok: boolean,
			failure: string?,
			applied: Rewards.Applied?
		): (boolean, string?, Rewards.Applied?)
			busy[userId] = nil
			return ok, failure, applied
		end

		local def = self:lookup(code)
		local staticDef = configCodes[code] or runtimeCodes[code]
		if def == nil and staticDef == nil and (loadedAt == nil or clock() - (loadedAt :: number) > missRefreshAge) then
			-- A code the owner just created may not be in this server's cache yet.
			self:refreshAsync()
			def = self:lookup(code)
			staticDef = configCodes[code] or runtimeCodes[code]
		end
		if def == nil then
			noteFailure(userId)
			return finish(false, "unknown", nil)
		end
		local d = def :: CodeDef
		if d.expiresAt and now() >= (d.expiresAt :: number) then
			return finish(false, "expired", nil)
		end
		local current = slots:get(who)
		if current == nil then
			return finish(false, "notLoaded", nil)
		end
		if current.redeemed[code] then
			return finish(false, "redeemed", nil)
		end
		if d.requires then
			local ok, reasonText = (d.requires :: (any) -> (boolean, string?))(who)
			if not ok then
				return finish(false, reasonText or "requirements", nil)
			end
		end
		-- Claim the global use before marking anything: if the player leaves while UpdateAsync
		-- yields, the release save must not carry a redeemed mark for a reward never granted.
		-- busy[userId] blocks a second request on this server and the session lock blocks others.
		if d.maxUses then
			local claimed, failure = claimUse(d)
			if not claimed then
				return finish(false, failure, nil)
			end
			local after = slots:get(who)
			if after == nil or after ~= current or not economy:isAttached(who) then
				Log.warn(
					"Codes",
					"player " .. tostring(userId) .. " left while claiming " .. code .. "; one use is spent"
				)
				return finish(false, "notLoaded", nil)
			end
		end
		-- No yield from here on: mark and grant together.
		current.redeemed[code] = now()
		local applied = Rewards.apply(target, who, d.reward, reason)
		if not applied.ok then
			current.redeemed[code] = nil
			return finish(false, applied.failure or "notLoaded", nil)
		end
		self.Redeemed:Fire(slots:player(who), userId, code, applied)
		return finish(true, nil, applied)
	end

	local function editDocument(edit: (doc: { codes: { [string]: any } }) -> string?): (boolean, string?)
		local store = codeStore()
		if store == nil then
			return false, "noDataStore"
		end
		local editError: string? = nil
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(current: any): any
				local doc: { codes: { [string]: any }, version: number? } = if type(current) == "table"
						and type(current.codes) == "table"
					then current
					else { codes = {} }
				editError = edit(doc)
				if editError then
					return nil
				end
				doc.version = (doc.version or 0) + 1
				return doc
			end)
		end)
		if not ok then
			return false, tostring(err)
		end
		if editError then
			return false, editError
		end
		local service = messaging()
		if service then
			local published, publishError = pcall(function()
				service:PublishAsync(TOPIC, { at = now() })
			end)
			if not published then
				Log.warn(
					"Codes",
					"change ping failed; other servers pick it up on their next refresh: " .. tostring(publishError)
				)
			end
		end
		codes:refreshAsync()
		return true, nil
	end

	function codes.createAsync(_self: Codes, def: CodeDef): (boolean, string?)
		if type(def) ~= "table" then
			return false, "code definition must be a table"
		end
		local copy = table.clone(def)
		copy.code = Codes.normalize(def.code) or tostring(def.code)
		if copy.requires ~= nil then
			return false, "runtime codes can't have a requires function"
		end
		local problems = Codes.validate(copy, target)
		if #problems > 0 then
			return false, table.concat(problems, "; ")
		end
		if configCodes[copy.code] then
			return false, "a config code already uses " .. copy.code
		end
		copy.source = nil
		copy.createdAt = now()
		return editDocument(function(doc)
			if doc.codes[copy.code] and not doc.codes[copy.code].disabled then
				return "code " .. copy.code .. " already exists"
			end
			doc.codes[copy.code] = copy
			return nil
		end)
	end

	function codes.disableAsync(_self: Codes, text: string): (boolean, string?)
		local code = Codes.normalize(text)
		if code == nil then
			return false, "invalid"
		end
		if configCodes[code] then
			return false, "config codes are disabled in config"
		end
		return editDocument(function(doc)
			local existing = doc.codes[code]
			if existing == nil then
				return "no runtime code " .. code
			end
			existing.disabled = true
			return nil
		end)
	end

	function codes.usesAsync(_self: Codes, text: string): (number?, string?)
		local code = Codes.normalize(text)
		local store = codeStore()
		if code == nil or store == nil then
			return nil, if code == nil then "invalid" else "noDataStore"
		end
		local ok, value = pcall(function()
			return store:GetAsync(usesKey(code))
		end)
		if not ok then
			return nil, tostring(value)
		end
		return if type(value) == "number" then value else 0, nil
	end

	function codes.listAsync(self: Codes): { { def: CodeDef, uses: number? } }
		self:refreshAsync()
		local out: { { def: CodeDef, uses: number? } } = {}
		local all: { CodeDef } = {}
		for _, def in configCodes do
			table.insert(all, def)
		end
		for _, def in runtimeCodes do
			table.insert(all, def)
		end
		table.sort(all, function(a: CodeDef, b: CodeDef): boolean
			return a.code < b.code
		end)
		for _, def in all do
			local uses: number? = nil
			if def.maxUses then
				uses = self:usesAsync(def.code)
			end
			table.insert(out, { def = def, uses = uses })
		end
		return out
	end

	function codes.bindNet(self: Codes, context: any?): any
		return Remotes.serve("Codes", self, context)
	end
	return codes
end

return Codes
