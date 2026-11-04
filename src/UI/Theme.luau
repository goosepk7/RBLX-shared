--!strict
--[[
	Theme: runtime accessors over Tokens.

	All Roblox value construction (Color3, Font, Enum) happens inside
	functions, never at require time, so lune can require this module.

	Usage (game client bootstrap, before building any UI):
		local UI = require(Packages.RBLXShared).UI
		UI.Theme.setGame("stilts")
]]

local Color = require("./Color")
local Tokens = require("./Tokens")

export type GameId = Tokens.GameId

export type ColorName =
	"ink"
	| "inkSoft"
	| "paper"
	| "paper2"
	| "line"
	| "lineDark"
	| "shadow"
	| "white"
	| "success"
	| "successEdge"
	| "danger"
	| "dangerEdge"
	| "warning"
	| "warningEdge"
	| "info"
	| "infoEdge"
	| "gold"
	| "goldEdge"
	| "primary"
	| "primaryEdge"
	| "secondary"
	| "secondaryEdge"

export type FontRole = "display" | "number" | "button" | "body" | "value" | "caption"
export type TextSize = "h1" | "h2" | "h3" | "body" | "caption" | "button" | "number"

-- Visual variants shared by Button, Chip, Banner, Toast, ProgressBar fills.
export type Variant = "Primary" | "Secondary" | "Success" | "Danger" | "Warning" | "Info" | "Gold" | "Ghost"

export type VariantColors = {
	fill: ColorName,
	edge: ColorName,
	text: ColorName,
	-- Stroke drawn around label text for legibility on saturated fills.
	textStroke: ColorName?,
	border: ColorName?,
}

local Theme = {}

Theme.tokens = Tokens

export type Palette = "off" | "deuteranopia" | "protanopia" | "tritanopia"

local currentGame: GameId = Tokens.defaultGame :: any
local listeners: { (GameId) -> () } = {}
local currentPalette: Palette = "off"
local paletteListeners: { (Palette) -> () } = {}

local VARIANTS: { [Variant]: VariantColors } = {
	Primary = { fill = "primary", edge = "primaryEdge", text = "white", textStroke = "primaryEdge" },
	Secondary = { fill = "paper", edge = "lineDark", text = "ink", border = "line" },
	Success = { fill = "success", edge = "successEdge", text = "white", textStroke = "successEdge" },
	Danger = { fill = "danger", edge = "dangerEdge", text = "white", textStroke = "dangerEdge" },
	-- Warning and Gold are light fills: Ink text reads better than white.
	Warning = { fill = "warning", edge = "warningEdge", text = "ink" },
	Info = { fill = "info", edge = "infoEdge", text = "white", textStroke = "infoEdge" },
	Gold = { fill = "gold", edge = "goldEdge", text = "ink" },
	Ghost = { fill = "paper", edge = "paper", text = "ink" },
}

Theme.VARIANTS = VARIANTS

function Theme.setGame(id: GameId)
	if Tokens.accents[id] == nil then
		error(`UI.Theme.setGame: unknown game "{id}"`, 2)
	end
	if id == currentGame then
		return
	end
	currentGame = id
	for _, fn in listeners do
		task.spawn(fn, id)
	end
end

function Theme.getGame(): GameId
	return currentGame
end

--- Subscribe to accent changes (used by the gallery). Returns a disconnect fn.
function Theme.onGameChanged(fn: (GameId) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then
			table.remove(listeners, i)
		end
	end
end

--- Switches the status colors to a colorblind palette ("off" restores the brief's palette).
--- UI built afterwards uses it; screens listen with onPaletteChanged to rebuild.
function Theme.setPalette(palette: Palette)
	if palette ~= "off" and Tokens.colorblind[palette] == nil then
		error(`UI.Theme.setPalette: unknown palette "{palette}"`, 2)
	end
	if palette == currentPalette then
		return
	end
	currentPalette = palette
	for _, fn in table.clone(paletteListeners) do
		task.spawn(fn, palette)
	end
end

function Theme.getPalette(): Palette
	return currentPalette
end

function Theme.onPaletteChanged(fn: (Palette) -> ()): () -> ()
	table.insert(paletteListeners, fn)
	return function()
		local i = table.find(paletteListeners, fn)
		if i then
			table.remove(paletteListeners, i)
		end
	end
end

--- Hex value for a token name under the current game's accent and colorblind palette.
function Theme.hex(name: ColorName, game: GameId?): string
	local accent = (Tokens.accents :: any)[game or currentGame]
	local override = if currentPalette ~= "off" then Tokens.colorblind[currentPalette][name] else nil
	local value = override or accent[name] or (Tokens.palette :: any)[name]
	if value == nil then
		error(`UI.Theme: unknown color token "{name}"`, 2)
	end
	return value
end

function Theme.rgb(name: ColorName, game: GameId?): Color.RGB
	return Color.parse(Theme.hex(name, game))
end

function Theme.color(name: ColorName, game: GameId?): Color3
	local c = Theme.rgb(name, game)
	return Color3.fromRGB(c.r, c.g, c.b)
end

function Theme.variant(v: Variant): VariantColors
	local colors = VARIANTS[v]
	if colors == nil then
		error(`UI.Theme: unknown variant "{v}"`, 2)
	end
	return colors
end

function Theme.font(role: FontRole): Font
	local spec = Tokens.fontRoles[role]
	local family = (Tokens.fonts :: any)[spec.family]
	return Font.new(family, (Enum.FontWeight :: any)[spec.weight], Enum.FontStyle.Normal)
end

function Theme.textSize(name: TextSize): number
	return (Tokens.type :: any)[name]
end

return Theme
