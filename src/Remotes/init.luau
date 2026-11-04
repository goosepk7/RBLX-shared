--!strict
--[[
	Remotes: the Net definitions for the v0.2 server modules, one namespace each, so the server
	side (`module:bindNet()`) and the client side (`Remotes.client("Shop")`, used by the shared
	screens) always agree.

	  -- Server, at startup, after building the modules:
	  shop:bindNet()            -- creates ReplicatedStorage.RBLXSharedNet.SharedShop.*
	  -- Client:
	  local remotes = Shared.Remotes.client("Shop")
	  local result = remotes.Buy:invokeAsync("skin_neon")

	Client-to-server payloads are validated (ids are short strings), every request is rate
	limited, and responses are plain tables. Nothing a client sends decides an outcome: buying,
	rebirthing, claiming, redeeming and joining are all checked on the server.
]]

local Net = require("./Net")

local S = Net.Schema

local Remotes = {}

-- Namespace names, prefixed so they never collide with a game's own namespaces.
Remotes.NAMESPACES = table.freeze({
	Progression = "SharedProgression",
	Rebirth = "SharedRebirth",
	Daily = "SharedDaily",
	Shop = "SharedShop",
	Codes = "SharedCodes",
	Leaderboards = "SharedLeaderboards",
	Badges = "SharedBadges",
	Events = "SharedEvents",
	Tutorial = "SharedTutorial",
})

local ID = S.string({ minLength = 1, maxLength = 64, pattern = "^[%w_:%.%-]+$" })
local SLOW = { rate = 2, burst = 4 }
local NORMAL = { rate = 5, burst = 10 }

export type ProgressionRemotes = {
	GetState: Net.ClientFunction<nil, any>,
	State: Net.ServerEvent<any>,
}

export type RebirthRemotes = {
	Preview: Net.ClientFunction<nil, any>,
	Rebirth: Net.ClientFunction<nil, any>,
	-- Everyone: { userId, name, count } for the server banner.
	Rebirthed: Net.ServerEvent<any>,
}

export type DailyRemotes = {
	Status: Net.ClientFunction<nil, any>,
	Claim: Net.ClientFunction<nil, any>,
	-- The player: today's claim is open (sent once the profile loads).
	Available: Net.ServerEvent<any>,
}

export type ShopRemotes = {
	GetState: Net.ClientFunction<nil, any>,
	Buy: Net.ClientFunction<string, any>,
	Equip: Net.ClientFunction<string, any>,
	Unequip: Net.ClientFunction<string, any>,
	Prompt: Net.ClientFunction<{ kind: string, key: string }, any>,
	State: Net.ServerEvent<any>,
	Confirmed: Net.ServerEvent<any>,
}

export type CodesRemotes = {
	Redeem: Net.ClientFunction<string, any>,
}

export type LeaderboardsRemotes = {
	Get: Net.ClientFunction<string, any>,
	-- Everyone: the board id whose top changed.
	Updated: Net.ServerEvent<string>,
}

export type BadgesRemotes = {
	-- The player: { key }.
	Earned: Net.ServerEvent<any>,
	-- Everyone: { key, userId, name } for badges marked announce.
	Announced: Net.ServerEvent<any>,
}

export type EventsRemotes = {
	GetState: Net.ClientFunction<nil, any>,
	Join: Net.ClientFunction<nil, any>,
	Leave: Net.ClientFunction<nil, any>,
	-- Everyone: the event state (phase, eventId, endsAt, participants, ...).
	State: Net.ServerEvent<any>,
	-- The player: whether they're in the current event (joined, left, dropped, or it ended).
	Joined: Net.ServerEvent<boolean>,
	-- Everyone: { eventId, cancelled, participants, placements } when an event ends.
	Finished: Net.ServerEvent<any>,
}

