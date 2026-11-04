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

local currentGame: GameId = Tokens.defaultGame
local listeners: { (GameId) -> () } = {}

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

--- Hex value for a token name under the current game's accent.
function Theme.hex(name: ColorName, game: GameId?): string
	local accent = (Tokens.accents :: any)[game or currentGame]
	local value = accent[name] or (Tokens.palette :: any)[name]
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
