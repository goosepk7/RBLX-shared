--!strict
--[[
	Progression: stages (Stilts challenges, Car stages), attempts measured on the server,
	completion records, awards (stars or medals), unlock gates and daily featured stages
	(brief §4, §6.4, §6.6, §7.7). Server only; nothing yields.

	  local progression = Shared.Progression.new({
	  	stages = {
	  		{ id = "pier:gapwalk:easy", group = "pier", par = 25, minSeconds = 6,
	  		  awards = { "clear", "underPar", "noDismount" },
	  		  reward = { currency = "Wins", amount = 1, firstClearMultiplier = 2, speedBonus = 0.5 } },
	  	},
	  	gates = {
	  		{ id = "pier" },                                   -- no requirements: open from the start
	  		{ id = "quarry", requires = { lifetime = { currency = "Wins", amount = 60 },
	  		                              awards = { count = 3, group = "pier" } },
	  		  fastTrack = { factor = 0.5 } },                  -- half the Wins after a rebirth
	  	},
	  	economy = economy,
	  	rewardReason = "challenge",
	  	rebirths = function(who) return rebirth:count(who) end,
	  	featured = { count = 3, factor = 2 },
	  })
	  progression:bindStore(Profiles)

	  local attempt = progression:begin(player, "pier:gapwalk:easy")     -- at the start line
	  local outcome = progression:finish(player, attempt.attemptId, {     -- at the finish
	  	completed = true, flags = { noDismount = true },
	  })
	  -- outcome.firstClear, outcome.newBest, outcome.newAwards, outcome.rewards.Wins, outcome.unlocked

	Awards: "clear" is earned by completing, "underPar" by completing within par, and any other
	award id by completing with `flags[id] == true` (or listing it in `awards`). Only the awards a
	stage declares can be earned on it. The award count (stars, medals) is what gates and boards
	read.

	Duration is measured here, between begin and finish, so a client can't report a time. A
	game that times from its own start line passes `durationSeconds`, which may only be shorter
	than the measured time. A clear faster than the stage's `minSeconds` is refused and reported
	to AntiExploit as `progression.tooFast`.
]]

local Log = require("./Util/Log")
local Remotes = require("./Remotes")
local Rng = require("./Sim/Rng")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Slots = require("./Util/Slots")
local Types = require("./Types")

export type StageRecord = Types.StageRecord
export type StageResult = Types.StageResult

export type StageReward = {
	currency: string,
	-- Base payout for a clear.
	amount: number,
	-- Multiplies the payout on the first clear. Default 1 (Stilts: 2).
	firstClearMultiplier: number?,
	-- Extra fraction for beating par, reached in full at `speedBonusAt` x par. Default 0.
	speedBonus: number?,
	-- Fraction of par at which the speed bonus is full. Default 0.5.
	speedBonusAt: number?,
	-- Extra fraction per award earned on this run besides "clear" (Car: stars). Default 0.
	awardBonus: number?,
}

export type StageDef = {
	id: string,
	-- World or biome id, for per-group award counts and gates.
	group: string?,
	-- Display order inside the group.
	order: number?,
	-- Par time in seconds (underPar award and speed bonus).
	par: number?,
	-- Fastest plausible clear in seconds; faster clears are refused. Default 0 (no check).
	minSeconds: number?,
	-- Awards this stage can give. Default { "clear" }.
	awards: { string }?,
	reward: StageReward?,
	-- Gate that must be unlocked to begin the stage.
	gate: string?,
	-- Can be one of the daily featured stages. Default true.
	featured: boolean?,
	-- Free-form data for the game (difficulty, archetype, tags).
	meta: { [string]: any }?,
}

export type GateRequirements = {
	-- Lifetime amount of a currency (since the last rebirth), e.g. 60 lifetime Wins.
	lifetime: { currency: string, amount: number }?,
	-- Awards earned, optionally only in one group and of one award id.
	awards: { count: number, group: string?, award: string? }?,
	-- Distinct stages cleared, optionally in one group.
	clears: { count: number, group: string? }?,
	-- Other gates that must be unlocked first.
	gates: { string }?,
}

export type GateDef = {
	id: string,
	-- No requirements means the gate is open from the start.
	requires: GateRequirements?,
	-- After `rebirths` (default 1) rebirths, the lifetime requirement is multiplied by `factor`.
	fastTrack: { factor: number, rebirths: number? }?,
}

