--!strict
--[[
	Events: server-wide timed events (brief §4, §6.4). Two kinds share one scheduler:

	  lobby    opt-in events on a fixed cadence (Stilt Race every 12 minutes, 90 s lobby). Players
	           join and leave during the lobby; the event runs if enough joined.
	  ambient  surprise events everyone in the server is in (Flash flood every 6-10 minutes), with
	           a warning phase instead of a lobby.

	  local events = Shared.Events.new({
	  	mode = "lobby",
	  	every = 12 * 60,                                -- slots aligned to the clock: all servers agree
	  	lobbySeconds = 90,
	  	economy = economy,
	  	events = {
	  		{ id = "race", durationSeconds = 60, minPlayers = 2,
	  		  rewards = { participation = { currencies = { Wins = 2 } },
	  		              placements = { { currencies = { Wins = 10 } }, { currencies = { Wins = 6 } } } },
	  		  run = function(ctx) Race.start(ctx.participants, function(order) ctx.finish({ placements = order }) end) end },
	  	},
	  })
	  events:start()
	  events:join(player)                                -- during the lobby
	  events.StateChanged:Connect(function(state) ... end) -- phase, endsAt, participants

	Phases: idle -> lobby (or warning) -> running -> results -> idle. An event ends when its
	`run` calls ctx.finish(result), or at durationSeconds with whatever result it has. Rewards
	pay with the "event" reason (an earn: multiplied, so a Lucky Events pass doubles them through
	Economy). `reward(player, outcome, place)` overrides the table rewards per player (Stilts pays
	short survivors more).
]]

local Log = require("./Util/Log")
local Remotes = require("./Remotes")
local Rewards = require("./Rewards")
local Rng = require("./Sim/Rng")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Types = require("./Types")

export type Phase = "idle" | "lobby" | "warning" | "running" | "results"

export type Result = {
	-- UserIds in finishing order (1st first). Players not listed get participation only.
	placements: { number }?,
	-- UserIds that get no reward at all (eliminated before the end), if the event uses it.
	excluded: { number }?,
	-- Free-form data for the results screen.
	data: { [string]: any }?,
}

export type Context = {
	id: string,
	def: EventDef,
	participants: { any },
	startedAt: number,
	endsAt: number,
	-- Ends the event now with a result (only the first call counts).
	finish: (result: Result?) -> (),
	isParticipant: (player: any) -> boolean,
}

export type EventDef = {
	id: string,
	nameKey: string?,
	descriptionKey: string?,
	icon: string?,
	durationSeconds: number,
	minPlayers: number?,
	maxPlayers: number?,
	rewards: { participation: Types.Reward?, placements: { Types.Reward }? }?,
	-- Starts the game logic. Must not yield for long (spawn what takes time).
	run: ((ctx: Context) -> ())?,
	-- Per-player reward override; nil falls back to the table rewards.
	reward: ((player: any, outcome: Outcome, place: number?) -> Types.Reward?)?,
	-- Relative chance with rotation = "random". Default 1.
	weight: number?,
}

export type Outcome = {
	id: string,
	participants: { number },
	placements: { number },
	-- UserId -> what landed.
	rewards: { [number]: Rewards.Applied },
	data: { [string]: any },
	cancelled: boolean,
}

-- What clients see. `joined` is filled in per player by the remotes layer.
export type State = {
	phase: Phase,
	eventId: string?,
	-- os.time() the current phase ends; for idle, when the next event opens (if known).
	endsAt: number?,
	participants: number,
	minPlayers: number,
	maxPlayers: number?,
	-- Results of the last event (results phase only).
	placements: { number }?,
	nextEventId: string?,
}

export type Options = {
	events: { EventDef },
	mode: ("lobby" | "ambient")?,
	-- Fixed cadence in seconds (aligned to the clock), or a random gap between min and max.
	every: number?,
	between: { min: number, max: number }?,
	lobbySeconds: number?,
	warningSeconds: number?,
	resultsSeconds: number?,
	rotation: ("sequence" | "random")?,
	seed: string?,
	economy: any?,
	shop: any?,
	rewardReason: string?,
	analytics: any?,
	players: any?,
	task: any?,
	now: (() -> number)?,
}

