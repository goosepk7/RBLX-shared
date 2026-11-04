--!strict
local Presets = require("@shared/VFX/Presets")
local Shake = require("@shared/VFX/Shake")
local T = require("@shared/Test")

local expect = T.expect

local function peak(shake: Shake.Shake, seconds: number): (number, number)
	local maxAngle, maxOffset = 0, 0
	local t = 0
	while t < seconds do
		local s = shake:step(1 / 60)
		maxAngle = math.max(maxAngle, math.abs(s.pitch), math.abs(s.yaw), math.abs(s.roll))
		maxOffset = math.max(maxOffset, math.abs(s.x), math.abs(s.y))
		t += 1 / 60
	end
	return maxAngle, maxOffset
end

T.describe("VFX.Shake", function()
	T.it("decays to rest", function()
		local shake = Shake.new({ decay = 2 })
		shake:add(1)
		expect(shake:isActive()).toBe(true)
		peak(shake, 0.6)
		expect(shake:isActive()).toBe(false)
		expect(shake:step(1 / 60)).toEqual({ pitch = 0, yaw = 0, roll = 0, x = 0, y = 0 })
	end)

	T.it("never exceeds the configured maxima, and those are hard-capped", function()
		local shake = Shake.new({ maxAngle = 99, maxOffset = 99 })
		for _ = 1, 10 do
			shake:add(5)
		end
		expect(shake.trauma).toBe(1)
		local angle, offset = peak(shake, 1)
		expect(angle <= Shake.HARD_MAX_ANGLE + 1e-9).toBe(true)
		expect(offset <= Shake.HARD_MAX_OFFSET + 1e-9).toBe(true)
		expect(angle > 1).toBe(true)
	end)

	T.it("scales with trauma squared and with the player's setting", function()
		local strong, weak = Shake.new(), Shake.new()
		strong:add(1)
		weak:add(0.5)
		local a1 = peak(strong, 0.05)
		local a2 = peak(weak, 0.05)
		expect(a2 < a1 / 3).toBe(true)
		local off = Shake.new()
		off:setScale(0)
		off:add(1)
		expect((peak(off, 0.5))).toBe(0)
	end)

	T.it("ignores NaN and negative input", function()
		local shake = Shake.new()
		shake:add(0 / 0)
		shake:add(-1)
		expect(shake.trauma).toBe(0)
		shake:setScale(0 / 0)
		expect(shake.scale).toBe(0)
	end)
end)

T.describe("VFX.Presets", function()
	T.it("every built-in preset is valid and uses theme tokens", function()
		local problems: { string } = {}
		for name, preset in Presets.list do
			for _, p in Presets.validate(name, preset) do
				table.insert(problems, p)
			end
		end
		expect(problems).toEqual({})
	end)

	T.it("covers the §5.7 / §6.11 / §7.12 moments", function()
		for _, name in { "sparkle", "confetti", "dust", "splash", "embers", "burst", "snow", "stars" } do
			expect(Presets.list[name]).toBeTruthy()
		end
	end)

	T.it("flags bad presets", function()
		local bad: any = table.clone(Presets.list.dust)
		bad.colors = { "notAToken" }
		bad.lifetime = { min = 2, max = 1 }
		local problems = Presets.validate("bad", bad)
		expect(#problems).toBe(2)
	end)

	T.it("splits counts across colors without losing particles", function()
		expect(Presets.split(10, 3)).toEqual({ 4, 3, 3 })
		expect(Presets.split(2, 5)).toEqual({ 1, 1, 1, 1, 1 })
	end)
end)
