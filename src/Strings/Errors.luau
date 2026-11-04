--!strict
-- Strings for request failures any v0.2 screen can show. Keys start with "errors.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["errors.rate_limited"] = "Slow down a little and try again.",
		["errors.timeout"] = "The server didn't answer. Try again.",
		["errors.disabled"] = "This is switched off for now.",
		["errors.unavailable"] = "This is unavailable right now. Try again soon.",
		["errors.notLoaded"] = "Your data is still loading. Try again in a moment.",
	},
	["pt-br"] = {
		["errors.rate_limited"] = "Vá com calma e tente de novo.",
		["errors.timeout"] = "O servidor não respondeu. Tente de novo.",
		["errors.disabled"] = "Isso está desligado por enquanto.",
		["errors.unavailable"] = "Indisponível agora. Tente de novo em breve.",
		["errors.notLoaded"] = "Seus dados ainda estão carregando. Tente de novo já já.",
	},
	es = {
		["errors.rate_limited"] = "Ve más despacio e inténtalo de nuevo.",
		["errors.timeout"] = "El servidor no respondió. Inténtalo de nuevo.",
		["errors.disabled"] = "Esto está desactivado por ahora.",
		["errors.unavailable"] = "No disponible ahora. Inténtalo pronto.",
		["errors.notLoaded"] = "Tus datos aún se están cargando. Inténtalo en un momento.",
	},
}

return strings
