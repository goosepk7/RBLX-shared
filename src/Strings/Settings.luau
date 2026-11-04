--!strict
-- Settings screen (Shared.Settings). Keys start with "settings.". Language names are written in
-- their own language in every table, so a player can always find theirs.
local Loc = require("../Loc")

local LANGUAGES: { [string]: string } = {
	["settings.language.en"] = "English",
	["settings.language.pt-br"] = "Português (Brasil)",
	["settings.language.es"] = "Español",
}

local function with(t: { [string]: string }): Loc.Table
	for key, value in LANGUAGES do
		t[key] = value
	end
	return t
end

local strings: Loc.Tables = {
	en = with({
		["settings.title"] = "Settings",
		["settings.done"] = "Done",
		["settings.reset"] = "Restore defaults",
		["settings.section.audio"] = "Sound",
		["settings.section.comfort"] = "Comfort",
		["settings.section.accessibility"] = "Accessibility",
		["settings.section.controls"] = "Controls",
		["settings.section.language"] = "Language",
		["settings.section.game"] = "Game",
		["settings.musicVolume"] = "Music",
		["settings.sfxVolume"] = "Sound effects",
		["settings.uiSounds"] = "Menu sounds",
		["settings.cameraShake"] = "Camera shake",
		["settings.cameraShake.hint"] = "Turn it down or off if shaking bothers you.",
		["settings.flashes"] = "Screen flashes",
		["settings.flashes.hint"] = "Turn off if bright flashes bother you.",
		["settings.haptics"] = "Vibration",
		["settings.colorblind"] = "Colorblind colors",
		["settings.colorblind.off"] = "Off",
		["settings.colorblind.deuteranopia"] = "Red-green (deutan)",
		["settings.colorblind.protanopia"] = "Red-green (protan)",
		["settings.colorblind.tritanopia"] = "Blue-yellow (tritan)",
		["settings.controls"] = "Control scheme",
		["settings.controls.auto"] = "Automatic",
		["settings.language"] = "Language",
		["settings.language.auto"] = "Device language",
	}),
	["pt-br"] = with({
		["settings.title"] = "Configurações",
		["settings.done"] = "Pronto",
		["settings.reset"] = "Restaurar padrões",
		["settings.section.audio"] = "Som",
		["settings.section.comfort"] = "Conforto",
		["settings.section.accessibility"] = "Acessibilidade",
		["settings.section.controls"] = "Controles",
		["settings.section.language"] = "Idioma",
		["settings.section.game"] = "Jogo",
		["settings.musicVolume"] = "Música",
		["settings.sfxVolume"] = "Efeitos sonoros",
		["settings.uiSounds"] = "Sons do menu",
		["settings.cameraShake"] = "Tremor da câmera",
		["settings.cameraShake.hint"] = "Diminua ou desligue se o tremor incomodar.",
		["settings.flashes"] = "Flashes na tela",
		["settings.flashes.hint"] = "Desligue se flashes fortes incomodarem.",
		["settings.haptics"] = "Vibração",
		["settings.colorblind"] = "Cores para daltonismo",
		["settings.colorblind.off"] = "Desligado",
		["settings.colorblind.deuteranopia"] = "Vermelho-verde (deutan)",
		["settings.colorblind.protanopia"] = "Vermelho-verde (protan)",
		["settings.colorblind.tritanopia"] = "Azul-amarelo (tritan)",
		["settings.controls"] = "Esquema de controle",
		["settings.controls.auto"] = "Automático",
		["settings.language"] = "Idioma",
		["settings.language.auto"] = "Idioma do aparelho",
	}),
	es = with({
		["settings.title"] = "Ajustes",
		["settings.done"] = "Listo",
		["settings.reset"] = "Restablecer",
		["settings.section.audio"] = "Sonido",
		["settings.section.comfort"] = "Comodidad",
		["settings.section.accessibility"] = "Accesibilidad",
		["settings.section.controls"] = "Controles",
		["settings.section.language"] = "Idioma",
		["settings.section.game"] = "Juego",
		["settings.musicVolume"] = "Música",
		["settings.sfxVolume"] = "Efectos de sonido",
		["settings.uiSounds"] = "Sonidos del menú",
		["settings.cameraShake"] = "Vibración de cámara",
		["settings.cameraShake.hint"] = "Bájala o apágala si te molesta.",
		["settings.flashes"] = "Destellos en pantalla",
		["settings.flashes.hint"] = "Apágalos si los destellos te molestan.",
		["settings.haptics"] = "Vibración del control",
		["settings.colorblind"] = "Colores para daltonismo",
		["settings.colorblind.off"] = "Desactivado",
		["settings.colorblind.deuteranopia"] = "Rojo-verde (deutan)",
		["settings.colorblind.protanopia"] = "Rojo-verde (protan)",
		["settings.colorblind.tritanopia"] = "Azul-amarillo (tritan)",
		["settings.controls"] = "Esquema de control",
		["settings.controls.auto"] = "Automático",
		["settings.language"] = "Idioma",
		["settings.language.auto"] = "Idioma del dispositivo",
	}),
}

return strings
