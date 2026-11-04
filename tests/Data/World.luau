--!strict
--[[
	Test world for Data specs: one virtual clock, one shared DataStore fake and one
	MessagingService fake, and any number of simulated servers ("A", "B", ...) on top of them.

	  local world = World.new()
	  local a, b = world:server("A"), world:server("B")
	  local profile = a.store:loadAsync(a:join(1))
	  world.clock:advance(60)            -- every server's timers run on the shared clock
	  expect(world:stored(1).data.coins).toBe(0)
]]

local ClockModule = require("@shared/Test/Clock")
local Data = require("@shared/Data")
local DataStoreFake = require("@shared/Test/Fakes/DataStoreService")
local Deep = require("@shared/Util/Deep")
local MarketplaceFake = require("@shared/Test/Fakes/MarketplaceService")
local PlayersFake = require("@shared/Test/Fakes/Players")
local T = require("@shared/Test")

export type Messaging = {
	published: number,
	failPublish: boolean,
	SubscribeAsync: (self: Messaging, topic: string, callback: (any) -> ()) -> { Disconnect: () -> () },
	PublishAsync: (self: Messaging, topic: string, data: any) -> (),
}

export type Server = {
	name: string,
	sessionId: string,
	store: Data.Store<any>,
	players: PlayersFake.FakePlayers,
	-- Callbacks the store handed to bindToClose; call closers[1]() to shut the server down.
	closers: { () -> () },
	-- A player joins this server (fires PlayerAdded). Typed `any` so it passes as a Player.
	join: (self: Server, userId: number) -> any,
	leave: (self: Server, player: any) -> (),
	counters: (self: Server) -> Data.StoreDiagnostics,
}

export type World = {
	clock: ClockModule.Clock,
	dss: DataStoreFake.FakeDataStoreService,
	messaging: Messaging,
	mps: MarketplaceFake.FakeMarketplaceService,
	server: (self: World, name: string, overrides: { [string]: any }?) -> Server,
	-- The stored document for a user, or nil.
	stored: (self: World, userId: number) -> any,
	seed: (self: World, userId: number, value: any) -> (),
	version: (self: World, userId: number) -> string?,
	-- A session lock as server `name` would write it, with a heartbeat `age` seconds old.
	lock: (self: World, name: string, age: number?) -> any,
}

local World = {}

World.STORE = "Profiles"

World.TEMPLATE = table.freeze({
	coins = 0,
	inventory = {},
	settings = { music = true },
})

-- Minimal MessagingService: delivers synchronously to every subscriber of a topic.
local function fakeMessaging(): Messaging
	local subscribers: { [string]: { (any) -> () } } = {}
	local service = { published = 0, failPublish = false } :: Messaging
	function service.SubscribeAsync(_self: Messaging, topic: string, callback: (any) -> ())
		local list = subscribers[topic] or {}
		subscribers[topic] = list
		table.insert(list, callback)
		return {
			Disconnect = function()
				local index = table.find(list, callback)
				if index then
					table.remove(list, index)
				end
			end,
		}
	end
	function service.PublishAsync(self: Messaging, topic: string, data: any)
		if self.failPublish then
			error("MessagingService unavailable")
		end
		self.published += 1
		local list: { (any) -> () } = subscribers[topic] or {}
		for _, callback in table.clone(list) do
			callback({ Data = Deep.copy(data), Sent = 0 })
		end
	end
	return service
end

local function keyOf(userId: number): string
	return "Player_" .. tostring(userId)
end

function World.new(): World
	local clock = ClockModule.new()
	local dss = T.Fakes.DataStoreService.new()
	dss:setNow(function()
		return clock:now() * 1000
	end)
	local world = {
		clock = clock,
		dss = dss,
		messaging = fakeMessaging(),
		mps = T.Fakes.MarketplaceService.new(),
	} :: World

	function world.server(self: World, name: string, overrides: { [string]: any }?): Server
		local players = T.Fakes.Players.new()
		local closers: { () -> () } = {}
		local sessionId = "session-" .. name
		local options: any = {
			name = World.STORE,
			template = Deep.copy(World.TEMPLATE),
			dataStoreService = self.dss,
			messagingService = self.messaging,
			players = players,
			task = self.clock.task,
			now = function()
				return self.clock:now()
			end,
			clock = function()
				return self.clock:clock()
			end,
			sessionId = sessionId,
			jobId = "job-" .. name,
			placeId = 1,
			decisions = self.mps.Decision,
			bindToClose = function(callback: () -> ())
				table.insert(closers, callback)
			end,
		}
		local extra: { [string]: any } = overrides or {}
		for key, value in extra do
			options[key] = value
		end
		local server = {
			name = name,
			sessionId = sessionId,
			store = Data.Store.new(options),
			players = players,
			closers = closers,
		} :: Server
		function server.join(_self: Server, userId: number): any
			return players:join({ UserId = userId, Name = "player" .. tostring(userId) })
		end
		function server.leave(_self: Server, player: any)
			players:leave(player)
		end
		function server.counters(s: Server): Data.StoreDiagnostics
			return s.store:getDiagnostics()
		end
		return server
	end

	function world.stored(self: World, userId: number): any
		return self.dss:inspect(World.STORE, keyOf(userId))
	end

	function world.seed(self: World, userId: number, value: any)
		self.dss:seed(World.STORE, keyOf(userId), value)
	end

	function world.version(self: World, userId: number): string?
		return self.dss:versionOf(World.STORE, keyOf(userId))
	end

	function world.lock(self: World, name: string, age: number?): any
		local at = self.clock:now() - (age or 0)
		return { sessionId = "session-" .. name, jobId = "job-" .. name, placeId = 1, lockedAt = at, heartbeatAt = at }
	end

	return world
end

-- A stored profile document as an older or other server would have written it.
function World.document(data: any, meta: { [string]: any }?): any
	local base: any = {
		schemaVersion = 1,
		createdAt = 1_699_000_000,
		updatedAt = 1_699_000_000,
		loadCount = 1,
		receipts = {},
	}
	local extra: { [string]: any } = meta or {}
	for key, value in extra do
		base[key] = value
	end
	return { data = data, meta = base }
end

-- A saved player with some progress, at schema version 1.
function World.progress(coins: number): any
	return { coins = coins, inventory = { "sword" }, settings = { music = false } }
end

return World
