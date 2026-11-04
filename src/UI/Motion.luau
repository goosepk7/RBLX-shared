--!strict
--[[
	Tween helpers with the kit's motion vocabulary (§5.7): Back/Quad out for
	enters, Quad in for exits, 0.12-0.25 s. Services are resolved lazily so
	the module can be required headlessly.
]]

local Tokens = require("./Tokens")

local Motion = {}

local tweenService: TweenService? = nil

local function getTweenService(): TweenService
	if tweenService == nil then
		tweenService = game:GetService("TweenService")
	end
	return tweenService :: TweenService
end

export type Ease = "Enter" | "EnterBack" | "Exit" | "Linear" | "Spring"

local function info(duration: number, ease: Ease): TweenInfo
	if ease == "EnterBack" then
		return TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	elseif ease == "Exit" then
		return TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	elseif ease == "Linear" then
		return TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
	elseif ease == "Spring" then
		return TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end
	return TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

--- Plays and returns a tween. Goals are property -> target value.
function Motion.tween(inst: Instance, duration: number, ease: Ease, goals: { [string]: any }): Tween
	local tween = getTweenService():Create(inst, info(duration, ease), goals)
	tween:Play()
	return tween
end

function Motion.enter(inst: Instance, goals: { [string]: any }): Tween
	return Motion.tween(inst, Tokens.motion.enterDuration, "EnterBack", goals)
end

function Motion.exit(inst: Instance, goals: { [string]: any }): Tween
	return Motion.tween(inst, Tokens.motion.exitDuration, "Exit", goals)
end

--- Counts a TextLabel from `from` to `to` over `duration` using `format`.
--- Returns a cancel function.
function Motion.countUp(
	label: TextLabel,
	from: number,
	to: number,
	duration: number,
	format: (number) -> string
): () -> ()
	local cancelled = false
	local runService = game:GetService("RunService")
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = runService.RenderStepped:Connect(function()
		if cancelled then
			conn:Disconnect()
			return
		end
		local t = math.clamp((os.clock() - start) / duration, 0, 1)
		local eased = 1 - (1 - t) ^ 3
		label.Text = format(from + (to - from) * eased)
		if t >= 1 then
			label.Text = format(to)
			conn:Disconnect()
		end
	end)
	return function()
		cancelled = true
		conn:Disconnect()
	end
end

return Motion
