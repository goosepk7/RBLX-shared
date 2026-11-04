--!strict
local Economy = require("@shared/Economy")
local T = require("@shared/Test")
local Types = require("@shared/Types")

local expect = T.expect
local Multipliers = Economy.Multipliers

type Spec = Types.MultiplierSpec

local NOW = 1_700_000_000

type CombineOptions = { reason: string?, multiplyWithin: { [string]: boolean }?, max: number? }

local function combine(sources: { { Spec } }, options: CombineOptions?)
	local opts: CombineOptions = options or {}
	return Multipliers.combine(
		sources,
		"Wins",
		opts.reason or "challenge",
		NOW,
		opts.multiplyWithin or {},
		opts.max or 100
	)
end

T.describe("Economy.Multipliers.combine", function()
	T.it("adds bonuses within a group and multiplies the groups", function()
		local total, groups = combine({
			{
				{ group = "rebirth", factor = 1.5 },
				{ group = "rebirth", factor = 1.25 },
				{ group = "pass", factor = 2 },
			},
			{ { group = "pass", factor = 1.25 } },
		})
		expect(groups).toEqual({ rebirth = 1.75, pass = 2.25 })
		expect(total).toBeNear(1.75 * 2.25, 1e-12)
	end)

	T.it("multiplies within groups listed in multiplyWithin", function()
		local total, groups = combine({
			{ { group = "boost", factor = 2 }, { group = "boost", factor = 2 }, { group = "pass", factor = 2 } },
		}, { multiplyWithin = { boost = true } })
		expect(groups.boost).toBe(4)
		expect(total).toBe(8)
	end)

	T.it("applies a source only to its currencies and reasons", function()
		local sources: { { Spec } } = {
			{
				{ group = "pass", factor = 2, currencies = { "Wins" } },
				{ group = "lucky", factor = 2, reasons = { "event" } },
				{ group = "gems", factor = 3, currencies = { "Gems" } },
			},
		}
		expect((combine(sources))).toBe(2)
		expect((combine(sources, { reason = "event" }))).toBe(4)
		local gems = Multipliers.combine(sources, "Gems", "challenge", NOW, {}, 100)
		expect(gems).toBe(3)
	end)

	T.it("stops applying a source at its expiry", function()
		local spec: Spec = { group = "event", factor = 2, expiresAt = NOW + 60 }
		expect(Multipliers.applies(spec, "Wins", "challenge", NOW + 59)).toBe(true)
		expect(Multipliers.applies(spec, "Wins", "challenge", NOW + 60)).toBe(false)
	end)

	T.it("lets penalties lower a group but never below zero, and caps the total", function()
		local _, groups = combine({ { { group = "afk", factor = 0.5 } } })
		expect(groups.afk).toBe(0.5)
		local zero, floored = combine({ { { group = "afk", factor = 0.25 }, { group = "afk", factor = 0.25 } } })
		expect(floored.afk).toBe(0)
		expect(zero).toBe(0)
		local capped = combine({ { { group = "a", factor = 50 }, { group = "b", factor = 50 } } }, { max = 100 })
		expect(capped).toBe(100)
	end)

	T.it("is 1 with no sources", function()
		local total, groups = combine({ {} })
		expect(total).toBe(1)
		expect(groups).toEqual({})
	end)
end)

T.describe("Economy.Multipliers.validate", function()
	T.it("explains what is wrong with a spec", function()
		local function problem(spec: any): string?
			local ok, why = Multipliers.validate(spec)
			expect(ok).toBe(why == nil)
			return why
		end
		expect(problem({ group = "pass", factor = 2 })).toBeNil()
		expect(problem({ group = "pass", factor = 2, currencies = { "Wins" }, reasons = { "event" }, expiresAt = NOW })).toBeNil()
		expect(problem(5)).toContain("must be a table")
		expect(problem({ factor = 2 })).toContain("needs a group")
		expect(problem({ group = "pass", factor = 0 })).toContain("greater than 0")
		expect(problem({ group = "pass", factor = 0 / 0 })).toContain("greater than 0")
		expect(problem({ group = "pass", factor = math.huge })).toContain("greater than 0")
		expect(problem({ group = "pass", factor = 2, currencies = "Wins" })).toContain("currencies must be a list")
		expect(problem({ group = "pass", factor = 2, reasons = { 1 } })).toContain("reasons must be a list")
		expect(problem({ group = "pass", factor = 2, expiresAt = "soon" })).toContain("unix time")
	end)
end)
