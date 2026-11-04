--!strict
local Layout = require("@shared/UI/Layout")
local Tokens = require("@shared/UI/Tokens")
local T = require("@shared/Test")
local expect = T.expect

T.describe("UI.Layout", function()
	T.it("scales by the shorter screen edge, clamped", function()
		expect(Layout.scaleFor(844, 390)).toBeNear(1, 1e-9)
		expect(Layout.scaleFor(390, 844)).toBeNear(1, 1e-9)
		expect(Layout.scaleFor(800, 360)).toBeNear(360 / 390, 1e-9) -- 0.923, just above the floor
		expect(Layout.scaleFor(568, 320)).toBe(Layout.MIN_SCALE)
		expect(Layout.scaleFor(1920, 1080)).toBe(Layout.MAX_SCALE)
		expect(Layout.scaleFor(0, 0)).toBe(1)
	end)

	T.it("every tappable control is >= 44 px at the smallest scale (§5.2)", function()
		local s = Layout.MIN_SCALE
		local tappable = {
			button = Tokens.size.buttonHeight + Tokens.edge.button,
			buttonSmall = Tokens.size.buttonHeightSmall,
			iconButton = Tokens.size.iconButton,
			chip = Tokens.size.chipHeight + Tokens.edge.chip,
			close = Tokens.size.closeButton,
			pill = Tokens.size.pillHeight,
			pillPlus = Tokens.size.pillHeight - 4,
			tab = Tokens.size.tabHeight,
			row = Tokens.size.rowHeight,
		}
		for name, px in tappable do
			if Layout.px(px, s) < Tokens.size.tapMin then
				error(`{name} renders at {Layout.px(px, s)} px (< {Tokens.size.tapMin})`)
			end
		end
	end)

	T.it("keeps the thumbstick zone and the primary-action arc apart", function()
		for _, size in { { 844, 390 }, { 800, 360 }, { 1194, 834 }, { 1920, 1080 } } do
			local w, h = size[1], size[2]
			expect(Layout.overlaps(Layout.thumbstickZone(w, h), Layout.thumbArcZone(w, h))).toBe(false)
			expect(Layout.overlaps(Layout.criticalTopZone(w, h), Layout.thumbArcZone(w, h))).toBe(false)
		end
	end)

	T.it("rect helpers", function()
		local a = { x = 0, y = 0, w = 10, h = 10 }
		expect(Layout.overlaps(a, { x = 9, y = 9, w = 5, h = 5 })).toBe(true)
		expect(Layout.overlaps(a, { x = 10, y = 0, w = 5, h = 5 })).toBe(false)
		expect(Layout.contains(a, { x = 2, y = 2, w = 3, h = 3 })).toBe(true)
		expect(Layout.contains(a, { x = 8, y = 8, w = 3, h = 3 })).toBe(false)
	end)

	T.it("safe rect applies insets and gutter", function()
		local r = Layout.safeRect(844, 390, { left = 47, top = 0, right = 47, bottom = 21 })
		expect(r).toEqual({ x = 59, y = 0, w = 844 - 94 - 24, h = 390 - 21 - 12 })
	end)

	T.it("maps input types to modes", function()
		expect(Layout.inputModeFor("Touch")).toBe("Touch")
		expect(Layout.inputModeFor("Gamepad3")).toBe("Gamepad")
		expect(Layout.inputModeFor("MouseMovement")).toBe("Keyboard")
		expect(Layout.inputModeFor("Keyboard")).toBe("Keyboard")
		expect(Layout.inputModeFor("Focus")).toBeNil()
		expect(Layout.inputModeFor("Accelerometer")).toBeNil()
	end)

	T.it("drawers are sheets on touch or portrait, side panels otherwise", function()
		expect(Layout.drawerStyle("Touch", 1920, 1080)).toBe("Sheet")
		expect(Layout.drawerStyle("Keyboard", 1920, 1080)).toBe("Side")
		expect(Layout.drawerStyle("Gamepad", 1920, 1080)).toBe("Side")
		expect(Layout.drawerStyle("Keyboard", 600, 900)).toBe("Sheet")
	end)

	T.it("grid columns follow width", function()
		expect(Layout.gridColumns(100, 150, 12)).toBe(1)
		expect(Layout.gridColumns(312, 150, 12)).toBe(2)
		expect(Layout.gridColumns(311, 150, 12)).toBe(1)
		expect(Layout.gridColumns(800, 150, 12)).toBe(5)
		expect(Layout.gridColumns(800, 0, 12)).toBe(1)
	end)
end)
