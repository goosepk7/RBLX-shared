--!strict
-- Strings for the tutorial coachmarks. Keys start with "tutorial.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["tutorial.next"] = "Next",
		["tutorial.skip"] = "Skip",
		["tutorial.done"] = "Got it!",
		["tutorial.step"] = "{step}/{total}",
	},
	["pt-br"] = {
		["tutorial.next"] = "Próximo",
		["tutorial.skip"] = "Pular",
		["tutorial.done"] = "Entendi!",
		["tutorial.step"] = "{step}/{total}",
	},
	es = {
		["tutorial.next"] = "Siguiente",
		["tutorial.skip"] = "Saltar",
		["tutorial.done"] = "¡Entendido!",
		["tutorial.step"] = "{step}/{total}",
	},
}

return strings
