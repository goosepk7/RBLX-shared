--!strict
-- Strings for the Codes screen. Keys start with "codes.".
local Loc = require("../Loc")

local strings: Loc.Tables = {
	en = {
		["codes.title"] = "Codes",
		["codes.placeholder"] = "Enter code",
		["codes.redeem"] = "Redeem",
		["codes.hint"] = "New codes come with updates and events.",
		["codes.success"] = "Code redeemed!",
		["codes.fail.invalid"] = "Codes are 3 to 24 letters and numbers.",
		["codes.fail.unknown"] = "That code doesn't exist.",
		["codes.fail.expired"] = "That code has expired.",
		["codes.fail.redeemed"] = "You've already used this code.",
		["codes.fail.exhausted"] = "That code has run out.",
		["codes.fail.requirements"] = "You can't use this code yet.",
		["codes.fail.tooManyAttempts"] = "Too many tries. Wait a few minutes.",
		["codes.fail.busy"] = "Still checking your last code.",
		["codes.fail.unavailable"] = "Codes are unavailable right now. Try again soon.",
	},
	["pt-br"] = {
		["codes.title"] = "Códigos",
		["codes.placeholder"] = "Digite o código",
		["codes.redeem"] = "Resgatar",
		["codes.hint"] = "Novos códigos chegam com atualizações e eventos.",
		["codes.success"] = "Código resgatado!",
		["codes.fail.invalid"] = "Códigos têm de 3 a 24 letras e números.",
		["codes.fail.unknown"] = "Esse código não existe.",
		["codes.fail.expired"] = "Esse código expirou.",
		["codes.fail.redeemed"] = "Você já usou esse código.",
		["codes.fail.exhausted"] = "Esse código esgotou.",
		["codes.fail.requirements"] = "Você ainda não pode usar esse código.",
		["codes.fail.tooManyAttempts"] = "Tentativas demais. Espere alguns minutos.",
		["codes.fail.busy"] = "Ainda verificando seu último código.",
		["codes.fail.unavailable"] = "Códigos indisponíveis agora. Tente de novo em breve.",
	},
	es = {
		["codes.title"] = "Códigos",
		["codes.placeholder"] = "Escribe el código",
		["codes.redeem"] = "Canjear",
		["codes.hint"] = "Hay códigos nuevos con cada actualización y evento.",
		["codes.success"] = "¡Código canjeado!",
		["codes.fail.invalid"] = "Los códigos tienen de 3 a 24 letras y números.",
		["codes.fail.unknown"] = "Ese código no existe.",
		["codes.fail.expired"] = "Ese código ya expiró.",
		["codes.fail.redeemed"] = "Ya usaste este código.",
		["codes.fail.exhausted"] = "Ese código se agotó.",
		["codes.fail.requirements"] = "Todavía no puedes usar este código.",
		["codes.fail.tooManyAttempts"] = "Demasiados intentos. Espera unos minutos.",
		["codes.fail.busy"] = "Todavía revisando tu último código.",
		["codes.fail.unavailable"] = "Los códigos no están disponibles ahora. Inténtalo pronto.",
	},
}

return strings
