--!strict
local Slider = require("@shared/UI/Kit/Slider")
local T = require("@shared/Test")
local expect = T.expect

T.describe("UI.Kit.Slider math", function()
	T.it("snaps to the step and clamps", function()
		expect(Slider.snap(0.33, 0, 1, 0.05)).toBe(0.35)
		expect(Slider.snap(0.3, 0, 1, 0.1)).toBe(0.3) -- no float noise
		expect(Slider.snap(1.7, 0, 1, 0.1)).toBe(1)
		expect(Slider.snap(-3, 0, 10, 1)).toBe(0)
		expect(Slider.snap(0 / 0, 2, 10, 1)).toBe(2)
	end)

	T.it("maps a screen x across the track", function()
		expect(Slider.valueAt(100, 100, 200, 0, 1, 0.05)).toBe(0)
		expect(Slider.valueAt(200, 100, 200, 0, 1, 0.05)).toBe(0.5)
		expect(Slider.valueAt(999, 100, 200, 0, 10, 1)).toBe(10)
		expect(Slider.valueAt(150, 100, 0, 0, 1, 0.1)).toBe(0)
	end)
end)
