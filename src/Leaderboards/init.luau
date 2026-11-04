--!strict
--[[
	Leaderboards: OrderedDataStore boards with batched writes, a cached top 100 refreshed on a
	cadence, rank lookup, and daily or weekly boards (brief §4, §6.8 "Tallest Today", §7.8
	Gauntlet weekly). Server only; reads and writes run in background threads.

	  local boards = Shared.Leaderboards.new({
	  	boards = {
	  		{ id = "wins", mode = "max", value = function(who) return economy:allTime(who, "Wins") end },
	  		{ id = "tallestToday", mode = "max", period = "daily", scale = 10,
	  		  value = function(who) return heightOf(who) end },
	  		{ id = "gap:pier:easy", mode = "min", scale = 1000 },     -- best time in ms
	  	},
	  })
	  boards:start()
	  boards:submit(player, "gap:pier:easy", 12.34)                  -- kept only if better
	  local snapshot = boards:get("wins")                            -- entries, updatedAt
	  local rank = boards:rankOf(player, "wins")                     -- nil past the top 100

	Modes: "max" keeps each player's highest value (descending board), "min" keeps the lowest
	(ascending: best times), "set" always replaces. Values are stored as whole numbers:
	value x scale, rounded. Boards with a `value` function are sampled for every player in the
	server at each write; others take what `submit` sends.

	Budget: writes go out every `writeInterval` (60 s) and when a player leaves, one UpdateAsync
	per changed player per board; each board reads its top `size` once per `refreshInterval`
	(120 s). Names come from UserService in one batch per refresh and are cached.
]]

local Log = require("./Util/Log")
local Remotes = require("./Remotes")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Slots = require("./Util/Slots")

export type Mode = "max" | "min" | "set"
export type Period = "all" | "daily" | "weekly"

export type BoardDef = {
	id: string,
	mode: Mode?,
	period: Period?,
	-- Stored value = round(value x scale). Default 1.
	scale: number?,
	-- Reads the player's current value at each write (lifetime Wins, height).
	value: ((who: any) -> number?)?,
	-- Entries cached and shown. Default 100 (the most one GetSortedAsync page returns).
	size: number?,
	nameKey: string?,
	icon: string?,
	-- How clients show values: "grouped" (1,234), "compact" (1.2K) or "time" (seconds).
	format: string?,
}

export type Entry = {
	rank: number,
	userId: number,
	name: string,
	displayName: string,
	-- In the board's units (stored value / scale).
	value: number,
}

export type Snapshot = {
	id: string,
	entries: { Entry },
	-- os.time() of the read; 0 before the first one.
	updatedAt: number,
	-- os.time() the period ends, for daily and weekly boards.
	endsAt: number?,
}

export type Options = {
	boards: { BoardDef },
	-- OrderedDataStore name prefix. Default "LB_".
	prefix: string?,
	refreshInterval: number?,
	writeInterval: number?,
	-- Dependencies.
	dataStoreService: any?,
	userService: any?,
	players: any?,
	task: any?,
	now: (() -> number)?,
}

export type Leaderboards = {
	-- (boardId, snapshot) after each refresh.
	Updated: Signal.Signal<string, Snapshot>,

	-- Starts the refresh and write loops and flushes players as they leave. Returns at once.
	start: (self: Leaderboards) -> (),
	board: (self: Leaderboards, id: string) -> BoardDef?,
	boards: (self: Leaderboards) -> { BoardDef },
	-- Queues a value; kept only if better than what is queued (per mode).
	submit: (self: Leaderboards, who: any, boardId: string, value: number) -> (),
	get: (self: Leaderboards, boardId: string) -> Snapshot,
	rankOf: (self: Leaderboards, who: any, boardId: string) -> number?,
	-- The player's best known value on a board (what they submitted, or read once on join).
	valueOf: (self: Leaderboards, who: any, boardId: string) -> number?,
	-- Store name and key for a board right now (for tests and the Admin panel).
	storeName: (self: Leaderboards, boardId: string, time: number?) -> string,
	periodEndsAt: (self: Leaderboards, boardId: string, time: number?) -> number?,
	-- Each yields.
	flushAsync: (self: Leaderboards, who: any?) -> (),
	refreshAsync: (self: Leaderboards, boardId: string?) -> (),
	loadPlayerAsync: (self: Leaderboards, player: any) -> (),
	-- Admin: removes a player from a board (cheaters).
	removeAsync: (self: Leaderboards, boardId: string, userId: number) -> (boolean, string?),

	-- Server: binds this module's remotes (Remotes.leaderboards) and wires the handlers. Once, at startup.
	bindNet: (self: Leaderboards, context: any?) -> any,
}

