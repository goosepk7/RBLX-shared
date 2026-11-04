--!strict
-- Strings for countdowns ("2h 05m") on every v0.2 screen. Keys start with "time.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["time.days"] = "{d}d {h}h",
		["time.hours"] = "{h}h {m}m",
		["time.minutes"] = "{m}m {s}s",
		["time.seconds"] = "{s}s",
	},
	["pt-br"] = {
		["time.days"] = "{d}d {h}h",
		["time.hours"] = "{h}h {m}min",
		["time.minutes"] = "{m}min {s}s",
		["time.seconds"] = "{s}s",
	},
	es = {
		["time.days"] = "{d} d {h} h",
		["time.hours"] = "{h} h {m} min",
		["time.minutes"] = "{m} min {s} s",
		["time.seconds"] = "{s} s",
	},
}

return strings
