--!strict
--[[
	Camera shake as pure math (trauma model). `add` raises trauma (0..1); it decays linearly;
	the offset scales with trauma squared, so small bumps stay subtle and big hits read big.
	Motion comes from summed sines with fixed per-axis phases: smooth, deterministic, testable.

	The output never exceeds the configured maxima times the player's scale, and the maxima
	themselves are capped at HARD_MAX_ANGLE / HARD_MAX_OFFSET, so no game config can make
	shake nauseating (§5.7: "camera shake capped and user-disableable").
]]

export type Options = {
	maxAngle: number?, -- degrees at full trauma, default 2.5
	maxOffset: number?, -- studs at full trauma, default 0.35
	decay: number?, -- trauma lost per second, default 1.6
	frequency: number?, -- Hz of the main wobble, default 18
}

export type Sample = { pitch: number, yaw: number, roll: number, x: number, y: number }

export type Shake = {
	trauma: number,
	scale: number,
	add: (self: Shake, amount: number) -> (),
	setScale: (self: Shake, scale: number) -> (),
	step: (self: Shake, dt: number) -> Sample,
	isActive: (self: Shake) -> boolean,
	reset: (self: Shake) -> (),
}

local Shake = {}

Shake.HARD_MAX_ANGLE = 4
Shake.HARD_MAX_OFFSET = 0.6

local PHASES = { 0.0, 1.7, 3.1, 4.6, 5.9 }

local function wobble(t: number, f: number, phase: number): number
	-- Two incommensurate sines read as noise without any randomness.
	return 0.65 * math.sin(t * f * 2 * math.pi + phase) + 0.35 * math.sin(t * f * 2 * math.pi * 2.31 + phase * 1.9)
end

local ZERO: Sample = table.freeze({ pitch = 0, yaw = 0, roll = 0, x = 0, y = 0 })

function Shake.new(options: Options?): Shake
	local opts: Options = options or {}
	local maxAngle = math.min(opts.maxAngle or 2.5, Shake.HARD_MAX_ANGLE)
	local maxOffset = math.min(opts.maxOffset or 0.35, Shake.HARD_MAX_OFFSET)
	local decay = opts.decay or 1.6
	local frequency = opts.frequency or 18
	local t = 0

	local shake = { trauma = 0, scale = 1 } :: Shake

	function shake.add(self: Shake, amount: number)
		if amount ~= amount or amount <= 0 then
			return
		end
		self.trauma = math.min(1, self.trauma + amount)
	end

	function shake.setScale(self: Shake, scale: number)
		self.scale = if scale ~= scale then 0 else math.clamp(scale, 0, 1)
	end

	function shake.isActive(self: Shake): boolean
		return self.trauma > 0
	end

	function shake.reset(self: Shake)
		self.trauma = 0
	end

	function shake.step(self: Shake, dt: number): Sample
		if self.trauma <= 0 then
			return ZERO
		end
		t += dt
		local intensity = self.trauma * self.trauma * self.scale
		self.trauma = math.max(0, self.trauma - decay * dt)
		if intensity <= 0 then
			return ZERO
		end
		local angle = maxAngle * intensity
		local offset = maxOffset * intensity
		return {
			pitch = angle * wobble(t, frequency, PHASES[1]),
			yaw = angle * wobble(t, frequency * 0.9, PHASES[2]),
			roll = angle * 0.5 * wobble(t, frequency * 0.7, PHASES[3]),
			x = offset * wobble(t, frequency * 1.1, PHASES[4]),
			y = offset * wobble(t, frequency * 1.05, PHASES[5]),
		}
	end

	return shake
end

return Shake