local DAY = 86400
local WEEK = 7 * DAY
-- The Unix epoch was a Thursday; shifting by 3 days starts weeks on Monday 00:00 UTC.
local WEEK_OFFSET = 3 * DAY
local MAX_STORED = 2 ^ 53

local Leaderboards = {}

-- Whether `candidate` beats `current` on a board of this mode (pure).
function Leaderboards.better(mode: Mode | string, candidate: number, current: number?): boolean
	if current == nil then
		return true
	end
	if mode == "max" then
		return candidate > current
	elseif mode == "min" then
		return candidate < current
	end
	return candidate ~= current
end

-- The period index and its end for a board period (pure).
function Leaderboards.period(period: Period, time: number): (number?, number?)
	if period == "daily" then
		local index = math.floor(time / DAY)
		return index, (index + 1) * DAY
	elseif period == "weekly" then
		local index = math.floor((time + WEEK_OFFSET) / WEEK)
		return index, (index + 1) * WEEK - WEEK_OFFSET
	end
	return nil, nil
end

function Leaderboards.encode(def: BoardDef, value: number): number
	local stored = math.floor(value * (def.scale or 1) + 0.5)
	return math.clamp(stored, -MAX_STORED, MAX_STORED)
end

function Leaderboards.decode(def: BoardDef, stored: number): number
	return stored / (def.scale or 1)
end

