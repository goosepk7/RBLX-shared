--!strict
--[[
	Particle presets as plain data. Colors are UI token names (Theme.color), so effects use the
	same palette as the UI and pick up the game's accent; textures are engine particle sprites
	(rbxasset://textures/particles/...), which ship with every client and need no upload.

	A preset may list several `colors`: VFX builds one emitter per color and splits the count,
	because a ParticleEmitter's color changes over a particle's life, not per particle.
	Games add their own with `VFX.definePreset(name, preset)` (e.g. "stilts.windStreak").
]]

local Theme = require("../UI/Theme")

export type Range = { min: number, max: number }

export type Preset = {
	texture: "sparkle" | "smoke" | "fire",
	colors: { string }, -- Theme.ColorName tokens (checked by validate)
	count: number, -- particles for one emit (split across colors)
	lifetime: Range,
	speed: Range,
	size: { start: number, finish: number },
	transparency: { start: number, finish: number },
	spread: number?, -- degrees, cone half-angle around the emit direction (default 30)
	acceleration: { x: number, y: number, z: number }?, -- studs/s^2 (gravity is -y)
	drag: number?,
	rotation: Range?,
	rotSpeed: Range?,
	lightEmission: number?,
	direction: ("Top" | "Bottom" | "Front" | "Back" | "Left" | "Right")?,
}

local Presets = {}

Presets.TEXTURES = table.freeze({
	sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
})

Presets.list = {
	-- Height-up / reward sparkle climbing a character (§6.11).
	sparkle = {
		texture = "sparkle",
		colors = { "gold", "white" },
		count = 24,
		lifetime = { min = 0.6, max = 1.1 },
		speed = { min = 4, max = 9 },
		size = { start = 0.6, finish = 0 },
		transparency = { start = 0, finish = 1 },
		spread = 25,
		acceleration = { x = 0, y = 6, z = 0 },
		lightEmission = 0.8,
	},
	-- Win moments in 3D (UI confetti is Kit.Confetti).
	confetti = {
		texture = "sparkle",
		colors = { "primary", "secondary", "gold", "info", "success" },
		count = 60,
		lifetime = { min = 1.2, max = 2.0 },
		speed = { min = 18, max = 30 },
		size = { start = 0.35, finish = 0.3 },
		transparency = { start = 0, finish = 0.2 },
		spread = 40,
		acceleration = { x = 0, y = -30, z = 0 },
		drag = 2,
		rotSpeed = { min = -360, max = 360 },
		lightEmission = 0.2,
	},
	-- Landing, hop dust, tyre kick-up.
	dust = {
		texture = "smoke",
		colors = { "lineDark" },
		count = 10,
		lifetime = { min = 0.4, max = 0.8 },
		speed = { min = 3, max = 7 },
		size = { start = 1.2, finish = 2.6 },
		transparency = { start = 0.35, finish = 1 },
		spread = 70,
		acceleration = { x = 0, y = 1, z = 0 },
		drag = 3,
	},
	-- Water hazards, wakes.
	splash = {
		texture = "sparkle",
		colors = { "info", "white" },
		count = 28,
		lifetime = { min = 0.5, max = 0.9 },
		speed = { min = 14, max = 24 },
		size = { start = 0.45, finish = 0.15 },
		transparency = { start = 0, finish = 0.6 },
		spread = 30,
		acceleration = { x = 0, y = -60, z = 0 },
		lightEmission = 0.3,
	},
	-- Lava, sizzle, sparks.
	embers = {
		texture = "fire",
		colors = { "warning", "danger" },
		count = 18,
		lifetime = { min = 0.6, max = 1.2 },
		speed = { min = 4, max = 10 },
		size = { start = 0.5, finish = 0 },
		transparency = { start = 0, finish = 1 },
		spread = 35,
		acceleration = { x = 0, y = 8, z = 0 },
		lightEmission = 1,
	},
	-- Something breaking apart (Car break burst, Stilts stumble chips).
	burst = {
		texture = "sparkle",
		colors = { "white", "lineDark" },
		count = 22,
		lifetime = { min = 0.35, max = 0.7 },
		speed = { min = 20, max = 34 },
		size = { start = 0.5, finish = 0.1 },
		transparency = { start = 0, finish = 1 },
		spread = 180,
		drag = 4,
		rotSpeed = { min = -540, max = 540 },
	},
	-- Freeze hazards, snow kick.
	snow = {
		texture = "sparkle",
		colors = { "white", "info" },
		count = 16,
		lifetime = { min = 0.6, max = 1.2 },
		speed = { min = 5, max = 10 },
		size = { start = 0.4, finish = 0.1 },
		transparency = { start = 0.1, finish = 1 },
		spread = 60,
		acceleration = { x = 0, y = -12, z = 0 },
		drag = 2,
		lightEmission = 0.5,
	},
	-- Star award / unlock beam base.
	stars = {
		texture = "sparkle",
		colors = { "gold" },
		count = 30,
		lifetime = { min = 0.8, max = 1.4 },
		speed = { min = 10, max = 18 },
		size = { start = 0.9, finish = 0 },
		transparency = { start = 0, finish = 1 },
		spread = 180,
		drag = 3,
		rotSpeed = { min = -180, max = 180 },
		lightEmission = 1,
	},
} :: { [string]: Preset }

--- Problems with a preset, as strings ("splash.lifetime: min > max"); empty when valid.
function Presets.validate(name: string, preset: Preset): { string }
	local problems: { string } = {}
	local function check(ok: boolean, message: string)
		if not ok then
			table.insert(problems, name .. "." .. message)
		end
	end
	check(Presets.TEXTURES[preset.texture] ~= nil, "texture: unknown " .. tostring(preset.texture))
	check(type(preset.colors) == "table" and #preset.colors > 0, "colors: at least one token")
	local colors: { string } = preset.colors or {}
	for _, color in colors do
		local ok = pcall(Theme.hex, color :: any)
		check(ok, "colors: unknown token " .. tostring(color))
	end
	check(type(preset.count) == "number" and preset.count >= 1 and preset.count <= 200, "count: 1-200")
	for _, field in { "lifetime", "speed", "rotation", "rotSpeed" } do
		local range = (preset :: any)[field]
		if range ~= nil then
			check(type(range.min) == "number" and type(range.max) == "number", field .. ": min and max")
			check(range.min <= range.max, field .. ": min > max")
		end
	end
	check(preset.lifetime ~= nil and preset.lifetime.min > 0, "lifetime: must be positive")
	check(preset.lifetime ~= nil and preset.lifetime.max <= 5, "lifetime: at most 5 s (effects, not ambience)")
	for _, field in { "size", "transparency" } do
		local pair = (preset :: any)[field]
		check(
			pair ~= nil and type(pair.start) == "number" and type(pair.finish) == "number",
			field .. ": start and finish"
		)
	end
	check(
		preset.transparency == nil or (preset.transparency.start >= 0 and preset.transparency.finish <= 1),
		"transparency: 0-1"
	)
	return problems
end

--- Particles per emitter for `count` split across `colors` (at least 1 each).
function Presets.split(count: number, colors: number): { number }
	local out: { number } = {}
	local each = math.floor(count / colors)
	local rest = count - each * colors
	for i = 1, colors do
		out[i] = math.max(1, each + (if i <= rest then 1 else 0))
	end
	return out
end

return Presets