export type TutorialRemotes = {
	GetState: Net.ClientFunction<nil, any>,
	-- The client finished showing a step.
	Step: Net.ClientFunction<string, any>,
	Skip: Net.ClientFunction<nil, any>,
}

function Remotes.progression(): ProgressionRemotes
	return {
		GetState = Net.clientFunction(S.none(), S.any(), { rateLimit = NORMAL }),
		State = Net.serverEvent(S.any()),
	}
end

function Remotes.rebirth(): RebirthRemotes
	return {
		Preview = Net.clientFunction(S.none(), S.any(), { rateLimit = NORMAL }),
		Rebirth = Net.clientFunction(S.none(), S.any(), { rateLimit = SLOW }),
		Rebirthed = Net.serverEvent(S.any()),
	}
end

function Remotes.daily(): DailyRemotes
	return {
		Status = Net.clientFunction(S.none(), S.any(), { rateLimit = NORMAL }),
		Claim = Net.clientFunction(S.none(), S.any(), { rateLimit = SLOW }),
		Available = Net.serverEvent(S.any()),
	}
end

function Remotes.shop(): ShopRemotes
	return {
		GetState = Net.clientFunction(S.none(), S.any(), { rateLimit = NORMAL }),
		Buy = Net.clientFunction(ID, S.any(), { rateLimit = NORMAL }),
		Equip = Net.clientFunction(ID, S.any(), { rateLimit = NORMAL }),
		Unequip = Net.clientFunction(S.string({ minLength = 1, maxLength = 32, pattern = "^[%w_]+$" }), S.any(), {
			rateLimit = NORMAL,
		}),
		Prompt = Net.clientFunction(
			S.struct({ kind = S.enum({ "product", "pass" }), key = ID }),
			S.any(),
			{ rateLimit = SLOW }
		) :: any,
		State = Net.serverEvent(S.any()),
		Confirmed = Net.serverEvent(S.any()),
	}
end

function Remotes.codes(): CodesRemotes
	return {
		Redeem = Net.clientFunction(S.string({ minLength = 1, maxLength = 64 }), S.any(), {
			rateLimit = { rate = 1, burst = 3 },
		}),
	}
end

function Remotes.leaderboards(): LeaderboardsRemotes
	return {
		Get = Net.clientFunction(ID, S.any(), { rateLimit = NORMAL }),
		Updated = Net.serverEvent(ID),
	}
end

function Remotes.badges(): BadgesRemotes
	return {
		Earned = Net.serverEvent(S.any()),
		Announced = Net.serverEvent(S.any()),
	}
end

function Remotes.events(): EventsRemotes
	return {
		GetState = Net.clientFunction(S.none(), S.any(), { rateLimit = NORMAL }),
		Join = Net.clientFunction(S.none(), S.any(), { rateLimit = SLOW }),
		Leave = Net.clientFunction(S.none(), S.any(), { rateLimit = SLOW }),
		State = Net.serverEvent(S.any()),
		Joined = Net.serverEvent(S.boolean()),
		Finished = Net.serverEvent(S.any()),
	}
end

function Remotes.tutorial(): TutorialRemotes
	return {
		GetState = Net.clientFunction(S.none(), S.any(), { rateLimit = NORMAL }),
		Step = Net.clientFunction(ID, S.any(), { rateLimit = NORMAL }),
		Skip = Net.clientFunction(S.none(), S.any(), { rateLimit = SLOW }),
	}
end

local FACTORIES: { [string]: () -> any } = {
	Progression = Remotes.progression,
	Rebirth = Remotes.rebirth,
	Daily = Remotes.daily,
	Shop = Remotes.shop,
	Codes = Remotes.codes,
	Leaderboards = Remotes.leaderboards,
	Badges = Remotes.badges,
	Events = Remotes.events,
	Tutorial = Remotes.tutorial,
}