export type Events = {
	StateChanged: Signal.Signal<State>,
	-- (eventId, participants) when an event starts running.
	Started: Signal.Signal<string, { any }>,
	Finished: Signal.Signal<Outcome>,
	-- (player, joined) when a player joins or leaves the lobby.
	Membership: Signal.Signal<any, boolean>,

	start: (self: Events) -> (),
	stop: (self: Events) -> (),
	state: (self: Events) -> State,
	isParticipant: (self: Events, player: any) -> boolean,
	join: (self: Events, player: any) -> (boolean, string?),
	leave: (self: Events, player: any) -> (boolean, string?),
	-- Opens the lobby (or warning) for an event now, skipping the schedule (admin, convoy portals).
	trigger: (self: Events, eventId: string?) -> (boolean, string?),
	-- The event the next slot opens.
	upcoming: (self: Events) -> (EventDef?, number?),
	event: (self: Events, id: string) -> EventDef?,

	-- Server: binds this module's remotes (Remotes.events) and wires the handlers. Once, at startup.
	bindNet: (self: Events, context: any?) -> any,
}

local Events = {}

-- The event for a slot under sequence rotation (pure).
function Events.sequencePick(defs: { EventDef }, slot: number): EventDef
	return defs[(slot % #defs) + 1]
end

-- The event for a slot under random rotation, the same on every server (pure).
function Events.randomPick(defs: { EventDef }, slot: number, seed: string): EventDef
	local rng = Rng.new(seed .. ":" .. tostring(slot))
	local weights: { [number]: number } = {}
	for i, def in defs do
		weights[i] = def.weight or 1
	end
	local index = rng:weighted(weights)
	return defs[index]
end

function Events.new(options: Options): Events
	local defs = options.events
	assert(type(defs) == "table" and #defs > 0, "Events.new: events must be a non-empty list")
	local mode = options.mode or "lobby"
	assert(mode == "lobby" or mode == "ambient", "Events.new: mode must be lobby or ambient")
	assert(options.every ~= nil or options.between ~= nil, "Events.new: give every (seconds) or between ({ min, max })")
	local every = options.every
	local between = options.between
	if between then
		assert(between.min > 0 and between.max >= between.min, "Events.new: between needs 0 < min <= max")
	end
	local lobbySeconds = options.lobbySeconds or 90
	local warningSeconds = options.warningSeconds or 10
	local resultsSeconds = options.resultsSeconds or 8
	local rotation = options.rotation or "sequence"
	local seed = options.seed or "events"
	local rewardReason = options.rewardReason or "event"
	local now: () -> number = options.now or os.time
	local byId: { [string]: EventDef } = {}
	for _, def in defs do
		assert(type(def.id) == "string" and #def.id > 0, "Events.new: event id must be a non-empty string")
		assert(byId[def.id] == nil, "Events.new: duplicate event " .. def.id)
		assert(
			type(def.durationSeconds) == "number" and def.durationSeconds > 0,
			"Events.new: " .. def.id .. ".durationSeconds must be positive"
		)
		local r = def.rewards
		if r then
			local target: Rewards.Target? = if options.economy
				then { economy = options.economy, shop = options.shop }
				else nil
			for _, reward in { r.participation } do
				local problems = Rewards.validate(reward, target)
				assert(
					#problems == 0,
					"Events.new: " .. def.id .. ".rewards.participation: " .. table.concat(problems, "; ")
				)
			end
			local placementRewards: { Types.Reward } = r.placements or {}
			for i, reward in placementRewards do
				local problems = Rewards.validate(reward, target)
				assert(
					#problems == 0,
					"Events.new: " .. def.id .. ".rewards.placements[" .. i .. "]: " .. table.concat(problems, "; ")
				)
			end
		end
		byId[def.id] = def
	end

	local current: State = { phase = "idle", participants = 0, minPlayers = 0 }
	local currentDef: EventDef? = nil
	local members: { any } = {}
	-- Bumped on every phase change; timers from an older generation do nothing.
	local generation = 0
	local running = false
	local randomSlot = 0
	local nextAt: number? = nil

	local events = {
		StateChanged = Signal.new(),
		Started = Signal.new(),
		Finished = Signal.new(),
		Membership = Signal.new(),
	} :: Events

	local function taskLib(): any
		return options.task or Roblox.task()
	end

	local function players(): any
		return options.players or Roblox.service("Players")
	end

	local function memberIndex(player: any): number?
		for i, member in members do
			if member == player or member.UserId == player.UserId then
				return i
			end
		end
		return nil
	end

	local function publish()
		current.participants = #members
		events.StateChanged:Fire(table.clone(current))
	end

	-- Empties the lobby; everyone who had joined is told they're out (Membership false).
	local function clearMembers()
		local former = members
		members = {}
		if mode == "lobby" then
			for _, player in former do
				events.Membership:Fire(player, false)
			end
		end
	end

	local function pickFor(slot: number): EventDef
		if rotation == "random" then
			return Events.randomPick(defs, slot, seed)
		end
		return Events.sequencePick(defs, slot)
	end

	local scheduleNext: () -> ()
	local openPhase: (def: EventDef) -> ()

	local function setIdle()
		generation += 1
		currentDef = nil
		clearMembers()
		current = { phase = "idle", participants = 0, minPlayers = 0 }
		scheduleNext()
		publish()
	end

	local function distribute(def: EventDef, result: Result?, participants: { any }, cancelled: boolean): Outcome
		local r: Result = result or {}
		local placements: { number } = r.placements or {}
		local excludedList: { number } = r.excluded or {}
		local excluded: { [number]: boolean } = {}
		for _, id in excludedList do
			excluded[id] = true
		end
		local placeOf: { [number]: number } = {}
		for place, id in placements do
			placeOf[id] = place
		end
		local outcome: Outcome = {
			id = def.id,
			participants = {},
			placements = table.clone(placements),
			rewards = {},
			data = r.data or {},
			cancelled = cancelled,
		}
		for _, player in participants do
			table.insert(outcome.participants, player.UserId)
		end
		if cancelled then
			return outcome
		end
		local economy = options.economy
		local inServer: { [number]: any } = {}
		for _, player in players():GetPlayers() do
			inServer[player.UserId] = player
		end
		for _, player in participants do
			local userId = player.UserId
			if inServer[userId] and not excluded[userId] then
				local place = placeOf[userId]
				local reward: Types.Reward? = nil
				if def.reward then
					reward = def.reward(player, outcome, place)
				else
					local tables = def.rewards
					if tables then
						local placementRewards: { Types.Reward } = tables.placements or {}
						reward = Rewards.merge(tables.participation, if place then placementRewards[place] else nil)
					end
				end
				if reward and not Rewards.isEmpty(reward) and economy then
					outcome.rewards[userId] = Rewards.apply(
						{ economy = economy, shop = options.shop },
						player,
						reward :: Types.Reward,
						rewardReason
					)
				end
			end
		end
		return outcome
	end

	local function finish(def: EventDef, gen: number, participants: { any }, result: Result?)
		if gen ~= generation or currentDef ~= def or current.phase ~= "running" then
			return
		end
		generation += 1
		local myGen = generation
		local outcome = distribute(def, result, participants, false)
		current = {
			phase = "results",
			eventId = def.id,
			endsAt = now() + resultsSeconds,
			participants = #participants,
			minPlayers = def.minPlayers or 1,
			maxPlayers = def.maxPlayers,
			placements = outcome.placements,
		}
		publish()
		events.Finished:Fire(outcome)
		local sink = options.analytics
		if sink and type(sink.progression) == "function" then
			-- Path "event.<id>" (Analytics names allow letters, digits, "_", "." and "-"); the
			-- level is the player's place, 0 for unplaced.
			local path = string.sub("event." .. (string.gsub(def.id, "[^%w_%.%-]", ".")), 1, 50)
			for _, player in participants do
				local place = table.find(outcome.placements, player.UserId) or 0
				sink:progression(player, path, "complete", place)
			end
		end
		taskLib().delay(resultsSeconds, function()
			if myGen == generation then
				setIdle()
			end
		end)
	end

	local function startRunning(def: EventDef)
		local participants: { any }
		if mode == "ambient" then
			participants = table.clone(players():GetPlayers())
		else
			participants = table.clone(members)
		end
		if #participants < (def.minPlayers or 1) then
			local outcome = distribute(def, nil, participants, true)
			events.Finished:Fire(outcome)
			setIdle()
			return
		end
		generation += 1
		local gen = generation
		local startedAt = now()
		local endsAt = startedAt + def.durationSeconds
		members = participants
		current = {
			phase = "running",
			eventId = def.id,
			endsAt = endsAt,
			participants = #participants,
			minPlayers = def.minPlayers or 1,
			maxPlayers = def.maxPlayers,
		}
		local finished = false
		local function done(result: Result?)
			if finished then
				return
			end
			finished = true
			finish(def, gen, participants, result)
		end
		publish()
		events.Started:Fire(def.id, participants)
		local ctx: Context = {
			id = def.id,
			def = def,
			participants = participants,
			startedAt = startedAt,
			endsAt = endsAt,
			finish = done,
			isParticipant = function(player: any): boolean
				return table.find(participants, player) ~= nil
			end,
		}
		if def.run then
			local ok, err = xpcall(def.run :: any, debug.traceback, ctx)
			if not ok then
				Log.error("Events", "event " .. def.id .. " failed to start: " .. tostring(err))
				done(nil)
				return
			end
		end
		taskLib().delay(def.durationSeconds, function()
			if gen == generation then
				done(nil)
			end
		end)
	end

	openPhase = function(def: EventDef)
		generation += 1
		local gen = generation
		currentDef = def
		clearMembers()
		local wait = if mode == "lobby" then lobbySeconds else warningSeconds
		current = {
			phase = if mode == "lobby" then "lobby" else "warning",
			eventId = def.id,
			endsAt = now() + wait,
			participants = 0,
			minPlayers = def.minPlayers or 1,
			maxPlayers = def.maxPlayers,
		}
		publish()
		taskLib().delay(wait, function()
			if gen == generation then
				startRunning(def)
			end
		end)
	end

	scheduleNext = function()
		if not running then
			nextAt = nil
			return
		end
		local gen = generation
		local t = now()
		local slotIndex: number
		local at: number
		if every then
			slotIndex = math.floor(t / every) + 1
			at = slotIndex * every
		else
			local b = between :: { min: number, max: number }
			randomSlot += 1
			slotIndex = randomSlot
			local rng = Rng.new(seed .. ":gap:" .. tostring(t) .. ":" .. tostring(randomSlot))
			at = t + rng:range(b.min, b.max)
		end
		nextAt = at
		local def = pickFor(slotIndex)
		current.nextEventId = def.id
		current.endsAt = at
		taskLib().delay(math.max(0, at - t), function()
			if gen == generation and running then
				openPhase(def)
			end
		end)
	end

	function events.start(_self: Events)
		if running then
			return
		end
		running = true
		players().PlayerRemoving:Connect(function(player: any)
			local index = memberIndex(player)
			if index and current.phase == "lobby" then
				table.remove(members, index)
				publish()
			end
		end)
		setIdle()
	end

	function events.stop(_self: Events)
		running = false
		generation += 1
		currentDef = nil
		clearMembers()
		current = { phase = "idle", participants = 0, minPlayers = 0 }
		publish()
	end

	function events.state(_self: Events): State
		local copy = table.clone(current)
		copy.participants = #members
		return copy
	end

	function events.isParticipant(_self: Events, player: any): boolean
		if mode == "ambient" then
			return current.phase == "running" or current.phase == "warning"
		end
		return memberIndex(player) ~= nil
	end

	function events.join(_self: Events, player: any): (boolean, string?)
		if mode ~= "lobby" then
			return false, "notOptIn"
		end
		if current.phase ~= "lobby" then
			return false, "closed"
		end
		if memberIndex(player) then
			return true, nil
		end
		local def = currentDef :: EventDef
		if def.maxPlayers and #members >= (def.maxPlayers :: number) then
			return false, "full"
		end
		table.insert(members, player)
		events.Membership:Fire(player, true)
		publish()
		return true, nil
	end

	function events.leave(_self: Events, player: any): (boolean, string?)
		local index = memberIndex(player)
		if index == nil then
			return false, "notJoined"
		end
		if current.phase ~= "lobby" then
			return false, "closed"
		end
		table.remove(members, index)
		events.Membership:Fire(player, false)
		publish()
		return true, nil
	end

	function events.trigger(_self: Events, eventId: string?): (boolean, string?)
		if current.phase ~= "idle" then
			return false, "busy"
		end
		local def = if eventId then byId[eventId] else pickFor(math.floor(now() / (every or 60)))
		if def == nil then
			return false, "unknown"
		end
		openPhase(def)
		return true, nil
	end

	function events.upcoming(_self: Events): (EventDef?, number?)
		if current.phase ~= "idle" or current.nextEventId == nil then
			return nil, nil
		end
		return byId[current.nextEventId :: string], nextAt
	end

	function events.event(_self: Events, id: string): EventDef?
		return byId[id]
	end

	function events.bindNet(self: Events, context: any?): any
		return Remotes.serve("Events", self, context)
	end
	return events
end

return Events