export type FeaturedOptions = {
	-- Stages featured per period. Default 3.
	count: number?,
	-- Reward multiplier on featured stages. Default 2.
	factor: number?,
	-- Seconds per period. Default 86400 (a UTC day).
	period: number?,
	-- Seed for the picks; change it to reshuffle. Default "featured".
	seed: string?,
}

export type Options = {
	stages: { StageDef },
	gates: { GateDef }?,
	-- Field of the profile data holding the state. Default "progression".
	field: string?,
	-- Pays stage rewards and answers lifetime requirements.
	economy: any?,
	-- Economy reason for stage rewards (declare it as "earn"). Default "stage".
	rewardReason: string?,
	-- The player's rebirth count, for fast-track gates.
	rebirths: ((who: any) -> number)?,
	featured: FeaturedOptions?,
	-- AntiExploit registry for implausible results. Default none.
	strikes: any?,
	-- Optional Analytics; receives :progression(player, stageId, status, attemptNumber).
	analytics: any?,
	-- Dependencies.
	now: (() -> number)?,
	clock: (() -> number)?,
	players: any?,
}

export type State = {
	records: { [string]: StageRecord },
	-- Gate id -> os.time() it was unlocked.
	unlocked: { [string]: number },
	-- The current period's featured picks.
	featured: { period: number, stages: { string } }?,
}

export type Attempt = {
	attemptId: string,
	stageId: string,
	userId: number,
	startedAt: number,
	-- Monotonic clock at begin.
	startClock: number,
	-- Which attempt this is for the stage (1 = first ever).
	number: number,
}

export type FinishOptions = {
	completed: boolean,
	flags: { [string]: boolean }?,
	awards: { string }?,
	-- Seconds from the game's own start line; only shorter than the measured time is accepted.
	durationSeconds: number?,
}

export type Outcome = {
	result: StageResult,
	record: StageRecord,
	firstClear: boolean,
	newBest: boolean,
	previousBest: number?,
	newAwards: { string },
	-- Currency id -> amount that reached the balance.
	rewards: { [string]: number },
	-- Payout before Economy multipliers, and its parts.
	payout: number,
	speedBonus: number,
	featured: boolean,
	-- Gates unlocked by this result.
	unlocked: { string },
}

export type Failure =
	"notLoaded"
	| "unknownStage"
	| "locked" -- the stage's gate isn't unlocked
	| "noAttempt" -- finish without a matching begin
	| "implausible" -- faster than minSeconds
	| "invalid" -- malformed result

export type GatePart = {
	kind: "lifetime" | "awards" | "clears" | "gates",
	have: number,
	need: number,
}

export type Progression = {
	-- (player?, userId, attempt)
	Started: Signal.Signal<any, number, Attempt>,
	-- (player?, userId, outcome) for every recorded result, completed or not.
	Finished: Signal.Signal<any, number, Outcome>,
	-- (player?, userId, gateId, reason) reason is "requirements" or what forced it ("product").
	Unlocked: Signal.Signal<any, number, string, string>,
	-- (player?, userId) whenever records, awards or gates change (for replication).
	Changed: Signal.Signal<any, number>,

	bindStore: (self: Progression, store: any) -> (),
	attach: (self: Progression, who: any, data: any) -> (),
	detach: (self: Progression, who: any) -> (),
	isAttached: (self: Progression, who: any) -> boolean,
	getState: (self: Progression, who: any) -> State?,

	stage: (self: Progression, stageId: string) -> StageDef?,
	-- Stages in order, optionally only one group's.
	stages: (self: Progression, group: string?) -> { StageDef },
	gate: (self: Progression, gateId: string) -> GateDef?,
	gates: (self: Progression) -> { GateDef },

	record: (self: Progression, who: any, stageId: string) -> StageRecord?,
	-- Awards earned, optionally filtered by group and award id.
	count: (self: Progression, who: any, filter: { group: string?, award: string? }?) -> number,
	-- Distinct stages cleared, optionally in one group.
	cleared: (self: Progression, who: any, group: string?) -> number,

	isUnlocked: (self: Progression, who: any, gateId: string) -> boolean,
	-- 0..1: the least-complete requirement (a gate needing 60 Wins and 3 awards at 30 Wins and
	-- 3 awards is 0.5). 1 when unlocked.
	gateProgress: (self: Progression, who: any, gateId: string) -> (number, { GatePart }),
	-- Unlocks every gate whose requirements are met. Returns the newly unlocked ids.
	checkGates: (self: Progression, who: any) -> { string },
	-- Unlocks a gate regardless of requirements (products, admin). False if already unlocked.
	unlock: (self: Progression, who: any, gateId: string, reason: string) -> boolean,
	-- Locks every gate except `keep` (Rebirth). Gates without requirements stay open.
	resetGates: (self: Progression, who: any, keep: { string }?) -> (),

	canBegin: (self: Progression, who: any, stageId: string) -> (boolean, Failure?),
	begin: (self: Progression, who: any, stageId: string) -> (Attempt?, Failure?),
	-- The player's attempt in progress, if any.
	current: (self: Progression, who: any) -> Attempt?,
	-- Ends the attempt in progress without recording a clear (left the stage, died out).
	abandon: (self: Progression, who: any) -> (),
	finish: (self: Progression, who: any, attemptId: string, options: FinishOptions) -> (Outcome?, Failure?),
	-- Records a result the game measured itself. Prefer begin/finish.
	submit: (self: Progression, who: any, result: StageResult) -> (Outcome?, Failure?),

	-- This period's featured stage ids for the player and the os.time() the period ends.
	featured: (self: Progression, who: any) -> ({ string }, number),
	isFeatured: (self: Progression, who: any, stageId: string) -> boolean,

	-- Server: binds this module's remotes (Remotes.progression) and wires the handlers. Once, at startup.
	bindNet: (self: Progression, context: any?) -> any,
}

