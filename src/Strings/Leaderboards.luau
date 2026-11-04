--!strict
-- Strings for the Leaderboards screen and wall boards. Keys start with "leaderboards.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["leaderboards.title"] = "Leaderboards",
		["leaderboards.you"] = "You",
		["leaderboards.unranked"] = "Not ranked yet",
		["leaderboards.resetsIn"] = "Resets in {time}",
		["leaderboards.empty"] = "No scores yet. Be the first!",
		["leaderboards.time"] = "{seconds}s",
	},
	["pt-br"] = {
		["leaderboards.title"] = "Placares",
		["leaderboards.you"] = "Você",
		["leaderboards.unranked"] = "Ainda sem posição",
		["leaderboards.resetsIn"] = "Reinicia em {time}",
		["leaderboards.empty"] = "Ninguém pontuou ainda. Seja o primeiro!",
		["leaderboards.time"] = "{seconds}s",
	},
	es = {
		["leaderboards.title"] = "Clasificaciones",
		["leaderboards.you"] = "Tú",
		["leaderboards.unranked"] = "Aún sin puesto",
		["leaderboards.resetsIn"] = "Se reinicia en {time}",
		["leaderboards.empty"] = "Nadie ha puntuado aún. ¡Sé el primero!",
		["leaderboards.time"] = "{seconds} s",
	},
}

return strings
