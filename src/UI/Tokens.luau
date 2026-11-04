--!strict
--[[
	UI design tokens ("Arcade Workshop", brief §5.2).

	Pure data: no Roblox globals and no requires, so lune tests can load it
	directly. `Theme.luau` turns these into Color3 / Font / UDim values at
	runtime. Every color used anywhere in the kit must come from this file;
	reviewers fail any literal color in component or game code (§5.8).
]]

export type Hex = string

export type AccentTokens = {
	primary: Hex,
	primaryEdge: Hex,
	secondary: Hex,
	secondaryEdge: Hex,
}

export type GameId = "stilts" | "car"

local Tokens = {}

-- Base palette shared by both games.
Tokens.palette = {
	ink = "#1E2235", -- text on light surfaces; never pure black
	inkSoft = "#5A6178", -- secondary text (ink at ~70% on paper)
	paper = "#FFFFFF", -- card surface
	paper2 = "#F3F5FA", -- panel background
	line = "#D9DEEA", -- card border
	lineDark = "#B9C0D3", -- bottom edge under Paper-filled buttons and cards
	shadow = "#1E2235", -- drawn at shadowTransparency (rgba(30,34,53,0.22))
	white = "#FFFFFF",

	success = "#3DD68C",
	successEdge = "#1FA466",
	danger = "#FF5A6E",
	dangerEdge = "#C8384A",
	warning = "#FFC53D",
	warningEdge = "#D39A12",
	info = "#4DA3FF",
	infoEdge = "#2B74C9",
	gold = "#FFD166", -- premium / Robux surfaces only
	goldEdge = "#B8860B",
}

-- Per-game accents (§5.2). `secondaryEdge` is derived (secondary darkened
-- ~22%) so secondary-filled surfaces get the same 3D edge treatment.
Tokens.accents = {
	stilts = {
		primary = "#FF7A1A",
		primaryEdge = "#C85A08",
		secondary = "#6C5CE7",
		secondaryEdge = "#4A3DB8",
	} :: AccentTokens,
	car = {
		primary = "#2EC4B6",
		primaryEdge = "#1C8D82",
		secondary = "#FF9F1C",
		secondaryEdge = "#C77606",
	} :: AccentTokens,
}

Tokens.defaultGame = "stilts" :: GameId

-- Colorblind palettes (Settings > Colorblind). Each overrides only the status colors whose
-- meaning would be lost: red/green confusion moves Success to blue (and Info to cyan, so the
-- two stay apart by lightness); blue/yellow confusion moves Info to magenta and Warning to
-- orange. Icons and text carry meaning too; these are the second channel, not the only one.
Tokens.colorblind = {
	deuteranopia = {
		success = "#3D8BFF",
		successEdge = "#2160C0",
		info = "#36C9DC",
		infoEdge = "#1E8E9C",
	},
	protanopia = {
		success = "#3D8BFF",
		successEdge = "#2160C0",
		info = "#36C9DC",
		infoEdge = "#1E8E9C",
		danger = "#FF4F8B", -- protans see red darker; a pinker red keeps it bright
		dangerEdge = "#C22F64",
	},
	tritanopia = {
		info = "#E05AA8",
		infoEdge = "#A8357A",
		warning = "#FF9A4C",
		warningEdge = "#C96A22",
	},
} :: { [string]: { [string]: string } }

-- Transparency values (Roblox convention: 0 = opaque, 1 = invisible).
Tokens.alpha = {
	shadow = 0.78, -- 22% shadow
	backdrop = 0.45, -- 55% dim behind modals
	disabled = 0.45, -- disabled controls render at 55% opacity
	highlight = 0.82, -- 18% white sticker highlight
	inkOutline = 0.15, -- icon outline is Ink at 85%
}

-- Fonts: Roblox built-in families, no uploads needed (§5.2).
Tokens.fonts = {
	display = "rbxasset://fonts/families/FredokaOne.json",
	body = "rbxasset://fonts/families/BuilderSans.json",
}

-- Font roles -> family key + weight name (Enum.FontWeight member).
Tokens.fontRoles = {
	display = { family = "display", weight = "Regular" },
	number = { family = "display", weight = "Regular" }, -- animated numbers, always stroked
	button = { family = "body", weight = "Bold" },
	body = { family = "body", weight = "Medium" },
	value = { family = "body", weight = "SemiBold" },
	caption = { family = "body", weight = "Medium" },
}

-- Type scale in px at the reference viewport (scaled by UIScale, see Layout).
Tokens.type = {
	h1 = 34,
	h2 = 26,
	h3 = 20,
	body = 16,
	caption = 13,
	button = 18,
	number = 24,
}

-- Shape (§5.2).
Tokens.radius = {
	card = 14,
	button = 12,
	chip = 10,
	pill = 999,
}

Tokens.border = {
	card = 2,
	numberStroke = 2,
}

-- The "3D" bottom edge.
Tokens.edge = {
	button = 6,
	card = 6,
	chip = 4,
	pressed = 2,
}

-- Spacing scale (px at reference).
Tokens.space = {
	xxs = 2,
	xs = 4,
	sm = 8,
	md = 12,
	lg = 16,
	xl = 24,
	xxl = 32,
}

-- Sizes (px at reference). Every tappable control is >= tapMin at the
-- smallest clamped scale; see Layout.MIN_SCALE and the tap-target test.
Tokens.size = {
	tapMin = 44,
	buttonHeight = 56,
	buttonHeightSmall = 48,
	iconButton = 52,
	iconButtonGap = 8,
	chipHeight = 52, -- chips are tappable; visual pill is smaller inside the hit box
	closeButton = 52,
	pillHeight = 52,
	rowHeight = 64,
	tabHeight = 52,
	progressHeight = 18,
	iconSm = 24,
	iconMd = 32,
	iconLg = 48,
	panelHeader = 64,
}

-- Motion (§5.7). Durations in seconds; easing names are Enum.EasingStyle /
-- Enum.EasingDirection members.
Tokens.motion = {
	pressDuration = 0.08,
	pressScale = 0.96,
	releaseDuration = 0.18,
	hoverLift = 2,
	enterDuration = 0.22,
	exitDuration = 0.14,
	fastDuration = 0.12,
	modalStartScale = 0.9,
	toastHold = 2.6,
	bannerHold = 4.0,
	numberPopDuration = 0.7,
	numberPopRise = 56,
	numberPopJitter = 18,
	bigValueRatio = 0.10, -- NumberPop: >= 10% of current value is "big"
	tabSlide = 0.18,
	progressFill = 0.35,
	countUp = 0.45,
	confettiCount = 28,
	confettiDuration = 1.1,
}

-- Display order for stacking (ZIndex on ScreenGuis via DisplayOrder).
Tokens.layers = {
	hud = 10,
	screen = 20,
	modal = 30,
	toast = 40,
	banner = 45,
	gallery = 90,
}

Tokens.limits = {
	maxModals = 2, -- §5.4: never stack more than 2 modals
}

return Tokens
