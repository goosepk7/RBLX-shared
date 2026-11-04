--!strict
-- Strings for reward lines ("+50 Wins", boosts, multipliers) on every v0.2 screen. Keys start with "rewards.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["rewards.multiplier"] = "x{value}",
		["rewards.currency"] = "+{amount} {currency}",
		["rewards.duplicate"] = "{item} (already owned)",
		["rewards.boost"] = "{boost} for {time}",
	},
	["pt-br"] = {
		["rewards.multiplier"] = "x{value}",
		["rewards.currency"] = "+{amount} {currency}",
		["rewards.duplicate"] = "{item} (você já tinha)",
		["rewards.boost"] = "{boost} por {time}",
	},
	es = {
		["rewards.multiplier"] = "x{value}",
		["rewards.currency"] = "+{amount} {currency}",
		["rewards.duplicate"] = "{item} (ya lo tenías)",
		["rewards.boost"] = "{boost} durante {time}",
	},
}

return strings
