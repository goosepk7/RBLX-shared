--!strict
--[[
	Feedback hooks: the kit announces UI events ("click", "success", "thump",
	...) and whoever owns audio/haptics answers them. Shared Audio (v0.2)
	registers itself with setSoundHandler; until then UI events are silent by
	design (not by accident: `hasSoundHandler()` lets the gallery show it).

	Haptics have a built-in default on gamepad and supported touch devices,
	and respect the player's setting through setHapticsEnabled.
]]

export type SoundName = "click" | "hover" | "open" | "close" | "success" | "fail" | "thump" | "pop" | "tab" | "toast"
export type HapticKind = "light" | "medium" | "heavy"

local Hooks = {}

local soundHandler: ((SoundName) -> ())? = nil
local hapticsEnabled = true

function Hooks.setSoundHandler(fn: ((SoundName) -> ())?)
	soundHandler = fn
end

function Hooks.hasSoundHandler(): boolean
	return soundHandler ~= nil
end

function Hooks.sound(name: SoundName)
	local fn = soundHandler
	if fn then
		fn(name)
	end
end

function Hooks.setHapticsEnabled(enabled: boolean)
	hapticsEnabled = enabled
end

local STRENGTH: { [HapticKind]: { amplitude: number, seconds: number } } = {
	light = { amplitude = 0.25, seconds = 0.05 },
	medium = { amplitude = 0.5, seconds = 0.08 },
	heavy = { amplitude = 1, seconds = 0.14 },
}

local function pulse(service: HapticService, inputType: Enum.UserInputType, kind: HapticKind)
	if not service:IsVibrationSupported(inputType) then
		return
	end
	local motor = Enum.VibrationMotor.Small
	if not service:IsMotorSupported(inputType, motor) then
		motor = Enum.VibrationMotor.Large
		if not service:IsMotorSupported(inputType, motor) then
			return
		end
	end
	local s = STRENGTH[kind]
	service:SetMotor(inputType, motor, s.amplitude)
	task.delay(s.seconds, function()
		service:SetMotor(inputType, motor, 0)
	end)
end

--- Fires a short vibration on the active gamepad and on touch devices that
--- support it. Win/fail/purchase call this (§5.7).
function Hooks.haptic(kind: HapticKind)
	if not hapticsEnabled then
		return
	end
	local service = game:GetService("HapticService")
	pulse(service, Enum.UserInputType.Gamepad1, kind)
	pulse(service, Enum.UserInputType.Touch, kind)
end

return Hooks
