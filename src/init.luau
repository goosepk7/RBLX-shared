--!strict
--[[
	RBLXShared: the framework consumed by +1 Stilts and Evolve a Car.

	Usage (Wally package or git submodule, same path either way):
		local Shared = require(ReplicatedStorage.Packages.RBLXShared)
		local Assets = Shared.Assets

	Every module listed here must be safe to require on server, client, and under lune:
	no service access or side effects at require time. See docs/CONTRIBUTING.md.
]]

local RBLXShared = {
	VERSION = "0.1.0",

	Admin = require("@self/Admin"),
	Analytics = require("@self/Analytics"),
	AntiExploit = require("@self/AntiExploit"),
	Assets = require("@self/Assets"),
	Audio = require("@self/Audio"),
	Badges = require("@self/Badges"),
	Codes = require("@self/Codes"),
	Daily = require("@self/Daily"),
	Data = require("@self/Data"),
	Economy = require("@self/Economy"),
	Events = require("@self/Events"),
	Leaderboards = require("@self/Leaderboards"),
	Loc = require("@self/Loc"),
	Net = require("@self/Net"),
	Progression = require("@self/Progression"),
	Rebirth = require("@self/Rebirth"),
	Remotes = require("@self/Remotes"),
	Rewards = require("@self/Rewards"),
	Settings = require("@self/Settings"),
	Shop = require("@self/Shop"),
	Signal = require("@self/Signal"),
	Sim = require("@self/Sim"),
	Strings = require("@self/Strings"),
	Test = require("@self/Test"),
	Tutorial = require("@self/Tutorial"),
	Types = require("@self/Types"),
	UI = require("@self/UI"),
	Util = require("@self/Util"),
	VFX = require("@self/VFX"),
	World = require("@self/World"),
}

return RBLXShared
