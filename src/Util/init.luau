--!strict
--[[
	Internal helpers used by framework modules. Exposed on RBLXShared.Util for games that want
	the same behaviour (deep copies of templates, scoped logging), but the stable public API is
	documented in docs/API.md; anything not listed there may change between minor versions.
]]

return {
	Deep = require("@self/Deep"),
	Log = require("@self/Log"),
	Roblox = require("@self/Roblox"),
}
