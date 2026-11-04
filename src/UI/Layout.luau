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

-- Bold BuilderSans averages about 0.55 em per character across en / pt-br / es; 0.58 leaves
-- headroom. Used to pick a short form of a label before Roblox lays it out (TextFits is
-- the backstop), and by layout tests that check long translations fit.
Layout.TEXT_EM = 0.58

-- Estimated width in px of one line of `text` at `size` px (both at reference scale).
function Layout.textWidth(text: string, size: number): number
	return (utf8.len(text) or #text) * size * Layout.TEXT_EM
end

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

--- Area reserved for the Roblox touch thumbstick. Matches the activation
--- frame of PlayerModule's DynamicThumbstick in landscape: left 40% of the
--- screen, bottom two-thirds (Position (0, 1/3), Size (0.4, 2/3)). No
--- input-sinking HUD element may sit here (§5.8).
function Layout.thumbstickZone(width: number, height: number): Rect
	return { x = 0, y = height / 3, w = width * 0.4, h = height * 2 / 3 }
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

export type AnchorName = "TopLeft" | "TopCenter" | "TopRight" | "RightRail" | "BottomRight" | "BottomCenter" | "Center"

-- Reference sizes (px at scale 1) for the HUD anchors (§5.4). Kept here, not
-- in SafeArea, so tests can check the real geometry against the zones.
Layout.ANCHOR = {
	topMargin = 8,
	pillStack = 2 * (52 + 4) + 8, -- two CurrencyPills + gap
	bannerLane = 52 + 4 + 8,
	iconButton = 52,
	iconButtonRow = 52 + 4,
	chipRow = 44 + 4,
	sideGap = 8, -- clearance between the prompt chip lane and the zones
}

--- HUD anchor rects in screen px. `content` is the safe content rect in
--- screen coordinates (Layout.safeRect at runtime), `s` the UI scale.
--- TopLeft (non-Active currency pills, see CurrencyPill) and Center (modals,
--- full screen by design) are allowed to reach into the thumbstick zone;
--- every other anchor must stay clear of it.
function Layout.anchors(width: number, height: number, content: Rect, s: number): { [AnchorName]: Rect }
	local A = Layout.ANCHOR
	local c = content
	local stick = Layout.thumbstickZone(width, height)
	local arc = Layout.thumbArcZone(width, height)
	local railH = c.h * 0.5
	local bottomRightW = c.w * 0.38
	local chipH = A.chipRow * s
	local chipLeft = math.max(c.x, stick.x + stick.w + A.sideGap * s)
	local chipRight = math.min(c.x + c.w, arc.x - A.sideGap * s)
	return {
		TopLeft = { x = c.x, y = c.y + A.topMargin * s, w = c.w * 0.3, h = A.pillStack * s },
		TopCenter = { x = c.x + c.w * 0.3, y = c.y, w = c.w * 0.4, h = A.bannerLane * s },
		TopRight = { x = c.x + c.w * 0.7, y = c.y + A.topMargin * s, w = c.w * 0.3, h = A.iconButtonRow * s },
		RightRail = {
			x = c.x + c.w - A.iconButton * s,
			y = c.y + c.h * 0.42 - railH / 2,
			w = A.iconButton * s,
			h = railH,
		},
		BottomRight = { x = c.x + c.w - bottomRightW, y = c.y + c.h * 0.5, w = bottomRightW, h = c.h * 0.5 },
		BottomCenter = { x = chipLeft, y = c.y + c.h - chipH, w = math.max(0, chipRight - chipLeft), h = chipH },
		Center = { x = c.x, y = c.y, w = c.w, h = c.h },
	}
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
