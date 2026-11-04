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

	Test = require("@self/Test"),
	UI = require("@self/UI"),
}

return RBLXShared