--[[
	Fresh definitions for a module, bound into its namespace on `context` (default: Net's default
	context for this side). The server modules' bindNet calls this; clients call it through
	Remotes.client. Each side binds a module's namespace once.
]]
function Remotes.bind(module: string, context: Net.Context?): any
	local factory = FACTORIES[module]
	assert(factory, "Remotes.bind: unknown module " .. tostring(module))
	return Net.namespace(Remotes.NAMESPACES[module], factory(), { context = context })
end

local clientCache: { [string]: any } = setmetatable({}, { __mode = "k" }) :: any

-- The client side of a module's remotes, bound once per context and cached.
function Remotes.client(module: string, context: Net.Context?): any
	local ctx = context or Net.getDefaultContext()
	local key = tostring(ctx) .. ":" .. module
	local existing = clientCache[key]
	if existing then
		return existing
	end
	local bound = Remotes.bind(module, ctx)
	clientCache[key] = bound
	return bound
end

--[[ Server side ]]

local function nameOf(player: any): string?
	return if type(player) == "table" or typeof(player) == "Instance" then player.Name else nil
end

-- Wraps a module's (ok, failure, extra) return as the plain table clients receive.
local function result(ok: any, failure: any, extra: { [string]: any }?): { [string]: any }
	local out: { [string]: any } = { ok = ok == true, failure = if ok == true then nil else failure or "error" }
	if extra then
		for key, value in extra do
			out[key] = value
		end
	end
	return out
end

local function progressionView(progression: any, who: any): any
	local state = progression:getState(who)
	if state == nil then
		return nil
	end
	local featured, featuredEndsAt = progression:featured(who)
	local gates: { [string]: any } = {}
	for _, gate in progression:gates() do
		local progress = progression:gateProgress(who, gate.id)
		gates[gate.id] = { unlocked = progression:isUnlocked(who, gate.id), progress = progress }
	end
	return {
		records = state.records,
		unlocked = state.unlocked,
		gates = gates,
		featured = featured,
		featuredEndsAt = featuredEndsAt,
	}
end

local SERVERS: { [string]: (instance: any, remotes: any) -> () } = {}

function SERVERS.Progression(progression: any, remotes: any)
	remotes.GetState:handle(function(player: Player)
		return progressionView(progression, player)
	end)
	progression.Changed:Connect(function(player: any, _userId: number)
		if player then
			local view = progressionView(progression, player)
			if view then
				remotes.State:fire(player, view)
			end
		end
	end)
end

function SERVERS.Rebirth(rebirth: any, remotes: any)
	remotes.Preview:handle(function(player: Player)
		return rebirth:preview(player)
	end)
	remotes.Rebirth:handle(function(player: Player)
		local ok, failure, summary = rebirth:perform(player)
		return result(ok, failure, { summary = summary })
	end)
	rebirth.Rebirthed:Connect(function(player: any, userId: number, summary: any)
		remotes.Rebirthed:fireAll({ userId = userId, name = nameOf(player), count = summary.count })
	end)
end

function SERVERS.Daily(daily: any, remotes: any)
	remotes.Status:handle(function(player: Player)
		return daily:status(player)
	end)
	remotes.Claim:handle(function(player: Player)
		local ok, failure, applied = daily:claim(player)
		return result(ok, failure, { applied = applied, status = daily:status(player) })
	end)
	daily.Attached:Connect(function(player: any, _userId: number)
		if player then
			local status = daily:status(player)
			if status and status.canClaim then
				remotes.Available:fire(player, status)
			end
		end
	end)
end

