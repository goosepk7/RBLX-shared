--!strict
--[[
	Confetti burst in screen space: rounded token-colored bits that pop out,
	tumble, fall and fade. Used by NumberPop for big gains and by win/unlock
	moments (§5.7).

		Kit.Confetti.burst(screenGui, Vector2.new(x, y))
]]

local Create = require("../Create")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Burst" | "Shower"

local Confetti = {}

Confetti.Variants = { "Burst", "Shower" } :: { Variant }

local COLORS: { Theme.ColorName } = { "primary", "secondary", "success", "warning", "info", "gold", "danger" }

--- Spawns pieces at `origin` (absolute screen px) in the ScreenGui that
--- contains `host` (pieces live outside any UIScale so pixels stay true).
--- Shower rains from the top edge across the screen instead.
function Confetti.burst(host: GuiBase2d, origin: Vector2, variant: Variant?, count: number?)
	local gui: GuiBase2d = if host:IsA("LayerCollector")
		then host
		else host:FindFirstAncestorWhichIsA("LayerCollector") or host
	local n = count or Tokens.motion.confettiCount
	local duration = Tokens.motion.confettiDuration
	local rng = Random.new()
	local layer = Create.group({ Name = "Confetti", ZIndex = 80, Parent = gui })
	origin -= gui.AbsolutePosition
	local width = gui.AbsoluteSize.X
	local height = gui.AbsoluteSize.Y
	for i = 1, n do
		local w = rng:NextInteger(6, 12)
		local start = if variant == "Shower" then Vector2.new(rng:NextNumber(0, width), -16) else origin
		local piece = Create.new("Frame", {
			Name = "Bit" .. i,
			BackgroundColor3 = Theme.color(COLORS[rng:NextInteger(1, #COLORS)]),
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(start.X, start.Y),
			Size = UDim2.fromOffset(w, math.floor(w * 0.6)),
			Rotation = rng:NextInteger(0, 360),
			ZIndex = 80,
			Parent = layer,
		}, { Create.corner(2) })
		local target: Vector2
		if variant == "Shower" then
			target = Vector2.new(start.X + rng:NextNumber(-60, 60), height + 20)
		else
			local angle = rng:NextNumber(-math.pi * 0.95, -math.pi * 0.05)
			local dist = rng:NextNumber(60, 160)
			target = origin + Vector2.new(math.cos(angle) * dist, math.sin(angle) * dist + rng:NextNumber(60, 140))
		end
		local d = duration * rng:NextNumber(0.75, 1.15)
		Motion.tween(piece, d, "Enter", {
			Position = UDim2.fromOffset(target.X, target.Y),
			Rotation = piece.Rotation + rng:NextInteger(-540, 540),
		})
		task.delay(d * 0.6, function()
			Motion.tween(piece, d * 0.4, "Linear", { BackgroundTransparency = 1 })
		end)
	end
	task.delay(duration * 1.2, function()
		layer:Destroy()
	end)
end

return Confetti
