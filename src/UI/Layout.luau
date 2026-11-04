--!strict
--[[
	Pure layout math: viewport scaling, safe zones, input-mode mapping.
	No Roblox globals, so all of it is unit-tested in lune.
]]

export type Rect = { x: number, y: number, w: number, h: number }
export type InputMode = "Touch" | "Gamepad" | "Keyboard"

local Layout = {}

-- Reference viewport: a 6.1" phone in landscape is ~844x390 points. All
-- token sizes are authored at that size; UIScale = shortEdge / REFERENCE.
Layout.REFERENCE_SHORT_EDGE = 390
-- Clamp floor chosen so the smallest tappable control (48 px) never renders
-- below the 44 px minimum tap target: 48 * 0.92 = 44.16.
Layout.MIN_SCALE = 0.92
-- Clamp ceiling keeps tablets/PC from turning the HUD into billboards.
Layout.MAX_SCALE = 1.6
-- Nothing critical in the top 12% of the screen (notch / status bar).
Layout.CRITICAL_TOP_FRACTION = 0.12
-- Side gutter applied inside the device safe area.
Layout.GUTTER = 12

function Layout.scaleFor(width: number, height: number): number
	local short = math.min(width, height)
	if short <= 0 then
		return 1
	end
	return math.clamp(short / Layout.REFERENCE_SHORT_EDGE, Layout.MIN_SCALE, Layout.MAX_SCALE)
end

--- Rendered pixel size of a token size at a given scale.
function Layout.px(tokenSize: number, scale: number): number
	return tokenSize * scale
end

--- Area reserved for the Roblox touch thumbstick (bottom-left). Matches the
--- dynamic thumbstick's activation region with a margin; nothing goes here.
function Layout.thumbstickZone(width: number, height: number): Rect
	return { x = 0, y = height * 0.45, w = width * 0.4, h = height * 0.55 }
end

--- Top strip where nothing critical may sit.
function Layout.criticalTopZone(width: number, height: number): Rect
	return { x = 0, y = 0, w = width, h = height * Layout.CRITICAL_TOP_FRACTION }
end

--- Primary-action thumb arc (bottom-right).
function Layout.thumbArcZone(width: number, height: number): Rect
	return { x = width * 0.62, y = height * 0.5, w = width * 0.38, h = height * 0.5 }
end

function Layout.overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

function Layout.contains(outer: Rect, inner: Rect): boolean
	return inner.x >= outer.x
		and inner.y >= outer.y
		and inner.x + inner.w <= outer.x + outer.w
		and inner.y + inner.h <= outer.y + outer.h
end

--- Content rect after applying insets {left, top, right, bottom} and gutter.
function Layout.safeRect(
	width: number,
	height: number,
	insets: { left: number, top: number, right: number, bottom: number }
): Rect
	local g = Layout.GUTTER
	local x = insets.left + g
	local y = insets.top
	local w = math.max(0, width - insets.left - insets.right - g * 2)
	local h = math.max(0, height - insets.top - insets.bottom - g)
	return { x = x, y = y, w = w, h = h }
end

local TOUCH = { Touch = true }
local GAMEPAD = {
	Gamepad1 = true,
	Gamepad2 = true,
	Gamepad3 = true,
	Gamepad4 = true,
	Gamepad5 = true,
	Gamepad6 = true,
	Gamepad7 = true,
	Gamepad8 = true,
}
local KEYBOARD = {
	Keyboard = true,
	MouseButton1 = true,
	MouseButton2 = true,
	MouseButton3 = true,
	MouseWheel = true,
	MouseMovement = true,
}

--- Maps an Enum.UserInputType name to an input mode, or nil when the input
--- should not change the current mode (Focus, Accelerometer, ...).
function Layout.inputModeFor(userInputTypeName: string): InputMode?
	if TOUCH[userInputTypeName] then
		return "Touch"
	elseif GAMEPAD[userInputTypeName] then
		return "Gamepad"
	elseif KEYBOARD[userInputTypeName] then
		return "Keyboard"
	end
	return nil
end

--- Drawer presentation: bottom sheet on touch/narrow screens, side panel otherwise.
function Layout.drawerStyle(mode: InputMode, width: number, height: number): "Sheet" | "Side"
	if mode == "Touch" or width < height then
		return "Sheet"
	end
	return "Side"
end

--- Columns for an auto-cell grid given container width and min cell width.
function Layout.gridColumns(containerWidth: number, minCell: number, gap: number): number
	if minCell <= 0 then
		return 1
	end
	return math.max(1, math.floor((containerWidth + gap) / (minCell + gap)))
end

return Layout
