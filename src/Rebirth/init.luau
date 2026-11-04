--!strict
--[[
	Rebirth: reset-with-bonus (brief §4, §6.6, §7.7). Configurable requirements, what resets,
	bonus curves applied as Economy multipliers, milestone rewards, and a preview for the
	confirmation screen. Server only; nothing yields.

	  local rebirth = Shared.Rebirth.new({
	  	economy = economy,
	  	progression = progression,
	  	requires = { lifetime = { currency = "Wins", amount = 250 }, gates = { "frostfall" } },
	  	resets = { currencies = { "Wins" }, gates = { keep = {} } },
	  	bonuses = {
	  		wins = { perRebirth = 0.25, linearUntil = 10, decay = 0.85, currencies = { "Wins" } },
	  		height = { perRebirth = 0.05, max = 0.5 },        -- read by the game: rebirth:factor(p, "height")
	  	},
	  	milestones = { [1] = { items = { "stilt_bamboo" } } },
	  	shop = shop,
	  	onRebirth = function(who, count, data) data.upgrades.lunge = 0 end,
	  })
	  rebirth:bindStore(Profiles)

	  local preview = rebirth:preview(player)          -- what resets, what stays, x before/after
	  local ok, failure = rebirth:perform(player)      -- requirements checked here

	A bonus with `currencies` (or `reasons`) is applied to Economy as the multiplier source
	"rebirth.<name>" in group "rebirth", set again every time the player loads. Bonuses without
	them are only read by the game (`factor`).

	Curve: `perRebirth` per rebirth up to `linearUntil` (default: no limit), then each further
	rebirth adds `decay` times the last one (diminishing), never over `max`. The factor is
	1 + bonus. With perRebirth 0.25, linearUntil 10, decay 0.85: 10 rebirths = 3.5x, 11 = 3.71x,
	the limit is 4.92x.
]]

local Remotes = require("./Remotes")
local Rewards = require("./Rewards")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Slots = require("./Util/Slots")
local Types = require("./Types")

export type Curve = {
	perRebirth: number,
	linearUntil: number?,
	decay: number?,
	max: number?,
	-- Apply to Economy for these currencies / earn reasons (nil and nil: not applied).
	currencies: { string }?,
	reasons: { string }?,
}

export type Requirements = {
	lifetime: { currency: string, amount: number }?,
	gates: { string }?,
	awards: { count: number, group: string?, award: string? }?,
	-- Game-specific: return (have, need).
	custom: ((who: any) -> (number, number))?,
}

export type Options = {
	economy: any,
	progression: any?,
	shop: any?,
	-- Field of the profile data holding the state. Default "rebirth".
	field: string?,
	requires: Requirements?,
	resets: {
		currencies: { string }?,
		-- Lock world/biome gates again, except `keep`.
		gates: { keep: { string }? }?,
	}?,
	bonuses: { [string]: Curve }?,
	-- Rebirth count -> reward granted when it is reached.
	milestones: { [number]: Types.Reward }?,
	-- Economy reason for milestone currencies (declare it). Default "rebirthReward".
	rewardReason: string?,
	-- Most rebirths allowed. Default unlimited.
	maxRebirths: number?,
	-- Game-specific resets, after the shared ones and before Rebirthed fires.
	onRebirth: ((who: any, count: number, data: any) -> ())?,
	analytics: any?,
	now: (() -> number)?,
	players: any?,
	task: any?,
}

export type State = {
	count: number,
	-- os.time() of the latest rebirth.
	lastAt: number?,
}

