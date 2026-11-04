--!strict
--[[
	Test rig for the v0.2 progression and monetization modules: one virtual clock, an Economy
	with Wins and Gems, and modules attached to plain profile tables (no Data store), so specs
	exercise the logic directly. Specs that need receipts use tests/Data/World.
]]

local Economy = require("@shared/Economy")
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")
local Types = require("@shared/Types")

export type Rig = {
	clock: any,
	now: () -> number,
	economy: Economy.Economy,
	players: any,
	logs: { Log.Entry },
	restore: () -> (),
	-- A player with fresh profile data, attached to the economy and to every `modules` entry.
	join: (self: Rig, userId: number, modules: { any }?) -> (any, any),
}

local Rig = {}

Rig.CURRENCIES = {
	{ id = "Wins", displayName = "Wins" },
	{ id = "Gems", displayName = "Gems", max = 1000 },
} :: { Types.Currency }

Rig.REASONS = {
	stage = "earn",
	challenge = "earn",
	event = "earn",
	daily = "earn",
	shop = "spend",
	rebirthReward = "grant",
	badge = "grant",
}

function Rig.new(): Rig
	local clock = T.Clock.new({ start = 1_700_000_000 })
	local logs, restore = Log.capture()
	local players = T.Fakes.Players.new()
	local now = function()
		return clock:now()
	end
	local economy = Economy.new({
		currencies = Rig.CURRENCIES,
		reasons = Rig.REASONS,
		task = clock.task,
		now = now,
		clock = function()
			return clock:clock()
		end,
		players = players,
	})
	local rig = {
		clock = clock,
		now = now,
		economy = economy,
		players = players,
		logs = logs,
		restore = restore,
	} :: Rig
	function rig.join(self: Rig, userId: number, modules: { any }?): (any, any)
		local player = self.players:join({ UserId = userId, Name = "player" .. userId })
		local data = { wallet = Economy.newWallet() }
		self.economy:attach(player, data)
		local list: { any } = modules or {}
		for _, module in list do
			module:attach(player, data)
		end
		return player, data
	end
	return rig
end

return Rig