function Leaderboards.new(options: Options): Leaderboards
	local prefix = options.prefix or "LB_"
	local refreshInterval = options.refreshInterval or 120
	local writeInterval = options.writeInterval or 60
	local now: () -> number = options.now or os.time

	local defs: { [string]: BoardDef } = {}
	local defList: { BoardDef } = {}
	for _, def in options.boards do
		assert(
			type(def.id) == "string" and string.match(def.id, "^[%w_:%.%-]+$"),
			"Leaderboards.new: board id must be letters, digits or _ : . -"
		)
		assert(defs[def.id] == nil, "Leaderboards.new: duplicate board " .. def.id)
		assert(
			def.mode == nil or def.mode == "max" or def.mode == "min" or def.mode == "set",
			"Leaderboards.new: " .. def.id .. ".mode must be max, min or set"
		)
		assert(
			def.period == nil or def.period == "all" or def.period == "daily" or def.period == "weekly",
			"Leaderboards.new: " .. def.id .. ".period must be all, daily or weekly"
		)
		assert(
			def.scale == nil or (def.scale > 0 and def.scale < math.huge),
			"Leaderboards.new: " .. def.id .. ".scale must be positive"
		)
		local size = def.size or 100
		assert(size >= 1 and size <= 100, "Leaderboards.new: " .. def.id .. ".size must be 1-100")
		defs[def.id] = def
		table.insert(defList, def)
	end

	local snapshots: { [string]: Snapshot } = {}
	-- boardId -> userId -> stored value waiting to be written.
	local pending: { [string]: { [number]: number } } = {}
	-- boardId -> userId -> best stored value known for the player in the current period.
	local known: { [string]: { [number]: { period: number?, value: number } } } = {}
	local names: { [number]: { name: string, displayName: string } } = {}
	local playerById: { [number]: any } = {}

	local boards = { Updated = Signal.new() } :: Leaderboards

	local function taskLib(): any
		return options.task or Roblox.task()
	end

	local function dss(): any
		return options.dataStoreService or Roblox.service("DataStoreService")
	end

	local function players(): any
		return options.players or Roblox.service("Players")
	end

	local function modeOf(def: BoardDef): Mode
		return (def.mode or "max") :: Mode
	end

	local function periodIndex(def: BoardDef, time: number?): number?
		local index = Leaderboards.period(def.period or "all", time or now())
		return index
	end

	local function storeNameOf(def: BoardDef, time: number?): string
		local index = periodIndex(def, time)
		if index == nil then
			return prefix .. def.id
		end
		local tag = if def.period == "daily" then "_D" else "_W"
		return prefix .. def.id .. tag .. tostring(index)
	end

	local function ordered(def: BoardDef): any
		return dss():GetOrderedDataStore(storeNameOf(def))
	end

	local function remember(def: BoardDef, userId: number, stored: number)
		local byUser = known[def.id]
		if byUser == nil then
			byUser = {}
			known[def.id] = byUser
		end
		local map = byUser :: { [number]: { period: number?, value: number } }
		local period = periodIndex(def)
		local current = map[userId]
		if current == nil or current.period ~= period or Leaderboards.better(modeOf(def), stored, current.value) then
			map[userId] = { period = period, value = stored }
		end
	end

	local function queue(def: BoardDef, userId: number, stored: number)
		local byUser = pending[def.id]
		if byUser == nil then
			byUser = {}
			pending[def.id] = byUser
		end
		local map = byUser :: { [number]: number }
		local mode = modeOf(def)
		local known_ = known[def.id] and (known[def.id] :: any)[userId]
		local period = periodIndex(def)
		local knownValue = if known_ and known_.period == period then known_.value else nil
		if mode ~= "set" and knownValue ~= nil and not Leaderboards.better(mode, stored, knownValue) then
			return
		end
		if mode == "set" and knownValue == stored and map[userId] == nil then
			return
		end
		if mode == "set" or Leaderboards.better(mode, stored, map[userId]) then
			map[userId] = stored
		end
	end

	local function sample(who: any)
		local userId = Slots.userIdOf(who)
		if userId == nil then
			return
		end
		for _, def in defList do
			local read = def.value
			if read then
				local value = read(who)
				if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
					queue(def, userId, Leaderboards.encode(def, value))
				end
			end
		end
	end

	local function resolveNames(ids: { number })
		local missing: { number } = {}
		for _, id in ids do
			if names[id] == nil then
				local player = playerById[id]
				if player then
					names[id] = { name = player.Name, displayName = player.DisplayName or player.Name }
				else
					table.insert(missing, id)
				end
			end
		end
		if #missing == 0 then
			return
		end
		local service = options.userService
		if service == nil and Roblox.isRoblox() then
			service = Roblox.service("UserService")
		end
		if service then
			local ok, infos = pcall(function()
				return service:GetUserInfosByUserIdsAsync(missing)
			end)
			if ok and type(infos) == "table" then
				for _, info in infos do
					names[info.Id] = { name = info.Username, displayName = info.DisplayName or info.Username }
				end
			elseif not ok then
				Log.warn("Leaderboards", "name lookup failed: " .. tostring(infos))
			end
		end
	end

	function boards.board(_self: Leaderboards, id: string): BoardDef?
		return defs[id]
	end

	function boards.boards(_self: Leaderboards): { BoardDef }
		return table.clone(defList)
	end

	function boards.storeName(_self: Leaderboards, boardId: string, time: number?): string
		local def = defs[boardId]
		assert(def, "Leaderboards: unknown board " .. boardId)
		return storeNameOf(def, time)
	end

	function boards.periodEndsAt(_self: Leaderboards, boardId: string, time: number?): number?
		local def = defs[boardId]
		assert(def, "Leaderboards: unknown board " .. boardId)
		local _, endsAt = Leaderboards.period(def.period or "all", time or now())
		return endsAt
	end

	function boards.submit(_self: Leaderboards, who: any, boardId: string, value: number)
		local def = defs[boardId]
		local userId = Slots.userIdOf(who)
		if def == nil then
			Log.warn("Leaderboards", "submit to unknown board " .. tostring(boardId))
			return
		end
		if userId == nil or type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return
		end
		queue(def, userId, Leaderboards.encode(def, value))
	end

	function boards.get(_self: Leaderboards, boardId: string): Snapshot
		local def = defs[boardId]
		assert(def, "Leaderboards: unknown board " .. boardId)
		local snapshot = snapshots[boardId]
		local _, endsAt = Leaderboards.period(def.period or "all", now())
		if snapshot == nil or (def.period ~= nil and def.period ~= "all" and snapshot.endsAt ~= endsAt) then
			return { id = boardId, entries = {}, updatedAt = 0, endsAt = endsAt }
		end
		return snapshot
	end

	function boards.rankOf(self: Leaderboards, who: any, boardId: string): number?
		local userId = Slots.userIdOf(who)
		for _, entry in self:get(boardId).entries do
			if entry.userId == userId then
				return entry.rank
			end
		end
		return nil
	end

	function boards.valueOf(_self: Leaderboards, who: any, boardId: string): number?
		local def = defs[boardId]
		local userId = Slots.userIdOf(who)
		if def == nil or userId == nil then
			return nil
		end
		local queued = pending[boardId] and (pending[boardId] :: any)[userId]
		local entry = known[boardId] and (known[boardId] :: any)[userId]
		local best: number? = nil
		if entry and entry.period == periodIndex(def) then
			best = entry.value
		end
		if queued and (best == nil or modeOf(def) == "set" or Leaderboards.better(modeOf(def), queued, best)) then
			best = queued
		end
		return if best then Leaderboards.decode(def, best) else nil
	end

	local function writeOne(def: BoardDef, userId: number, stored: number): boolean
		local mode = modeOf(def)
		local ok, err = pcall(function()
			ordered(def):UpdateAsync(tostring(userId), function(current: number?): number?
				if mode == "set" or Leaderboards.better(mode, stored, current) then
					return stored
				end
				return nil
			end)
		end)
		if not ok then
			Log.warn("Leaderboards", string.format("write %s for %d failed: %s", def.id, userId, tostring(err)))
			return false
		end
		remember(def, userId, stored)
		return true
	end

	function boards.flushAsync(_self: Leaderboards, who: any?)
		local only = if who ~= nil then Slots.userIdOf(who) else nil
		if who ~= nil then
			sample(who)
		else
			for _, player in players():GetPlayers() do
				sample(player)
			end
		end
		for _, def in defList do
			local byUser = pending[def.id]
			if byUser then
				for userId, stored in table.clone(byUser) do
					if only == nil or only == userId then
						byUser[userId] = nil
						if not writeOne(def, userId, stored) then
							-- Keep it for the next flush unless something better arrived meanwhile.
							if byUser[userId] == nil then
								byUser[userId] = stored
							end
						end
					end
				end
			end
		end
	end

	function boards.refreshAsync(_self: Leaderboards, boardId: string?)
		for _, def in defList do
			if boardId == nil or def.id == boardId then
				local ok, page = pcall(function()
					local pages = ordered(def):GetSortedAsync(modeOf(def) == "min", def.size or 100)
					return pages:GetCurrentPage()
				end)
				if ok and type(page) == "table" then
					local ids: { number } = {}
					local rows: { { userId: number, value: number } } = {}
					for _, item in page do
						local id = tonumber(item.key)
						if id then
							table.insert(ids, id)
							table.insert(rows, { userId = id, value = item.value })
						end
					end
					resolveNames(ids)
					local entries: { Entry } = {}
					for index, row in rows do
						local info = names[row.userId]
						local fallback = "#" .. tostring(row.userId)
						table.insert(entries, {
							rank = index,
							userId = row.userId,
							name = if info then info.name else fallback,
							displayName = if info then info.displayName else fallback,
							value = Leaderboards.decode(def, row.value),
						})
						remember(def, row.userId, row.value)
					end
					local _, endsAt = Leaderboards.period(def.period or "all", now())
					local snapshot: Snapshot = { id = def.id, entries = entries, updatedAt = now(), endsAt = endsAt }
					snapshots[def.id] = snapshot
					boards.Updated:Fire(def.id, snapshot)
				elseif not ok then
					Log.warn("Leaderboards", "refresh " .. def.id .. " failed: " .. tostring(page))
				end
			end
		end
	end

	function boards.loadPlayerAsync(_self: Leaderboards, player: any)
		local userId = player.UserId
		playerById[userId] = player
		names[userId] = { name = player.Name, displayName = player.DisplayName or player.Name }
		for _, def in defList do
			local ok, value = pcall(function()
				return ordered(def):GetAsync(tostring(userId))
			end)
			if ok and type(value) == "number" then
				remember(def, userId, value)
			elseif not ok then
				Log.warn("Leaderboards", "reading " .. def.id .. " for " .. userId .. " failed: " .. tostring(value))
			end
		end
	end

	function boards.removeAsync(_self: Leaderboards, boardId: string, userId: number): (boolean, string?)
		local def = defs[boardId]
		if def == nil then
			return false, "unknown board"
		end
		local ok, err = pcall(function()
			ordered(def):RemoveAsync(tostring(userId))
		end)
		if not ok then
			return false, tostring(err)
		end
		if pending[boardId] then
			(pending[boardId] :: any)[userId] = nil
		end
		if known[boardId] then
			(known[boardId] :: any)[userId] = nil
		end
		local snapshot = snapshots[boardId]
		if snapshot then
			local kept: { Entry } = {}
			for _, entry in snapshot.entries do
				if entry.userId ~= userId then
					local copy = table.clone(entry)
					copy.rank = #kept + 1
					table.insert(kept, copy)
				end
			end
			snapshot.entries = kept
		end
		return true, nil
	end

	function boards.start(self: Leaderboards)
		local t = taskLib()
		local service = players()
		service.PlayerAdded:Connect(function(player: any)
			t.spawn(function()
				self:loadPlayerAsync(player)
			end)
		end)
		service.PlayerRemoving:Connect(function(player: any)
			t.spawn(function()
				self:flushAsync(player)
				playerById[player.UserId] = nil
			end)
		end)
		for _, player in service:GetPlayers() do
			t.spawn(function()
				self:loadPlayerAsync(player)
			end)
		end
		t.spawn(function()
			self:refreshAsync()
			while true do
				t.wait(refreshInterval)
				self:refreshAsync()
			end
		end)
		t.spawn(function()
			while true do
				t.wait(writeInterval)
				self:flushAsync()
			end
		end)
	end

	function boards.bindNet(self: Leaderboards, context: any?): any
		return Remotes.serve("Leaderboards", self, context)
	end
	return boards
end

return Leaderboards