local DEFAULT_AWARDS: { string } = { "clear" }
local DAY = 86400

local Progression = {}

function Progression.newState(): State
	return { records = {}, unlocked = {} }
end

local function isFiniteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function repairRecord(record: any): StageRecord?
	if type(record) ~= "table" then
		return nil
	end
	local awards: { [string]: boolean } = {}
	if type(record.awards) == "table" then
		for id, has in record.awards do
			if type(id) == "string" and has == true then
				awards[id] = true
			end
		end
	end
	return {
		clears = if isFiniteNonNegative(record.clears) then math.floor(record.clears) else 0,
		attempts = if isFiniteNonNegative(record.attempts) then math.floor(record.attempts) else 0,
		bestTime = if isFiniteNonNegative(record.bestTime) then record.bestTime else nil,
		awards = awards,
		firstClearAt = if isFiniteNonNegative(record.firstClearAt) then record.firstClearAt else nil,
		lastAt = if isFiniteNonNegative(record.lastAt) then record.lastAt else nil,
	}
end

-- Brings a loaded state up to date: drops malformed entries, keeps everything valid.
function Progression.repair(state: any): State
	local out = Progression.newState()
	if type(state) ~= "table" then
		return out
	end
	if type(state.records) == "table" then
		for id, record in state.records do
			local fixed = if type(id) == "string" then repairRecord(record) else nil
			if fixed then
				out.records[id] = fixed
			end
		end
	end
	if type(state.unlocked) == "table" then
		for id, at in state.unlocked do
			if type(id) == "string" and isFiniteNonNegative(at) then
				out.unlocked[id] = at
			end
		end
	end
	local featured = state.featured
	if type(featured) == "table" and isFiniteNonNegative(featured.period) and type(featured.stages) == "table" then
		local stages: { string } = {}
		for _, id in featured.stages do
			if type(id) == "string" then
				table.insert(stages, id)
			end
		end
		out.featured = { period = featured.period, stages = stages }
	end
	return out
end

--[[
	The speed bonus fraction for a clear: 0 at or over par, `reward.speedBonus` at or under
	`speedBonusAt` x par, linear between.
]]
function Progression.speedBonus(reward: StageReward, par: number?, duration: number?): number
	local max = reward.speedBonus or 0
	if max <= 0 or par == nil or par <= 0 or duration == nil then
		return 0
	end
	local fullAt = par * math.clamp(reward.speedBonusAt or 0.5, 0, 1)
	if duration >= par then
		return 0
	end
	if duration <= fullAt or par == fullAt then
		return max
	end
	return max * (par - duration) / (par - fullAt)
end

--[[
	The payout for a completed run before Economy multipliers:
	amount x (1 + speed bonus) x (1 + awardBonus x awards besides clear) x first-clear multiplier
	x featured factor. Returns (payout, speedBonusFraction).
]]
function Progression.payout(
	stage: StageDef,
	result: StageResult,
	firstClear: boolean,
	featuredFactor: number?
): (number, number)
	local reward = stage.reward
	if reward == nil or not result.completed then
		return 0, 0
	end
	local speed = if result.flags.noSpeedBonus
		then 0
		else Progression.speedBonus(reward, stage.par, result.durationSeconds)
	local extraAwards = 0
	for _, award in result.awards do
		if award ~= "clear" then
			extraAwards += 1
		end
	end
	local value = reward.amount * (1 + speed) * (1 + (reward.awardBonus or 0) * extraAwards)
	if firstClear then
		value *= reward.firstClearMultiplier or 1
	end
	value *= featuredFactor or 1
	return value, speed
