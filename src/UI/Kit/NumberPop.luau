--!strict
--[[
	NumberPop (§5.3): "+N" floats up from a source element with a slight
	random x offset, scale punch, 0.7 s fade. Big gains (>= 10% of the value
	before the gain) add a confetti burst and the "thump" sound.

		Kit.NumberPop.spawn(pillRoot, 25, { Before = 140 })
]]

local Confetti = require("./Confetti")
local Create = require("../Create")
local Format = require("../Format")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Gain" | "Loss" | "Gold"

export type Options = {
	Before: number?, -- value before the change; enables the big-gain check
	Variant: Variant?,
	Text: string?, -- overrides "+N"
}

local NumberPop = {}

NumberPop.Variants = { "Gain", "Loss", "Gold" } :: { Variant }

local COLORS: { [Variant]: { Theme.ColorName } } = {
	Gain = { "success", "ink" },
	Loss = { "danger", "ink" },
	Gold = { "gold", "goldEdge" },
}

--- True if this change should get the big-gain treatment.
function NumberPop.isBig(before: number?, amount: number): boolean
	if before == nil then
		return false
	end
	return Format.isBigGain(before, amount, Tokens.motion.bigValueRatio)
end

function NumberPop.spawn(source: GuiObject, amount: number, opts: Options?): TextLabel?
	local o: Options = opts or {}
	local gui = source:FindFirstAncestorWhichIsA("LayerCollector")
	if gui == nil then
		return nil
	end
	local variant: Variant = o.Variant or (if amount < 0 then "Loss" else "Gain")
	local colors = COLORS[variant]
	local m = Tokens.motion
	local rng = Random.new()

	local center = source.AbsolutePosition + source.AbsoluteSize / 2
	local origin = gui.AbsolutePosition
	local x = center.X - origin.X + rng:NextNumber(-m.numberPopJitter, m.numberPopJitter)
	local y = source.AbsolutePosition.Y - origin.Y

	local label = Create.text({
		Name = "NumberPop",
		Text = o.Text or Format.delta(amount),
		Role = "number",
		SizeName = "h2",
		Color = colors[1],
		Stroke = colors[2],
		StrokeThickness = 2.5,
		XAlign = "Center",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(160, 36),
		ZIndex = 90,
		Parent = gui,
	})
	local scale = Create.new("UIScale", { Scale = 0.4, Parent = label })

	-- Punch in, rise, then fade over the pop duration.
	Motion.tween(scale, m.fastDuration, "EnterBack", { Scale = 1.25 })
	task.delay(m.fastDuration, function()
		Motion.tween(scale, m.fastDuration, "Enter", { Scale = 1 })
	end)
	Motion.tween(label, m.numberPopDuration, "Enter", { Position = UDim2.fromOffset(x, y - m.numberPopRise) })
	task.delay(m.numberPopDuration * 0.45, function()
		local stroke = label:FindFirstChildOfClass("UIStroke")
		if stroke then
			Motion.tween(stroke, m.numberPopDuration * 0.55, "Linear", { Transparency = 1 })
		end
		Motion.tween(label, m.numberPopDuration * 0.55, "Linear", { TextTransparency = 1 })
	end)
	task.delay(m.numberPopDuration + 0.05, function()
		label:Destroy()
	end)

	if amount > 0 and NumberPop.isBig(o.Before, amount) then
		Hooks.sound("thump")
		Confetti.burst(gui, center, "Burst")
	else
		Hooks.sound("pop")
	end
	return label
end

return NumberPop