-- `currency` is set on lifetime parts (for the screen's "Earn 5,000 Wins" line).
export type Part = {
	kind: "lifetime" | "gates" | "awards" | "custom",
	have: number,
	need: number,
	currency: string?,
}

export type BonusPreview = { before: number, after: number }

export type Preview = {
	count: number,
	-- 0..1, the least-complete requirement.
	progress: number,
	parts: { Part },
	canRebirth: boolean,
	failure: string?,
	-- Bonus name -> factor now and after the next rebirth.
	bonuses: { [string]: BonusPreview },
	resetsCurrencies: { string },
	resetsGates: boolean,
	keepsGates: { string },
	-- Reward for reaching count + 1, if any.
	milestone: Types.Reward?,
}

export type Summary = {
	count: number,
	reason: string,
	bonuses: { [string]: BonusPreview },
	-- Currency id -> balance taken away.
	reset: { [string]: number },
	milestone: Rewards.Applied?,
}

export type Failure = "notLoaded" | "requirements" | "maxed"

export type Rebirth = {
	-- (player?, userId, summary) after a rebirth is done.
	Rebirthed: Signal.Signal<any, number, Summary>,

	bindStore: (self: Rebirth, store: any) -> (),
	attach: (self: Rebirth, who: any, data: any) -> (),
	detach: (self: Rebirth, who: any) -> (),
	isAttached: (self: Rebirth, who: any) -> boolean,

	count: (self: Rebirth, who: any) -> number,
	-- 1 + bonus for a curve, at the player's count (or at `count`).
	factor: (self: Rebirth, who: any, name: string, count: number?) -> number,
	progress: (self: Rebirth, who: any) -> (number, { Part }),
	canRebirth: (self: Rebirth, who: any) -> (boolean, Failure?),
	preview: (self: Rebirth, who: any) -> Preview?,
	-- `force` skips requirements (Instant Rebirth product, admin). `reason` is for analytics.
	perform: (self: Rebirth, who: any, options: { force: boolean?, reason: string? }?) -> (boolean, Failure?, Summary?),

	-- Server: binds this module's remotes (Remotes.rebirth) and wires the handlers. Once, at startup.
	bindNet: (self: Rebirth, context: any?) -> any,
}

local Rebirth = {}

function Rebirth.newState(): State
	return { count = 0 }
end

function Rebirth.repair(state: any): State
	local count = if type(state) == "table" then state.count else nil
	local lastAt = if type(state) == "table" then state.lastAt else nil
	return {
		count = if type(count) == "number"
				and count == count
				and count >= 0
				and count < math.huge
			then math.floor(count)
			else 0,
		lastAt = if type(lastAt) == "number" and lastAt == lastAt and lastAt >= 0 then lastAt else nil,
	}
end

-- The bonus (not the factor) a curve gives at `count` rebirths.
function Rebirth.bonus(curve: Curve, count: number): number
	local n = math.max(0, math.floor(count))
	local per = curve.perRebirth
	local linear = curve.linearUntil
	local value
	if linear == nil or n <= linear then
		value = per * n
	else
		value = per * linear
		local decay = curve.decay
		if decay and decay > 0 and decay < 1 then
			local extra = n - linear
			value += per * decay * (1 - decay ^ extra) / (1 - decay)
		end
	end
	if curve.max then
		value = math.min(value, curve.max)
	end
	return value
end

function Rebirth.factor(curve: Curve, count: number): number
	return 1 + Rebirth.bonus(curve, count)
end

local function validateCurve(name: string, curve: any)
	assert(type(curve) == "table", "Rebirth.new: bonuses." .. name .. " must be a table")
	local function nonNegative(key: string, required: boolean)
		local v = curve[key]
		if v == nil and not required then
			return
		end
		assert(
			type(v) == "number" and v == v and v >= 0 and v < math.huge,
			"Rebirth.new: bonuses." .. name .. "." .. key .. " must be a number >= 0"
		)
	end
	nonNegative("perRebirth", true)
	nonNegative("linearUntil", false)
	nonNegative("max", false)
	assert(
		curve.decay == nil or (type(curve.decay) == "number" and curve.decay >= 0 and curve.decay < 1),
		"Rebirth.new: bonuses." .. name .. ".decay must be in [0, 1)"
	)
end

function Rebirth.new(options: Options): Rebirth
	local economy = options.economy
	assert(economy ~= nil, "Rebirth.new: economy is required")
	local progression = options.progression
	local field = options.field or "rebirth"
	local now: () -> number = options.now or os.time
	local requires: Requirements = options.requires or {}
	local resets: { currencies: { string }?, gates: { keep: { string }? }? } = options.resets or {}
	local resetCurrencies: { string } = resets.currencies or {}
	local resetGates = resets.gates
	local bonuses: { [string]: Curve } = options.bonuses or {}
	local milestones: { [number]: Types.Reward } = options.milestones or {}
	local rewardReason = options.rewardReason or "rebirthReward"

	for _, currency in resetCurrencies do
		assert(economy:currency(currency), "Rebirth.new: resets unknown currency " .. currency)
	end
	if requires.lifetime then
		assert(
			economy:currency(requires.lifetime.currency),
			"Rebirth.new: requires unknown currency " .. requires.lifetime.currency
		)
	end
	if (requires.gates or requires.awards or resetGates) and progression == nil then
		error("Rebirth.new: gate and award requirements and gate resets need a progression")
	end
	local requiredGates: { string } = requires.gates or {}
	for _, gateId in requiredGates do
		assert(progression:gate(gateId), "Rebirth.new: requires unknown gate " .. gateId)
	end
	for name, curve in bonuses do
		validateCurve(name, curve)
	end
	for count, reward in milestones do
		assert(type(count) == "number" and count >= 1, "Rebirth.new: milestone keys are rebirth counts >= 1")
		local problems = Rewards.validate(reward, { economy = economy, shop = options.shop })
		assert(#problems == 0, "Rebirth.new: milestones[" .. tostring(count) .. "]: " .. table.concat(problems, "; "))
	end

	local slots = Slots.new(field, Rebirth.newState, Rebirth.repair)
	local boundStore: any = nil

	local rebirth = {
		Rebirthed = Signal.new(),
	} :: Rebirth

	local function countOf(who: any): number
		local state = slots:get(who)
		return if state then state.count else 0
	end

	local function applyMultipliers(who: any, count: number)
		for name, curve in bonuses do
			if curve.currencies or curve.reasons then
				economy:setMultiplier(who, "rebirth." .. name, {
					group = "rebirth",
					factor = Rebirth.factor(curve, count),
					currencies = curve.currencies,
					reasons = curve.reasons,
				})
			end
		end
	end

	local function setAttribute(who: any, count: number)
		Slots.setAttribute(slots:player(who), "Rebirths", count)
	end

	slots.Attached:Connect(function(player: any, userId: number, state: State)
		applyMultipliers(player or userId, state.count)
		setAttribute(player or userId, state.count)
	end)

	local function partsFor(who: any): { Part }
		local parts: { Part } = {}
		if requires.lifetime then
			table.insert(parts, {
				kind = "lifetime",
				have = economy:lifetime(who, requires.lifetime.currency),
				need = requires.lifetime.amount,
				currency = requires.lifetime.currency,
			})
		end
		if requires.gates and #requires.gates > 0 then
			local have = 0
			for _, gateId in requires.gates do
				if progression:isUnlocked(who, gateId) then
					have += 1
				end
			end
			table.insert(parts, { kind = "gates", have = have, need = #requires.gates })
		end
		if requires.awards then
			table.insert(parts, {
				kind = "awards",
				have = progression:count(who, { group = requires.awards.group, award = requires.awards.award }),
				need = requires.awards.count,
			})
		end
		if requires.custom then
			local have, need = requires.custom(who)
			table.insert(parts, { kind = "custom", have = have, need = need })
		end
		return parts
	end

	local function fractionOf(parts: { Part }): number
		local fraction = 1
		for _, part in parts do
			fraction = math.min(fraction, if part.need <= 0 then 1 else math.clamp(part.have / part.need, 0, 1))
		end
		return fraction
	end

	local function bonusPreview(count: number): { [string]: BonusPreview }
		local out: { [string]: BonusPreview } = {}
		for name, curve in bonuses do
			out[name] = { before = Rebirth.factor(curve, count), after = Rebirth.factor(curve, count + 1) }
		end
		return out
	end

	function rebirth.bindStore(self: Rebirth, store: any)
		boundStore = store
		slots:bindStore(store)
		local players = options.players
		if players == nil and Roblox.isRoblox() then
			players = Roblox.service("Players")
		end
		if players then
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

	function rebirth.attach(_self: Rebirth, who: any, data: any)
		slots:attach(who, data)
	end

	function rebirth.detach(_self: Rebirth, who: any)
		slots:detach(who)
	end

	function rebirth.isAttached(_self: Rebirth, who: any): boolean
		return slots:isAttached(who)
	end

	function rebirth.count(_self: Rebirth, who: any): number
		return countOf(who)
	end

	function rebirth.factor(_self: Rebirth, who: any, name: string, count: number?): number
		local curve = bonuses[name]
		assert(curve, "Rebirth.factor: unknown bonus " .. name)
		return Rebirth.factor(curve, count or countOf(who))
	end

	function rebirth.progress(_self: Rebirth, who: any): (number, { Part })
		local parts = partsFor(who)
		return fractionOf(parts), parts
	end

	function rebirth.canRebirth(_self: Rebirth, who: any): (boolean, Failure?)
		if not slots:isAttached(who) or not economy:isAttached(who) then
			return false, "notLoaded"
		end
		if options.maxRebirths and countOf(who) >= options.maxRebirths then
			return false, "maxed"
		end
		if fractionOf(partsFor(who)) < 1 then
			return false, "requirements"
		end
		return true, nil
	end

	function rebirth.preview(self: Rebirth, who: any): Preview?
		if not slots:isAttached(who) then
			return nil
		end
		local count = countOf(who)
		local parts = partsFor(who)
		local ok, failure = self:canRebirth(who)
		return {
			count = count,
			progress = fractionOf(parts),
			parts = parts,
			canRebirth = ok,
			failure = failure,
			bonuses = bonusPreview(count),
			resetsCurrencies = table.clone(resetCurrencies),
			resetsGates = resetGates ~= nil,
			keepsGates = if resetGates then table.clone(resetGates.keep or {}) else {},
			milestone = milestones[count + 1],
		}
	end

	function rebirth.perform(
		self: Rebirth,
		who: any,
		performOptions: { force: boolean?, reason: string? }?
	): (boolean, Failure?, Summary?)
		local opts: { force: boolean?, reason: string? } = performOptions or {}
		local state = slots:get(who)
		if state == nil or not economy:isAttached(who) then
			return false, "notLoaded", nil
		end
		if options.maxRebirths and state.count >= options.maxRebirths then
			return false, "maxed", nil
		end
		if not opts.force and fractionOf(partsFor(who)) < 1 then
			return false, "requirements", nil
		end
		local before = state.count
		local reset: { [string]: number } = {}
		for _, currency in resetCurrencies do
			reset[currency] = economy:balance(who, currency)
			economy:set(who, currency, 0, "rebirth", { lifetime = 0 })
		end
		if resetGates and progression then
			progression:resetGates(who, resetGates.keep)
		end
		state.count = before + 1
		state.lastAt = now()
		applyMultipliers(who, state.count)
		setAttribute(who, state.count)

		local milestone: Rewards.Applied? = nil
		local reward = milestones[state.count]
		if reward then
			milestone = Rewards.apply({ economy = economy, shop = options.shop }, who, reward, rewardReason)
		end
		if options.onRebirth then
			options.onRebirth(who, state.count, slots:data(who))
		end
		if progression then
			-- Fast-track gates may open straight away at the new count.
			progression:checkGates(who)
		end

		local summary: Summary = {
			count = state.count,
			reason = opts.reason or "player",
			bonuses = bonusPreview(before),
			reset = reset,
			milestone = milestone,
		}
		local userId = Slots.userIdOf(who) :: number
		self.Rebirthed:Fire(slots:player(who), userId, summary)
		local sink = options.analytics
		local player = slots:player(who)
		if sink and player and type(sink.progression) == "function" then
			sink:progression(player, "rebirth", "complete", state.count)
		end

		-- A rebirth is worth saving now rather than at the next autosave.
		local store = boundStore
		local profile = if store and player then store:get(player) else nil
		if profile then
			local taskLib: any = options.task or (if Roblox.isRoblox() then Roblox.task() else nil)
			if taskLib then
				taskLib.spawn(function()
					profile:saveAsync()
				end)
			end
		end
		return true, nil, summary
	end

	function rebirth.bindNet(self: Rebirth, context: any?): any
		return Remotes.serve("Rebirth", self, context)
	end
	return rebirth
end

return Rebirth