function SERVERS.Shop(shop: any, remotes: any)
	remotes.GetState:handle(function(player: Player)
		return shop:snapshot(player)
	end)
	remotes.Buy:handle(function(player: Player, itemId: string)
		local ok, failure, level = shop:buy(player, itemId)
		return result(ok, failure, { level = level })
	end)
	remotes.Equip:handle(function(player: Player, itemId: string)
		local ok, failure = shop:equip(player, itemId)
		return result(ok, failure)
	end)
	remotes.Unequip:handle(function(player: Player, slot: string)
		if not shop:isAttached(player) then
			return result(false, "notLoaded")
		end
		shop:unequip(player, slot)
		return result(true)
	end)
	remotes.Prompt:handle(function(player: Player, request: { kind: string, key: string })
		local ok, failure = shop:prompt(player, request.kind :: any, request.key)
		return result(ok, failure)
	end)
	shop.Changed:Connect(function(player: any, _userId: number)
		if player then
			local snapshot = shop:snapshot(player)
			if snapshot then
				remotes.State:fire(player, snapshot)
			end
		end
	end)
	shop.Confirmed:Connect(function(player: any, _userId: number, kind: string, key: string, details: any)
		if player then
			remotes.Confirmed:fire(player, { kind = kind, key = key, details = details })
		end
	end)
end

function SERVERS.Codes(codes: any, remotes: any)
	remotes.Redeem:handle(function(player: Player, text: string)
		local ok, failure, applied = codes:redeemAsync(player, text)
		return result(ok, failure, { applied = applied })
	end)
end

function SERVERS.Leaderboards(boards: any, remotes: any)
	remotes.Get:handle(function(player: Player, boardId: string): any
		if boards:board(boardId) == nil then
			return nil
		end
		return {
			board = boards:get(boardId),
			you = { rank = boards:rankOf(player, boardId), value = boards:valueOf(player, boardId) },
		}
	end)
	boards.Updated:Connect(function(boardId: string)
		remotes.Updated:fireAll(boardId)
	end)
end

function SERVERS.Badges(badges: any, remotes: any)
	badges.Earned:Connect(function(player: any, userId: number, def: any)
		if player then
			remotes.Earned:fire(player, { key = def.key })
		end
		if def.announce then
			remotes.Announced:fireAll({ key = def.key, userId = userId, name = nameOf(player) })
		end
	end)
end

function SERVERS.Events(events: any, remotes: any)
	local function view(player: Player): any
		local state = table.clone(events:state())
		state.joined = events:isParticipant(player)
		return state
	end
	remotes.GetState:handle(view)
	remotes.Join:handle(function(player: Player)
		local ok, failure = events:join(player)
		return result(ok, failure, { state = view(player) })
	end)
	remotes.Leave:handle(function(player: Player)
		local ok, failure = events:leave(player)
		return result(ok, failure, { state = view(player) })
	end)
	events.StateChanged:Connect(function(state: any)
		remotes.State:fireAll(state)
	end)
	events.Finished:Connect(function(outcome: any)
		remotes.Finished:fireAll({
			eventId = outcome.id,
			cancelled = outcome.cancelled,
			participants = outcome.participants,
			placements = outcome.placements,
		})
	end)
	events.Membership:Connect(function(player: any, joined: boolean)
		if type(player) == "table" or typeof(player) == "Instance" then
			remotes.Joined:fire(player, joined)
		end
	end)
end

function SERVERS.Tutorial(tutorial: any, remotes: any)
	remotes.GetState:handle(function(player: Player)
		return tutorial:status(player)
	end)
	remotes.Step:handle(function(player: Player, stepId: string)
		local ok, failure = tutorial:complete(player, stepId)
		return result(ok, failure, { status = tutorial:status(player) })
	end)
	remotes.Skip:handle(function(player: Player)
		local ok, failure = tutorial:skip(player)
		return result(ok, failure, { status = tutorial:status(player) })
	end)
end

--[[
	Binds a module's remotes on the server and wires its handlers and pushes. The modules' own
	`bindNet(context?)` calls this; call it once per module instance, at startup.
]]
function Remotes.serve(module: string, instance: any, context: Net.Context?): any
	local serve = SERVERS[module]
	assert(serve, "Remotes.serve: unknown module " .. tostring(module))
	local remotes = Remotes.bind(module, context)
	serve(instance, remotes)
	return remotes
end

return Remotes
