--!strict
-- Strings for badge toasts and announcements. Keys start with "badges.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["badges.earned"] = "Badge earned!",
		["badges.announce"] = "{name} earned {badge}!",
	},
	["pt-br"] = {
		["badges.earned"] = "Emblema conquistado!",
		["badges.announce"] = "{name} conquistou {badge}!",
	},
	es = {
		["badges.earned"] = "¡Insignia conseguida!",
		["badges.announce"] = "¡{name} consiguió {badge}!",
	},
}

return strings
