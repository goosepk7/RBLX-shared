--!strict
--[[
	Badges: a badge registry with award-once semantics and a hook for the server banner (brief
	§4, §5.5 "Badge/Milestone toast"). Server only.

	  local badges = Shared.Badges.new({
	  	badges = {
	  		{ key = "FirstWin", id = 0, nameKey = "badge.FirstWin.name", icon = "icon_wins" },
	  		{ key = "Rebirth1", id = 0, nameKey = "badge.Rebirth1.name", icon = "icon_rebirth", announce = true },
	  	},
	  })
	  badges:bindStore(Profiles)
	  badges.Earned:Connect(function(player, userId, def) ... toast, and a banner if def.announce ... end)
	  badges:award(player, "FirstWin")                 -- true the first time only

	"Earned" is ours and is saved in the profile; the Roblox badge is delivered from it. A badge
	whose id is still 0 (not created in the dashboard yet) is earned now and delivered on the
	player's next join once the owner pastes the id, so nobody misses a badge they earned
	before launch. Delivery retries three times, then again on the next join.
]]

local Log = require("./Util/Log")
local Remotes = require("./Remotes")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Slots = require("./Util/Slots")

export type BadgeDef = {
	key: string,
	-- Roblox badge id; 0 = not created yet (earned, delivered later).
	id: number,
	nameKey: string?,
	descriptionKey: string?,
	icon: string?,
	-- Ask the game to announce it server-wide (the Earned listener decides how).
	announce: boolean?,
}

export type Options = {
	badges: { BadgeDef },
	field: string?,
	retries: number?,
	retryDelay: number?,
	badgeService: any?,
	players: any?,
	task: any?,
	now: (() -> number)?,
}

export type State = {
	-- Key -> os.time() earned.
	earned: { [string]: number },
	-- Key -> os.time() the Roblox badge was confirmed.
	awarded: { [string]: number },
}

export type Badges = {
	-- (player?, userId, def) once, when a badge is first earned.
	Earned: Signal.Signal<any, number, BadgeDef>,
	-- (player?, userId, def) when the Roblox badge is confirmed.
	Delivered: Signal.Signal<any, number, BadgeDef>,

	bindStore: (self: Badges, store: any) -> (),
	attach: (self: Badges, who: any, data: any) -> (),
	detach: (self: Badges, who: any) -> (),
	isAttached: (self: Badges, who: any) -> boolean,
	badge: (self: Badges, key: string) -> BadgeDef?,
	badges: (self: Badges) -> { BadgeDef },
	has: (self: Badges, who: any, key: string) -> boolean,
	-- True when the badge is newly earned. Delivery to Roblox runs in the background.
	award: (self: Badges, who: any, key: string) -> boolean,
	-- Delivers every earned badge Roblox doesn't have yet (yields).
	deliverAsync: (self: Badges, player: any) -> (),

	-- Server: binds this module's remotes (Remotes.badges) and wires the handlers. Once, at startup.
	bindNet: (self: Badges, context: any?) -> any,
}

local Badges = {}

function Badges.newState(): State
	return { earned = {}, awarded = {} }
end

function Badges.repair(state: any): State
	local out = Badges.newState()
	if type(state) ~= "table" then
		return out
	end
	for _, field in { "earned", "awarded" } do
		local map = state[field]
		if type(map) == "table" then
			for key, at in map do
				if type(key) == "string" and type(at) == "number" and at == at then
					(out :: any)[field][key] = at
				end
			end
		end
	end
	return out
end