end

-- Awards a completed result earns on `stage` (pure; the rules in the header).
function Progression.awardsFor(stage: StageDef, result: StageResult): { string }
	local earned: { string } = {}
	if not result.completed then
		return earned
	end
	local listed: { [string]: boolean } = {}
	for _, id in result.awards do
		listed[id] = true
	end
	local possible: { string } = stage.awards or DEFAULT_AWARDS
	for _, id in possible do
		local has
		if id == "clear" then
			has = true
		elseif id == "underPar" then
			has = stage.par ~= nil and result.durationSeconds ~= nil and result.durationSeconds <= (stage.par :: number)
		else
			has = result.flags[id] == true or listed[id] == true
		end
		if has then
			table.insert(earned, id)
		end
	end
	return earned
end

local function validateStage(stage: any, seen: { [string]: boolean })
	assert(type(stage) == "table", "Progression.new: each stage must be a table")
	local id = stage.id
	assert(type(id) == "string" and #id > 0 and #id <= 64, "Progression.new: stage id must be 1-64 characters")
	assert(not seen[id], "Progression.new: duplicate stage id " .. id)
	seen[id] = true
	assert(
		stage.par == nil or (isFiniteNonNegative(stage.par) and stage.par > 0),
		"Progression.new: " .. id .. ".par must be positive"
	)
	assert(
		stage.minSeconds == nil or isFiniteNonNegative(stage.minSeconds),
		"Progression.new: " .. id .. ".minSeconds must be >= 0"
	)
	local reward = stage.reward
	if reward ~= nil then
		assert(type(reward.currency) == "string", "Progression.new: " .. id .. ".reward.currency must be a currency id")
		assert(isFiniteNonNegative(reward.amount), "Progression.new: " .. id .. ".reward.amount must be >= 0")
		for _, key in { "firstClearMultiplier", "speedBonus", "speedBonusAt", "awardBonus" } do
			local v = reward[key]
			assert(
				v == nil or isFiniteNonNegative(v),
				"Progression.new: " .. id .. ".reward." .. key .. " must be >= 0"
			)
		end
	end
end

function Progression.new(options: Options): Progression
	assert(type(options.stages) == "table", "Progression.new: stages must be a list")
	local field = options.field or "progression"
	local rewardReason = options.rewardReason or "stage"
	local economy = options.economy
	local now: () -> number = options.now or os.time
	local clock: () -> number = options.clock or os.clock
	local featuredOptions = options.featured
	local featuredCount = if featuredOptions then featuredOptions.count or 3 else 0
	local featuredFactor = if featuredOptions then featuredOptions.factor or 2 else 1
	local featuredPeriod = if featuredOptions then featuredOptions.period or DAY else DAY
	local featuredSeed = if featuredOptions then featuredOptions.seed or "featured" else "featured"
	assert(featuredPeriod > 0, "Progression.new: featured.period must be positive")

	local stageById: { [string]: StageDef } = {}
	local stageList: { StageDef } = {}
	local seen: { [string]: boolean } = {}
	for _, stage in options.stages do
		validateStage(stage, seen)
		stageById[stage.id] = stage
		table.insert(stageList, stage)
	end
	local orderOf: { [string]: number } = {}
	for index, stage in stageList do
		orderOf[stage.id] = index
	end
	table.sort(stageList, function(a: StageDef, b: StageDef): boolean
		local ga, gb = a.group or "", b.group or ""
		if ga ~= gb then
			return ga < gb
		end
		local oa, ob = a.order or orderOf[a.id], b.order or orderOf[b.id]
		if oa ~= ob then
			return oa < ob
		end
		return a.id < b.id
	end)

	local gateById: { [string]: GateDef } = {}
	local gateList: { GateDef } = {}
	local gateDefs: { GateDef } = options.gates or {}
	for _, gate in gateDefs do
		assert(type(gate.id) == "string" and #gate.id > 0, "Progression.new: gate id must be a non-empty string")
		assert(gateById[gate.id] == nil, "Progression.new: duplicate gate id " .. gate.id)
		local fast = gate.fastTrack
		assert(
			fast == nil or (isFiniteNonNegative(fast.factor) and fast.factor <= 1),
			"Progression.new: gate " .. gate.id .. ".fastTrack.factor must be in [0, 1]"
		)
		gateById[gate.id] = gate
		table.insert(gateList, gate)
	end
	for _, gate in gateList do
		local needs: { string } = (gate.requires and gate.requires.gates) or {}
		for _, other in needs do
			assert(gateById[other], "Progression.new: gate " .. gate.id .. " requires unknown gate " .. other)
		end
		local lifetime = gate.requires and gate.requires.lifetime
		if lifetime and economy then
			assert(
				economy:currency(lifetime.currency),
				"Progression.new: gate " .. gate.id .. " uses unknown currency " .. lifetime.currency
			)
		end
	end
	for _, stage in stageList do
		assert(
			stage.gate == nil or gateById[stage.gate],
			"Progression.new: stage " .. stage.id .. " uses unknown gate " .. tostring(stage.gate)
		)
		if stage.reward and economy then
			assert(
				economy:currency(stage.reward.currency),
				"Progression.new: stage " .. stage.id .. " pays unknown currency " .. stage.reward.currency
			)
		end
	end

	local slots = Slots.new(field, Progression.newState, Progression.repair)
	local attempts: { [number]: Attempt } = {}
	local attemptCounter = 0

	local progression = {
		Started = Signal.new(),
		Finished = Signal.new(),
		Unlocked = Signal.new(),
		Changed = Signal.new(),
	} :: Progression

	local function userIdOf(who: any): number?
		return Slots.userIdOf(who)
	end

	-- Analytics paths allow letters, digits, "_", "." and "-" (50 max): "pier:gap:easy" -> "pier.gap.easy".
	local function analytics(who: any, stageId: string, status: string, number: number)
		local sink = options.analytics
		local player = slots:player(who)
		if sink and player and type(sink.progression) == "function" then
			local path = string.sub((string.gsub(stageId, "[^%w_%.%-]", ".")), 1, 50)
			sink:progression(player, path, status, number)
		end
	end

	local function rebirthsOf(who: any): number
		local fn = options.rebirths
		return if fn then fn(who) else 0
	end

	local function countAwards(state: State, filter: { group: string?, award: string? }?): number
		local f: { group: string?, award: string? } = filter or {}
		local total = 0
		for stageId, record in state.records do
			local stage = stageById[stageId]
			if stage and (f.group == nil or stage.group == f.group) then
				for award, has in record.awards do
					if has and (f.award == nil or award == f.award) then
						total += 1
					end
				end
			end
		end
		return total
	end

	local function countCleared(state: State, group: string?): number
		local total = 0
		for stageId, record in state.records do
			local stage = stageById[stageId]
			if stage and record.clears > 0 and (group == nil or stage.group == group) then
				total += 1
			end
		end
		return total
	end

	local function gateOpenByDefault(gate: GateDef): boolean
		local r = gate.requires
		return r == nil
			or (r.lifetime == nil and r.awards == nil and r.clears == nil and (r.gates == nil or #r.gates == 0))
	end

	local function unlockedIn(state: State, gateId: string): boolean
		local gate = gateById[gateId]
		if gate == nil then
			return false
		end
		return state.unlocked[gateId] ~= nil or gateOpenByDefault(gate)
	end

	local function partsFor(who: any, state: State, gate: GateDef): { GatePart }
		local parts: { GatePart } = {}
		local r = gate.requires
		if r == nil then
			return parts
		end
		if r.lifetime then
			local need = r.lifetime.amount
			local fast = gate.fastTrack
			if fast and rebirthsOf(who) >= (fast.rebirths or 1) then
				need = math.ceil(need * fast.factor)
			end
			local have = if economy then economy:lifetime(who, r.lifetime.currency) else 0
			table.insert(parts, { kind = "lifetime", have = have, need = need })
		end
		if r.awards then
			table.insert(parts, {
				kind = "awards",
				have = countAwards(state, { group = r.awards.group, award = r.awards.award }),
				need = r.awards.count,
			})
		end
		if r.clears then
			table.insert(parts, { kind = "clears", have = countCleared(state, r.clears.group), need = r.clears.count })
		end
		if r.gates and #r.gates > 0 then
			local have = 0
			for _, other in r.gates do
				if unlockedIn(state, other) then
					have += 1
				end
			end
			table.insert(parts, { kind = "gates", have = have, need = #r.gates })
		end
		return parts
	end

	local function fractionOf(parts: { GatePart }): number
		local fraction = 1
		for _, part in parts do
			local f = if part.need <= 0 then 1 else math.clamp(part.have / part.need, 0, 1)
			fraction = math.min(fraction, f)
		end
		return fraction
	end

	local function setStarsAttribute(who: any, state: State)
		Slots.setAttribute(slots:player(who), "Progression_Awards", countAwards(state))
	end

	local function changed(who: any, state: State)
		setStarsAttribute(who, state)
		local id = userIdOf(who) :: number
		progression.Changed:Fire(slots:player(who), id)
	end

	local function checkGatesFor(who: any, state: State): { string }
		local newly: { string } = {}
		-- Repeat so a gate that requires another gate opens in the same pass.
		local progress = true
		while progress do
			progress = false
			for _, gate in gateList do
				if state.unlocked[gate.id] == nil and not gateOpenByDefault(gate) then
					if fractionOf(partsFor(who, state, gate)) >= 1 then
						state.unlocked[gate.id] = now()
						table.insert(newly, gate.id)
						progress = true
					end
				end
			end
		end
		local id = userIdOf(who) :: number
		for _, gateId in newly do
			progression.Unlocked:Fire(slots:player(who), id, gateId, "requirements")
		end
		return newly
	end

	function progression.bindStore(self: Progression, store: any)
		slots:bindStore(store)
		local players = options.players
		if players == nil and Roblox.isRoblox() then
			players = Roblox.service("Players")
		end
		if players then
			players.PlayerRemoving:Connect(function(player: any)
				attempts[player.UserId] = nil
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

	slots.Attached:Connect(function(player: any, userId: number, state: State)
		local who: any = player or userId
		checkGatesFor(who, state)
		setStarsAttribute(who, state)
	end)

	-- Users whose result is being recorded: their gates are checked once, after the reward.
	local recording: { [number]: boolean } = {}

	if economy then
		-- A lifetime gate can open on any earning.
		economy.Changed:Connect(function(player: any, userId: number)
			local state = slots:get(userId)
			if state and not recording[userId] then
				local newly = checkGatesFor(player or userId, state)
				if #newly > 0 then
					changed(player or userId, state)
				end
			end
		end)
	end

	function progression.attach(_self: Progression, who: any, data: any)
		slots:attach(who, data)
	end

	function progression.detach(_self: Progression, who: any)
		local id = userIdOf(who)
		if id then
			attempts[id] = nil
		end
		slots:detach(who)
	end

	function progression.isAttached(_self: Progression, who: any): boolean
		return slots:isAttached(who)
	end

	function progression.getState(_self: Progression, who: any): State?
		return slots:get(who)
	end

	function progression.stage(_self: Progression, stageId: string): StageDef?
		return stageById[stageId]
	end

	function progression.stages(_self: Progression, group: string?): { StageDef }
		local out: { StageDef } = {}
		for _, stage in stageList do
			if group == nil or stage.group == group then
				table.insert(out, stage)
			end
		end
		return out
	end

	function progression.gate(_self: Progression, gateId: string): GateDef?
		return gateById[gateId]
	end

	function progression.gates(_self: Progression): { GateDef }
		return table.clone(gateList)
	end

	function progression.record(_self: Progression, who: any, stageId: string): StageRecord?
		local state = slots:get(who)
		return if state then state.records[stageId] else nil
	end

	function progression.count(_self: Progression, who: any, filter: { group: string?, award: string? }?): number
		local state = slots:get(who)
		return if state then countAwards(state, filter) else 0
	end

	function progression.cleared(_self: Progression, who: any, group: string?): number
		local state = slots:get(who)
		return if state then countCleared(state, group) else 0
	end

	function progression.isUnlocked(_self: Progression, who: any, gateId: string): boolean
		local state = slots:get(who)
		return state ~= nil and unlockedIn(state, gateId)
	end

	function progression.gateProgress(_self: Progression, who: any, gateId: string): (number, { GatePart })
		local gate = gateById[gateId]
		local state = slots:get(who)
		if gate == nil or state == nil then
			return 0, {}
		end
		local parts = partsFor(who, state, gate)
		if unlockedIn(state, gateId) then
			return 1, parts
		end
		return fractionOf(parts), parts
	end

	function progression.checkGates(_self: Progression, who: any): { string }
		local state = slots:get(who)
		if state == nil then
			return {}
		end
		local newly = checkGatesFor(who, state)
		if #newly > 0 then
			changed(who, state)
		end
		return newly
	end

	function progression.unlock(_self: Progression, who: any, gateId: string, reason: string): boolean
		local state = slots:get(who)
		assert(gateById[gateId], "Progression.unlock: unknown gate " .. gateId)
		if state == nil or unlockedIn(state, gateId) then
			return false
		end
		state.unlocked[gateId] = now()
		progression.Unlocked:Fire(slots:player(who), userIdOf(who) :: number, gateId, reason)
		checkGatesFor(who, state)
		changed(who, state)
		return true
	end

	function progression.resetGates(_self: Progression, who: any, keep: { string }?)
		local state = slots:get(who)
		if state == nil then
			return
		end
		local kept: { [string]: number } = {}
		local keepList: { string } = keep or {}
		for _, gateId in keepList do
			if state.unlocked[gateId] then
				kept[gateId] = state.unlocked[gateId]
			end
		end
		state.unlocked = kept
		state.featured = nil
		changed(who, state)
	end

	function progression.canBegin(_self: Progression, who: any, stageId: string): (boolean, Failure?)
		local state = slots:get(who)
		if state == nil then
			return false, "notLoaded"
		end
		local stage = stageById[stageId]
		if stage == nil then
			return false, "unknownStage"
		end
		if stage.gate and not unlockedIn(state, stage.gate) then
			return false, "locked"
		end
		return true, nil
	end

	function progression.begin(self: Progression, who: any, stageId: string): (Attempt?, Failure?)
		local ok, failure = self:canBegin(who, stageId)
		if not ok then
			return nil, failure :: any
		end
		local state = slots:get(who) :: State
		local userId = userIdOf(who) :: number
		if attempts[userId] then
			self:abandon(who)
		end
		local record = state.records[stageId]
		if record == nil then
			record = { clears = 0, attempts = 0, awards = {} }
			state.records[stageId] = record
		end
		local r = record :: StageRecord
		r.attempts += 1
		r.lastAt = now()
		attemptCounter += 1
		local attempt: Attempt = {
			attemptId = string.format("%d-%d-%d", userId, now(), attemptCounter),
			stageId = stageId,
			userId = userId,
			startedAt = now(),
			startClock = clock(),
			number = r.attempts,
		}
		attempts[userId] = attempt
		self.Started:Fire(slots:player(who), userId, attempt)
		analytics(who, stageId, "start", attempt.number)
		return attempt, nil
	end

	function progression.current(_self: Progression, who: any): Attempt?
		local id = userIdOf(who)
		return if id then attempts[id] else nil
	end

	function progression.abandon(_self: Progression, who: any)
		local id = userIdOf(who)
		local attempt = if id then attempts[id] else nil
		if attempt == nil then
			return
		end
		attempts[id :: number] = nil
		analytics(who, attempt.stageId, "fail", attempt.number)
	end

	local function record(self: Progression, who: any, result: StageResult, attemptNumber: number): (Outcome?, Failure?)
		local state = slots:get(who)
		if state == nil then
			return nil, "notLoaded"
		end
		local stage = stageById[result.stageId]
		if stage == nil then
			return nil, "unknownStage"
		end
		local userId = userIdOf(who) :: number
		if result.completed then
			local duration = result.durationSeconds
			if duration == nil or not isFiniteNonNegative(duration) then
				return nil, "invalid"
			end
			if stage.minSeconds and duration < (stage.minSeconds :: number) then
				local strikes = options.strikes
				local player = slots:player(who)
				if strikes and player then
					strikes:strike(
						player,
						"progression.tooFast",
						string.format("%s in %.2f s (min %.2f s)", stage.id, duration, stage.minSeconds :: number)
					)
				end
				Log.warn(
					"Progression",
					string.format("refused %s for %d: %.2f s is under the minimum", stage.id, userId, duration)
				)
				return nil, "implausible"
			end
		end

		local existing = state.records[stage.id]
		if existing == nil then
			existing = { clears = 0, attempts = 0, awards = {} }
			state.records[stage.id] = existing
		end
		local rec = existing :: StageRecord
		if attemptNumber == 0 then
			-- A submit without begin counts its own attempt.
			rec.attempts += 1
		end
		rec.lastAt = now()

		local earned = Progression.awardsFor(stage, result)
		result.awards = earned
		local firstClear = result.completed and rec.clears == 0
		local previousBest = rec.bestTime
		local newBest = false
		local newAwards: { string } = {}
		local rewards: { [string]: number } = {}
		local payout, speed = 0, 0
		local isFeatured = self:isFeatured(who, stage.id)
		if result.completed then
			rec.clears += 1
			if firstClear then
				rec.firstClearAt = now()
			end
			local duration = result.durationSeconds :: number
			if previousBest == nil or duration < previousBest then
				rec.bestTime = duration
				newBest = true
			end
			for _, award in earned do
				if not rec.awards[award] then
					rec.awards[award] = true
					table.insert(newAwards, award)
				end
			end
			payout, speed = Progression.payout(stage, result, firstClear, if isFeatured then featuredFactor else 1)
			local reward = stage.reward
			if reward and payout > 0 and economy then
				recording[userId] = true
				local granted = economy:earn(who, reward.currency, payout, rewardReason)
				recording[userId] = nil
				rewards[reward.currency] = granted
			end
		end
		local unlocked = checkGatesFor(who, state)
		local outcome: Outcome = {
			result = result,
			record = table.clone(rec),
			firstClear = firstClear,
			newBest = newBest,
			previousBest = previousBest,
			newAwards = newAwards,
			rewards = rewards,
			payout = payout,
			speedBonus = speed,
			featured = isFeatured,
			unlocked = unlocked,
		}
		changed(who, state)
		self.Finished:Fire(slots:player(who), userId, outcome)
		analytics(who, stage.id, if result.completed then "complete" else "fail", math.max(attemptNumber, rec.attempts))
		return outcome, nil
	end

	function progression.finish(
		self: Progression,
		who: any,
		attemptId: string,
		finishOptions: FinishOptions
	): (Outcome?, Failure?)
		local userId = userIdOf(who)
		local attempt = if userId then attempts[userId] else nil
		if attempt == nil or attempt.attemptId ~= attemptId then
			return nil, "noAttempt"
		end
		if type(finishOptions) ~= "table" or type(finishOptions.completed) ~= "boolean" then
			return nil, "invalid"
		end
		attempts[userId :: number] = nil
		local measured = math.max(0, clock() - attempt.startClock)
		local duration = measured
		local reported = finishOptions.durationSeconds
		if reported ~= nil then
			if not isFiniteNonNegative(reported) then
				return nil, "invalid"
			end
			duration = math.min(measured, reported)
		end
		local flags: { [string]: boolean } = {}
		local given: { [string]: boolean } = finishOptions.flags or {}
		for key, value in given do
			if type(key) == "string" and value == true then
				flags[key] = true
			end
		end
		local result: StageResult = {
			stageId = attempt.stageId,
			userId = attempt.userId,
			attemptId = attempt.attemptId,
			completed = finishOptions.completed,
			startedAt = attempt.startedAt,
			finishedAt = now(),
			durationSeconds = if finishOptions.completed then duration else nil,
			parSeconds = (stageById[attempt.stageId] :: StageDef).par,
			awards = table.clone(finishOptions.awards or {}),
			flags = flags,
		}
		return record(self, who, result, attempt.number)
	end

	function progression.submit(self: Progression, who: any, result: StageResult): (Outcome?, Failure?)
		if type(result) ~= "table" or type(result.stageId) ~= "string" or type(result.completed) ~= "boolean" then
			return nil, "invalid"
		end
		if result.userId ~= userIdOf(who) then
			return nil, "invalid"
		end
		local copy: StageResult = table.clone(result)
		copy.awards = table.clone(result.awards or {})
		copy.flags = table.clone(result.flags or {})
		return record(self, who, copy, 0)
	end

	function progression.featured(_self: Progression, who: any): ({ string }, number)
		local period = math.floor(now() / featuredPeriod)
		local endsAt = (period + 1) * featuredPeriod
		local state = slots:get(who)
		if state == nil or featuredCount <= 0 then
			return {}, endsAt
		end
		local current = state.featured
		if current and current.period == period then
			return table.clone(current.stages), endsAt
		end
		local pool: { string } = {}
		for _, stage in stageList do
			if stage.featured ~= false and (stage.gate == nil or unlockedIn(state, stage.gate)) then
				table.insert(pool, stage.id)
			end
		end
		local rng = Rng.new(string.format("%s:%d:%d", featuredSeed, period, userIdOf(who) :: number))
		local picks: { string } = {}
		for _ = 1, math.min(featuredCount, #pool) do
			local index = rng:int(1, #pool)
			table.insert(picks, table.remove(pool, index) :: string)
		end
		state.featured = { period = period, stages = picks }
		return table.clone(picks), endsAt
	end

	function progression.isFeatured(self: Progression, who: any, stageId: string): boolean
		if featuredCount <= 0 then
			return false
		end
		local picks = self:featured(who)
		return table.find(picks, stageId) ~= nil
	end

	function progression.bindNet(self: Progression, context: any?): any
		return Remotes.serve("Progression", self, context)
	end
	return progression
end

return Progression
