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

	AntiExploit = require("@self/AntiExploit"),
	Assets = require("@self/Assets"),
	Data = require("@self/Data"),
	Economy = require("@self/Economy"),
	Loc = require("@self/Loc"),
	Net = require("@self/Net"),
	Signal = require("@self/Signal"),
	Sim = require("@self/Sim"),
	Test = require("@self/Test"),
	Types = require("@self/Types"),
	Util = require("@self/Util"),
	UI = require("@self/UI"),
	World = require("@self/World"),
}

return RBLXShared
