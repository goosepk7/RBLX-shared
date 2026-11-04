--!strict
--[[
	Fake Players service and Player objects.

	  local players = T.Fakes.Players.new()
	  players.PlayerAdded:Connect(onJoin)
	  local p = players:join({ UserId = 101, Name = "builder101" })  -- fires PlayerAdded
	  players:leave(p)                                                -- fires PlayerRemoving
	  expect(p:wasKicked()).toBe(false)

	Fake players support attributes (GetAttribute/SetAttribute/GetAttributeChangedSignal) so
	read-only replicated state can be asserted on, and Kick() records the message.
]]

local Signal = require("../Signal")

export type FakePlayer = {
	UserId: number,
	Name: string,
	DisplayName: string,
	AccountAge: number,
	MembershipType: string,
	Parent: any,
	ClassName: string,
	Kick: (self: FakePlayer, message: string?) -> (),
	wasKicked: (self: FakePlayer) -> boolean,
	kickMessage: (self: FakePlayer) -> string?,
	GetAttribute: (self: FakePlayer, name: string) -> any,
	SetAttribute: (self: FakePlayer, name: string, value: any) -> (),
	GetAttributes: (self: FakePlayer) -> { [string]: any },
	GetAttributeChangedSignal: (self: FakePlayer, name: string) -> Signal.Signal<>,
	IsA: (self: FakePlayer, className: string) -> boolean,
}

export type PlayerSpec = {
	UserId: number?,
	Name: string?,
	DisplayName: string?,
	AccountAge: number?,
	MembershipType: string?,
}

export type FakePlayers = {
	PlayerAdded: Signal.Signal<FakePlayer>,
	PlayerRemoving: Signal.Signal<FakePlayer>,
	LocalPlayer: FakePlayer?,
	MaxPlayers: number,
	GetPlayers: (self: FakePlayers) -> { FakePlayer },
	GetPlayerByUserId: (self: FakePlayers, userId: number) -> FakePlayer?,
	join: (self: FakePlayers, spec: PlayerSpec?) -> FakePlayer,
	leave: (self: FakePlayers, player: FakePlayer) -> (),
	setLocalPlayer: (self: FakePlayers, player: FakePlayer?) -> (),
}

local Players = {}

local nextUserId = 1000

function Players.newPlayer(spec: PlayerSpec?): FakePlayer
	local s: PlayerSpec = spec or {}
	local userId = s.UserId
	if userId == nil then
		nextUserId += 1
		userId = nextUserId
	end
	local name = s.Name or ("Player" .. tostring(userId))
	local attributes: { [string]: any } = {}
	local attributeSignals: { [string]: Signal.Signal<> } = {}
	local kicked = false
	local kickText: string? = nil

	local player = {
		UserId = userId,
		Name = name,
		DisplayName = s.DisplayName or name,
		AccountAge = s.AccountAge or 30,
		MembershipType = s.MembershipType or "None",
		Parent = nil,
		ClassName = "Player",
	} :: FakePlayer

	function player.Kick(_self: FakePlayer, message: string?)
		kicked = true
		kickText = message
	end

	function player.wasKicked(_self: FakePlayer): boolean
		return kicked
	end

	function player.kickMessage(_self: FakePlayer): string?
		return kickText
	end

	function player.GetAttribute(_self: FakePlayer, key: string): any
		return attributes[key]
	end

	function player.SetAttribute(_self: FakePlayer, key: string, value: any)
		local kind = typeof(value)
		assert(
			kind == "nil" or kind == "string" or kind == "number" or kind == "boolean",
			"SetAttribute: unsupported attribute type " .. kind .. " (fake supports nil/string/number/boolean)"
		)
		if attributes[key] == value then
			return
		end
		attributes[key] = value
		local signal = attributeSignals[key]
		if signal then
			signal:Fire()
		end
	end

	function player.GetAttributes(_self: FakePlayer): { [string]: any }
		return table.clone(attributes)
	end

	function player.GetAttributeChangedSignal(_self: FakePlayer, key: string): Signal.Signal<>
		local signal = attributeSignals[key]
		if not signal then
			signal = Signal.new()
			attributeSignals[key] = signal
		end
		return signal :: Signal.Signal<>
	end

	function player.IsA(_self: FakePlayer, className: string): boolean
		return className == "Player" or className == "Instance"
	end

	return player
end

function Players.new(): FakePlayers
	local list: { FakePlayer } = {}
	local service = {
		PlayerAdded = Signal.new(),
		PlayerRemoving = Signal.new(),
		LocalPlayer = nil,
		MaxPlayers = 12,
	} :: FakePlayers

	function service.GetPlayers(_self: FakePlayers): { FakePlayer }
		return table.clone(list)
	end

	function service.GetPlayerByUserId(_self: FakePlayers, userId: number): FakePlayer?
		for _, player in list do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end

	function service.join(self: FakePlayers, spec: PlayerSpec?): FakePlayer
		local player = Players.newPlayer(spec)
		assert(self:GetPlayerByUserId(player.UserId) == nil, "Players:join: UserId already in server")
		player.Parent = self
		table.insert(list, player)
		-- Kicking removes the player from the server like Roblox (PlayerRemoving fires).
		local kick = player.Kick
		function player.Kick(p: FakePlayer, message: string?)
			local inServer = table.find(list, p) ~= nil
			kick(p, message)
			if inServer then
				self:leave(p)
			end
		end
		self.PlayerAdded:Fire(player)
		return player
	end

	function service.leave(self: FakePlayers, player: FakePlayer)
		local index = table.find(list, player)
		assert(index, "Players:leave: player is not in this server")
		self.PlayerRemoving:Fire(player)
		table.remove(list, index)
		player.Parent = nil
	end

	function service.setLocalPlayer(self: FakePlayers, player: FakePlayer?)
		self.LocalPlayer = player
	end

	return service
end

return Players
