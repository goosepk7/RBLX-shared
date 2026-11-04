--!strict
--[[
	The framework's own player-facing strings (en, pt-br, es), merged from one module per area.
	Games merge them under their own tables:

		local loc = Shared.Loc.new({ tables = Shared.Loc.merge(Shared.Strings, require(Game.Strings)) })

	Each area owns its file and its key prefix ("common.", "settings.", "admin.", ...).
	tests/Loc/Strings.spec.luau runs Loc.validate over the result, so every locale must be
	complete and every placeholder must match the English source.
]]

local Loc = require("./Loc")

return Loc.merge(
	require("@self/Admin"),
	require("@self/Badges"),
	require("@self/Codes"),
	require("@self/Common"),
	require("@self/Daily"),
	require("@self/Errors"),
	require("@self/Events"),
	require("@self/Leaderboards"),
	require("@self/Rebirth"),
	require("@self/Rewards"),
	require("@self/Settings"),
	require("@self/Shop"),
	require("@self/Time"),
	require("@self/Tutorial")
)
