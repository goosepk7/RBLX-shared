--!strict
-- Strings for the Daily Rewards screen. Keys start with "daily.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["daily.title"] = "Daily Rewards",
		["daily.claim"] = "Claim",
		["daily.claimed"] = "Come back tomorrow!",
		["daily.day"] = "Day {day}",
		["daily.today"] = "Today",
		["daily.nextIn"] = "Next reward in {time}",
		["daily.streak"] = { one = "{count} day streak", other = "{count} day streak" },
		["daily.broken"] = "Streak reset. Starting again at day 1.",
		["daily.fail.claimed"] = "Already claimed today.",
	},
	["pt-br"] = {
		["daily.title"] = "Recompensas Diárias",
		["daily.claim"] = "Pegar",
		["daily.claimed"] = "Volte amanhã!",
		["daily.day"] = "Dia {day}",
		["daily.today"] = "Hoje",
		["daily.nextIn"] = "Próxima recompensa em {time}",
		["daily.streak"] = { one = "{count} dia seguido", other = "{count} dias seguidos" },
		["daily.broken"] = "Sequência perdida. Recomeçando do dia 1.",
		["daily.fail.claimed"] = "Você já pegou a de hoje.",
	},
	es = {
		["daily.title"] = "Recompensas Diarias",
		["daily.claim"] = "Reclamar",
		["daily.claimed"] = "¡Vuelve mañana!",
		["daily.day"] = "Día {day}",
		["daily.today"] = "Hoy",
		["daily.nextIn"] = "Siguiente recompensa en {time}",
		["daily.streak"] = { one = "{count} día seguido", other = "{count} días seguidos" },
		["daily.broken"] = "Racha perdida. Empiezas de nuevo en el día 1.",
		["daily.fail.claimed"] = "Ya reclamaste la de hoy.",
	},
}

return strings
