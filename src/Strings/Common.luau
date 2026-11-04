--!strict
-- Strings every shared screen uses (buttons, states). Keys start with "common.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["common.close"] = "Close",
		["common.back"] = "Back",
		["common.cancel"] = "Cancel",
		["common.confirm"] = "Confirm",
		["common.apply"] = "Apply",
		["common.retry"] = "Try again",
		["common.on"] = "On",
		["common.off"] = "Off",
		["common.loading"] = "Loading",
		["common.percent"] = "{value:raw}%",
		["common.error"] = "Something went wrong. Try again in a moment.",
	},
	["pt-br"] = {
		["common.close"] = "Fechar",
		["common.back"] = "Voltar",
		["common.cancel"] = "Cancelar",
		["common.confirm"] = "Confirmar",
		["common.apply"] = "Aplicar",
		["common.retry"] = "Tentar de novo",
		["common.on"] = "Ligado",
		["common.off"] = "Desligado",
		["common.loading"] = "Carregando",
		["common.percent"] = "{value:raw}%",
		["common.error"] = "Algo deu errado. Tente de novo daqui a pouco.",
	},
	es = {
		["common.close"] = "Cerrar",
		["common.back"] = "Atrás",
		["common.cancel"] = "Cancelar",
		["common.confirm"] = "Confirmar",
		["common.apply"] = "Aplicar",
		["common.retry"] = "Reintentar",
		["common.on"] = "Activado",
		["common.off"] = "Desactivado",
		["common.loading"] = "Cargando",
		["common.percent"] = "{value:raw}%",
		["common.error"] = "Algo salió mal. Inténtalo de nuevo en un momento.",
	},
}

return strings
