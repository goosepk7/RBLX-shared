--!strict
local Color = require("@shared/UI/Color")
local T = require("@shared/Test")
local expect = T.expect

T.describe("UI.Color", function()
	T.it("parses #RRGGBB with or without the hash", function()
		expect(Color.parse("#1E2235")).toEqual({ r = 30, g = 34, b = 53 })
		expect(Color.parse("ff7a1a")).toEqual({ r = 255, g = 122, b = 26 })
	end)

	T.it("rejects malformed hex instead of rendering black", function()
		expect(function()
			Color.parse("#12345")
		end).toThrow("invalid hex")
		expect(function()
			Color.parse("orange")
		end).toThrow("invalid hex")
	end)

	T.it("round-trips through toHex", function()
		expect(Color.toHex(Color.parse("#2EC4B6"))).toBe("#2EC4B6")
	end)

	T.it("mixes and shades toward Ink, not black", function()
		local white = Color.parse("#FFFFFF")
		expect(Color.mix(white, Color.parse("#000000"), 0.5)).toEqual({ r = 128, g = 128, b = 128 })
		expect(Color.shade(white, 1)).toEqual({ r = 30, g = 34, b = 53 })
	end)

	T.it("computes WCAG contrast", function()
		expect(Color.contrast(Color.parse("#FFFFFF"), Color.parse("#000000"))).toBeNear(21, 0.01)
		expect(Color.contrast(Color.parse("#777777"), Color.parse("#777777"))).toBeNear(1, 0.001)
	end)
end)
