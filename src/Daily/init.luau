--!strict
--[[
	Daily: the login-streak reward strip (brief §5.5 "Daily Rewards", §6.6). One claim per day;
	claiming on consecutive days walks the strip, missing a day starts it again at day 1. After
	the last day the strip repeats from `repeatFrom`. Server only; nothing yields.

	  local daily = Shared.Daily.new({
	  	economy = economy,
	  	shop = shop,                                   -- for item rewards (the day-7 skin)
	  	reason = "daily",                              -- declare it in Economy ("earn" or "grant")
	  	days = {
	  		{ currencies = { Wins = 5 } }, { currencies = { Wins = 8 } }, ...,
	  		{ items = { "stilt_candy" }, ifOwned = { Wins = 40 } },
	  	},
	  })
	  daily:bindStore(Profiles)
	  local status = daily:status(player)            -- canClaim, day, streak, nextAt, days
	  local ok, failure, result = daily:claim(player)

	Days are UTC days shifted by `resetHourUtc`. `graceDays` lets a streak survive that many
	missed days (default 0).
]]

local Remotes = require("./Remotes")
local Rewards = require("./Rewards")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Slots = require("./Util/Slots")
local Types = require("./Types")

local DAY = 86400

export type Options = {
	economy: any,
	shop: any?,
	days: { Types.Reward },
	-- Economy reason for currency rewards. Default "daily".
	reason: string?,
	field: string?,
	-- Hour (UTC) the day turns over. Default 0.
	resetHourUtc: number?,
	-- Missed days a streak survives. Default 0.
	graceDays: number?,
	-- Day the strip restarts at after the last day. Default 1.
	repeatFrom: number?,
	analytics: any?,
	now: (() -> number)?,
	players: any?,
}

export type State = {
	-- Consecutive claims in the current run.
	streak: number,
	-- Day index of the last claim; -1 = never.
	lastDay: number,
	-- Claims ever.
	total: number,
}

export type Status = {
	canClaim: boolean,
	-- Strip position (1..#days) the next claim pays, or that today's claim paid.
	day: number,
	-- Streak after the next claim, or the current streak once claimed today.
	streak: number,
	-- The streak was broken; the next claim starts again at day 1.
	broken: boolean,
	-- os.time() when the next claim opens (the next day if already claimed today).
	nextAt: number,
	days: { Types.Reward },
}

export type Daily = {
	-- (player?, userId, day, result)
	Claimed: Signal.Signal<any, number, number, Rewards.Applied>,
	-- (player?, userId, state) once the player's daily state is loaded.
	Attached: Signal.Signal<any, number, State>,
	bindStore: (self: Daily, store: any) -> (),
	attach: (self: Daily, who: any, data: any) -> (),
	detach: (self: Daily, who: any) -> (),
	isAttached: (self: Daily, who: any) -> boolean,
	dayIndex: (self: Daily, time: number?) -> number,
	status: (self: Daily, who: any) -> Status?,
	claim: (self: Daily, who: any) -> (boolean, string?, Rewards.Applied?),

	-- Server: binds this module's remotes (Remotes.daily) and wires the handlers. Once, at startup.
	bindNet: (self: Daily, context: any?) -> any,
}

local Daily = {}

function Daily.newState(): State
	return { streak = 0, lastDay = -1, total = 0 }
end

local function wholeAtLeast(value: any, min: number, default: number): number
	if type(value) == "number" and value == value and value >= min and value < math.huge then
		return math.floor(value)
	end
	return default
end

function Daily.repair(state: any): State
	if type(state) ~= "table" then
		return Daily.newState()
	end
	return {
		streak = wholeAtLeast(state.streak, 0, 0),
		lastDay = wholeAtLeast(state.lastDay, -1, -1),
		total = wholeAtLeast(state.total, 0, 0),
	}
end

-- Strip position for the `streak`-th consecutive claim (pure).
function Daily.position(streak: number, length: number, repeatFrom: number?): number
	local from = math.clamp(repeatFrom or 1, 1, length)
	if streak <= length then
		return math.max(1, streak)
	end
	local loop = length - from + 1
	return from + ((streak - length - 1) % loop)
end

function Daily.new(options: Options): Daily
	local economy = options.economy
	assert(economy ~= nil, "Daily.new: economy is required")
	local days = options.days
	assert(type(days) == "table" and #days > 0, "Daily.new: days must be a non-empty list of rewards")
	for i, reward in days do
		local problems = Rewards.validate(reward, { economy = economy, shop = options.shop })
		assert(#problems == 0, "Daily.new: days[" .. i .. "]: " .. table.concat(problems, "; "))
	end
	local reason = options.reason or "daily"
	local offset = (options.resetHourUtc or 0) * 3600
	local grace = options.graceDays or 0
	local now: () -> number = options.now or os.time
	local slots = Slots.new(options.field or "daily", Daily.newState, Daily.repair)

	local daily = { Claimed = Signal.new(), Attached = slots.Attached } :: Daily

	local function dayOf(time: number): number
		return math.floor((time - offset) / DAY)
	end

	local function nextStreak(state: State, today: number): (number, boolean)
		if state.lastDay >= 0 and today - state.lastDay <= 1 + grace then
			return state.streak + 1, false
		end
		return 1, state.lastDay >= 0
	end

	function daily.bindStore(self: Daily, store: any)
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

	function daily.attach(_self: Daily, who: any, data: any)
		slots:attach(who, data)
	end

	function daily.detach(_self: Daily, who: any)
		slots:detach(who)
	end

	function daily.isAttached(_self: Daily, who: any): boolean
		return slots:isAttached(who)
	end

	function daily.dayIndex(_self: Daily, time: number?): number
		return dayOf(time or now())
	end

	function daily.status(_self: Daily, who: any): Status?
		local state = slots:get(who)
		if state == nil then
			return nil
		end
		local today = dayOf(now())
		local claimed = state.lastDay == today
		local streak, broken
		if claimed then
			streak, broken = state.streak, false
		else
			streak, broken = nextStreak(state, today)
		end
		local nextAt = if claimed then (today + 1) * DAY + offset else now()
		return {
			canClaim = not claimed,
			day = Daily.position(streak, #days, options.repeatFrom),
			streak = streak,
			broken = broken,
			nextAt = nextAt,
			days = days,
		}
	end

	function daily.claim(self: Daily, who: any): (boolean, string?, Rewards.Applied?)
		local state = slots:get(who)
		if state == nil or not economy:isAttached(who) then
			return false, "notLoaded", nil
		end
		local today = dayOf(now())
		if state.lastDay == today then
			return false, "claimed", nil
		end
		local streak = nextStreak(state, today)
		local position = Daily.position(streak, #days, options.repeatFrom)
		local result = Rewards.apply({ economy = economy, shop = options.shop }, who, days[position], reason)
		if not result.ok then
			return false, result.failure, nil
		end
		state.streak = streak
		state.lastDay = today
		state.total += 1
		self.Claimed:Fire(slots:player(who), Slots.userIdOf(who) :: number, position, result)
		local sink = options.analytics
		local player = slots:player(who)
		if sink and player and type(sink.progression) == "function" then
			sink:progression(player, "daily", "complete", position)
		end
		return true, nil, result
	end

	function daily.bindNet(self: Daily, context: any?): any
		return Remotes.serve("Daily", self, context)
	end
	return daily
end

return Daily
