--!strict
--[[
	Slots: one module's state inside each player's profile data (profile.data[field]).

	Progression, Rebirth, Shop, Codes, Daily, Badges and Events each keep their per-player state
	in a field of the game's profile data, so it saves and session-locks with the profile. This
	helper does the bookkeeping they share with Economy's wallet:

	  local slots = Slots.new("progression", Progression.newState, Progression.repair)
	  slots:bindStore(Profiles)          -- attach on Loaded, detach on Released
	  slots:attach(player, data)         -- or by hand (sims, tests): data or () -> data
	  local state = slots:get(player)    -- nil until attached

	`who` is a Player or a UserId everywhere. A release only detaches the profile it attached, so
	a newer profile for the same player stays attached (same rule as Economy.bindStore).
]]

local Signal = require("../Signal")

export type Slots<S> = {
	field: string,
	-- (player or nil, userId, state) after a state is attached (and created or repaired).
	Attached: Signal.Signal<any, number, S>,
	-- (player or nil, userId) after a state is detached.
	Detached: Signal.Signal<any, number>,

	attach: (self: Slots<S>, who: any, data: any) -> S,
	detach: (self: Slots<S>, who: any) -> (),
	bindStore: (self: Slots<S>, store: any) -> (),
	get: (self: Slots<S>, who: any) -> S?,
	-- The whole profile data table the state lives in (for modules that touch other fields).
	data: (self: Slots<S>, who: any) -> any,
	player: (self: Slots<S>, who: any) -> any,
	isAttached: (self: Slots<S>, who: any) -> boolean,
	-- Every attached user id.
	userIds: (self: Slots<S>) -> { number },
}

type Record = { userId: number, player: any?, getData: () -> any }

local Slots = {}

function Slots.userIdOf(who: any): number?
	if type(who) == "number" then
		return who
	end
	if type(who) == "table" or typeof(who) == "Instance" then
		local id = (who :: any).UserId
		if type(id) == "number" then
			return id
		end
	end
	return nil
end

-- Sets a player attribute when `player` is a Player (or a fake with SetAttribute); a UserId or
-- nil is ignored.
function Slots.setAttribute(player: any, name: string, value: any)
	if player == nil or type(player) == "number" then
		return
	end
	if typeof(player) == "Instance" or type((player :: any).SetAttribute) == "function" then
		player:SetAttribute(name, value)
	end
end

--[[
	`create()` returns a fresh state; `repair(state)` brings a loaded state up to date (adds
	missing fields, drops values of the wrong type) and returns it, or a replacement.
]]
function Slots.new<S>(field: string, create: () -> S, repair: ((any) -> S)?): Slots<S>
	assert(type(field) == "string" and #field > 0, "Slots.new: field must be a non-empty string")
	local records: { [number]: Record } = {}

	local slots = {
		field = field,
		Attached = Signal.new(),
		Detached = Signal.new(),
	} :: Slots<S>

	local function recordFor(who: any): Record?
		local id = Slots.userIdOf(who)
		return if id then records[id] else nil
	end

	local function stateOf(record: Record): S?
		local data = record.getData()
		if type(data) ~= "table" then
			return nil
		end
		local state = data[field]
		if type(state) ~= "table" then
			state = create()
			data[field] = state
		end
		return state
	end

	function slots.attach(self: Slots<S>, who: any, data: any): S
		local userId = Slots.userIdOf(who)
		assert(userId, "Slots.attach: expected a Player or a UserId")
		local getData: () -> any
		if type(data) == "function" then
			getData = data
		else
			assert(type(data) == "table", "Slots.attach: expected the profile data table or a function returning it")
			getData = function()
				return data
			end
		end
		local current = getData()
		assert(type(current) == "table", "Slots.attach: profile data must be a table")
		local state = current[field]
		if type(state) ~= "table" then
			state = create()
		elseif repair then
			state = repair(state)
		end
		current[field] = state
		local player = if type(who) == "number" then nil else who
		records[userId] = { userId = userId, player = player, getData = getData }
		self.Attached:Fire(player, userId, state)
		return state
	end

	function slots.detach(self: Slots<S>, who: any)
		local record = recordFor(who)
		if record then
			records[record.userId] = nil
			self.Detached:Fire(record.player, record.userId)
		end
	end

	function slots.bindStore(self: Slots<S>, store: any)
		store.Loaded:Connect(function(player: any, profile: any)
			self:attach(player, function()
				return profile.data
			end)
		end)
		store.Released:Connect(function(_player: any, profile: any)
			local record = records[profile.userId]
			if record and record.getData() == profile.data then
				self:detach(profile.userId)
			end
		end)
	end

	function slots.get(_self: Slots<S>, who: any): S?
		local record = recordFor(who)
		return if record then stateOf(record) else nil
	end

	function slots.data(_self: Slots<S>, who: any): any
		local record = recordFor(who)
		return if record then record.getData() else nil
	end

	function slots.player(_self: Slots<S>, who: any): any
		local record = recordFor(who)
		if record then
			return record.player
		end
		return if type(who) == "number" then nil else who
	end

	function slots.isAttached(_self: Slots<S>, who: any): boolean
		return recordFor(who) ~= nil
	end

	function slots.userIds(_self: Slots<S>): { number }
		local ids: { number } = {}
		for id in records do
			table.insert(ids, id)
		end
		table.sort(ids)
		return ids
	end

	return slots
end

return Slots