function Badges.new(options: Options): Badges
	local now: () -> number = options.now or os.time
	local retries = options.retries or 3
	local retryDelay = options.retryDelay or 2
	local byKey: { [string]: BadgeDef } = {}
	local list: { BadgeDef } = {}
	for _, def in options.badges do
		assert(type(def.key) == "string" and #def.key > 0, "Badges.new: key must be a non-empty string")
		assert(byKey[def.key] == nil, "Badges.new: duplicate badge " .. def.key)
		assert(
			type(def.id) == "number" and def.id >= 0,
			"Badges.new: " .. def.key .. ".id must be a number (0 = not created)"
		)
		byKey[def.key] = def
		table.insert(list, def)
	end
	local slots = Slots.new(options.field or "badges", Badges.newState, Badges.repair)
	local delivering: { [number]: boolean } = {}
	local rerun: { [number]: boolean } = {}

	local badges = { Earned = Signal.new(), Delivered = Signal.new() } :: Badges

	local function taskLib(): any
		return options.task or Roblox.task()
	end

	local function service(): any
		return options.badgeService or Roblox.service("BadgeService")
	end

	local function deliverOne(player: any, def: BadgeDef): boolean
		local userId = player.UserId
		for attempt = 1, retries do
			local ok, result = pcall(function()
				return service():AwardBadge(userId, def.id)
			end)
			if ok and result == true then
				return true
			end
			-- False can mean "already owned"; ask before trying again.
			local checked, owns = pcall(function()
				return service():UserHasBadgeAsync(userId, def.id)
			end)
			if checked and owns == true then
				return true
			end
			Log.warn(
				"Badges",
				string.format("award %s to %d failed (try %d): %s", def.key, userId, attempt, tostring(result))
			)
			if attempt < retries then
				taskLib().wait(retryDelay * attempt)
			end
		end
		return false
	end

	function badges.deliverAsync(self: Badges, player: any)
		local userId = player.UserId
		if delivering[userId] then
			-- A delivery is running; it picks this one up before it ends.
			rerun[userId] = true
			return
		end
		delivering[userId] = true
		local tried: { [string]: boolean } = {}
		repeat
			rerun[userId] = nil
			local state = slots:get(player)
			if state then
				for _, def in list do
					if def.id > 0 and not tried[def.key] and state.earned[def.key] and not state.awarded[def.key] then
						tried[def.key] = true
						if deliverOne(player, def) then
							local current = slots:get(player)
							if current then
								current.awarded[def.key] = now()
							end
							self.Delivered:Fire(player, userId, def)
						end
					end
				end
			end
		until not rerun[userId]
		delivering[userId] = nil
	end

	slots.Attached:Connect(function(player: any, _userId: number, _state: State)
		if player ~= nil then
			taskLib().spawn(function()
				badges:deliverAsync(player)
			end)
		end
	end)

	function badges.bindStore(self: Badges, store: any)
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

	function badges.attach(_self: Badges, who: any, data: any)
		slots:attach(who, data)
	end

	function badges.detach(_self: Badges, who: any)
		slots:detach(who)
	end

	function badges.isAttached(_self: Badges, who: any): boolean
		return slots:isAttached(who)
	end

	function badges.badge(_self: Badges, key: string): BadgeDef?
		return byKey[key]
	end

	function badges.badges(_self: Badges): { BadgeDef }
		return table.clone(list)
	end

	function badges.has(_self: Badges, who: any, key: string): boolean
		local state = slots:get(who)
		return state ~= nil and state.earned[key] ~= nil
	end

	function badges.award(self: Badges, who: any, key: string): boolean
		local def = byKey[key]
		if def == nil then
			Log.warn("Badges", "award of unknown badge " .. tostring(key))
			return false
		end
		local state = slots:get(who)
		if state == nil or state.earned[key] then
			return false
		end
		state.earned[key] = now()
		local player = slots:player(who)
		self.Earned:Fire(player, Slots.userIdOf(who) :: number, def)
		if player ~= nil and def.id > 0 then
			taskLib().spawn(function()
				self:deliverAsync(player)
			end)
		end
		return true
	end

	function badges.bindNet(self: Badges, context: any?): any
		return Remotes.serve("Badges", self, context)
	end
	return badges
end

return Badges
