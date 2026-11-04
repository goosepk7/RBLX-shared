--!strict
--[[
	Pure color math on 0-255 RGB triples. No Roblox globals, so it is
	testable in lune. Theme converts results to Color3.
]]

export type RGB = { r: number, g: number, b: number }

local Color = {}

local function clampByte(v: number): number
	return math.clamp(math.floor(v + 0.5), 0, 255)
end

--- Parses "#RRGGBB" (or "RRGGBB"). Errors on anything else so a typo in the
--- token file fails loudly instead of rendering black.
function Color.parse(hex: string): RGB
	local digits = string.match(hex, "^#?(%x%x%x%x%x%x)$")
	if digits == nil then
		error(`UI.Color: invalid hex color "{hex}" (expected #RRGGBB)`, 2)
	end
	return {
		r = tonumber(string.sub(digits, 1, 2), 16) :: number,
		g = tonumber(string.sub(digits, 3, 4), 16) :: number,
		b = tonumber(string.sub(digits, 5, 6), 16) :: number,
	}
end

function Color.toHex(c: RGB): string
	return string.format("#%02X%02X%02X", clampByte(c.r), clampByte(c.g), clampByte(c.b))
end

--- Linear mix: t = 0 returns a, t = 1 returns b.
function Color.mix(a: RGB, b: RGB, t: number): RGB
	return {
		r = clampByte(a.r + (b.r - a.r) * t),
		g = clampByte(a.g + (b.g - a.g) * t),
		b = clampByte(a.b + (b.b - a.b) * t),
	}
end

--- Darkens toward Ink (not black) so shaded surfaces keep the palette's hue.
function Color.shade(c: RGB, amount: number, ink: RGB?): RGB
	return Color.mix(c, ink or { r = 30, g = 34, b = 53 }, amount)
end

local function channel(v: number): number
	local s = v / 255
	if s <= 0.03928 then
		return s / 12.92
	end
	return ((s + 0.055) / 1.055) ^ 2.4
end

--- WCAG relative luminance, 0..1.
function Color.luminance(c: RGB): number
	return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
end

--- WCAG contrast ratio, 1..21.
function Color.contrast(a: RGB, b: RGB): number
	local la, lb = Color.luminance(a), Color.luminance(b)
	if la < lb then
		la, lb = lb, la
	end
	return (la + 0.05) / (lb + 0.05)
end

return Color
