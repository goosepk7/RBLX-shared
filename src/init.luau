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
	Data = require("@self/Data"),
	Economy = require("@self/Economy"),
	Loc = require("@self/Loc"),
	Net = require("@self/Net"),
	Settings = require("@self/Settings"),
	Signal = require("@self/Signal"),
	Strings = require("@self/Strings"),
	Sim = require("@self/Sim"),
	Test = require("@self/Test"),
	Types = require("@self/Types"),
	Util = require("@self/Util"),
	UI = require("@self/UI"),
	VFX = require("@self/VFX"),
	World = require("@self/World"),
}

return RBLXShared
