--!strict
--[[
	Fakes for Roblox services, usable under lune and in Studio. Build modules against the
	subset of the real API these implement, and inject them:

		local dss = T.Fakes.DataStoreService.new()
		local data = Data.new({ dataStoreService = dss, players = T.Fakes.Players.new() })
]]

return {
	DataStoreService = require("@self/DataStoreService"),
	MarketplaceService = require("@self/MarketplaceService"),
	Players = require("@self/Players"),
}
