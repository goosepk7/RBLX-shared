--!strict
--[[
	Slider: a horizontal value control for Settings (music and sound volume, sensitivity).

	A 12 px two-tone track (accent fill on Paper-2) with a 32 px Paper knob that has the kit's
	4 px edge. The hit box is 48 px tall across the whole width, so a thumb can grab anywhere
	on the track. Touch and mouse drag; console and keyboard step with D-pad / arrow keys while
	selected. `OnChanged` fires as the value moves (for instant feedback, e.g. live volume),
	`OnCommitted` once on release (save it then).

	`Slider.valueAt` and `Slider.snap` are the pure math, tested under lune.
]]

local Common = require("./Common")
local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Secondary"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Value: number,
	Min: number?, -- default 0
	Max: number?, -- default 1
	Step: number?, -- default (Max - Min) / 20
	Variant: Variant?,
	Width: number?, -- px; default fills the parent
	OnChanged: ((value: number) -> ())?,
	OnCommitted: ((value: number) -> ())?,
}

export type Handle = {
	getValue: () -> number,
	setValue: (value: number, silent: boolean?) -> (),
	setDisabled: (boolean) -> (),
	destroy: () -> (),
}

local Slider = {}

Slider.Variants = { "Primary", "Secondary" } :: { Variant }

local TRACK_H = 12
local KNOB = 32

--- Rounds `value` to the nearest step from `min` and clamps it to [min, max].
function Slider.snap(value: number, min: number, max: number, step: number): number
	if value ~= value then
		return min
	end
	local v = math.clamp(value, min, max)
	if step > 0 then
		v = min + math.floor((v - min) / step + 0.5) * step
		-- Kill float noise (0.30000000000000004) so saved settings stay clean.
		v = math.floor(v * 1e6 + 0.5) / 1e6
	end
	return math.clamp(v, min, max)
end

--- The value under screen x for a track starting at `left` that is `width` px wide.
function Slider.valueAt(x: number, left: number, width: number, min: number, max: number, step: number): number
	if width <= 0 then
		return min
	end
	local t = math.clamp((x - left) / width, 0, 1)
	return Slider.snap(min + t * (max - min), min, max, step)
end

function Slider.new(props: Props): (Frame, Handle)
	local min = props.Min or 0
	local max = props.Max or 1
	assert(max > min, "Slider: Max must be greater than Min")
	local step = props.Step or (max - min) / 20
	local variant: Variant = props.Variant or "Primary"
	local fillName: Theme.ColorName = if variant == "Secondary" then "secondary" else "primary"
	local edgeName: Theme.ColorName = if variant == "Secondary" then "secondaryEdge" else "primaryEdge"
	local value = Slider.snap(props.Value, min, max, step)
	local disabled = props.Disabled == true
	local hitH = Tokens.size.buttonHeightSmall

	local root = Create.group({
		Size = if props.Width then UDim2.fromOffset(props.Width, hitH) else UDim2.new(1, 0, 0, hitH),
	})
	Common.applyBase(root, props, "Slider")

	local hit = Create.new("TextButton", {
		Name = "Hit",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		Selectable = true,
		ZIndex = 5,
		Parent = root,
	}) :: TextButton
	hit.SelectionImageObject = Common.selectionRing(999)

	-- The knob's center travels from KNOB/2 to width - KNOB/2, so it never leaves the control.
	local rail = Create.group({
		Name = "Rail",
		Size = UDim2.new(1, -KNOB, 1, 0),
		Position = UDim2.fromOffset(KNOB / 2, 0),
		Parent = root,
	})
	local track = Create.new("Frame", {
		Name = "Track",
		BackgroundColor3 = Theme.color("paper2"),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.new(1, 0, 0, TRACK_H),
		Position = UDim2.fromScale(0, 0.5),
		ZIndex = 2,
		Parent = rail,
	}, { Create.pill(), Create.stroke("line", Tokens.border.card) })
	local fill = Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.color(fillName),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 3,
		Parent = track,
	}, { Create.pill() })
	local knob = Create.new("Frame", {
		Name = "Knob",
		BackgroundColor3 = Theme.color(edgeName),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(KNOB, KNOB),
		Position = UDim2.fromScale(0, 0.5),
		ZIndex = 4,
		Parent = rail,
	}, { Create.pill() })
	local face = Create.new("Frame", {
		Name = "Face",
		BackgroundColor3 = Theme.color("paper"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -Tokens.edge.chip),
		ZIndex = 4,
		Parent = knob,
	}, { Create.pill(), Create.stroke("line", Tokens.border.card) })
	local knobScale = Create.new("UIScale", { Scale = 1, Parent = face }) :: UIScale

	local function paint()
		local t = (value - min) / (max - min)
		fill.Size = UDim2.fromScale(t, 1)
		knob.Position = UDim2.fromScale(t, 0.5)
	end

	local lastSoundAt = 0
	local function setValue(v: number, silent: boolean?)
		local snapped = Slider.snap(v, min, max, step)
		if snapped == value then
			return
		end
		value = snapped
		paint()
		if not silent then
			local t = os.clock()
			if t - lastSoundAt > 0.06 then
				lastSoundAt = t
				Hooks.sound("hover")
			end
			if props.OnChanged then
				props.OnChanged(value)
			end
		end
	end

	local function commit()
		Hooks.sound("tab")
		if props.OnCommitted then
			props.OnCommitted(value)
		end
	end

	local dragging: InputObject? = nil
	local conns: { RBXScriptConnection } = {}
	local UserInputService = game:GetService("UserInputService")

	local function moveTo(x: number)
		setValue(Slider.valueAt(x, rail.AbsolutePosition.X, rail.AbsoluteSize.X, min, max, step))
	end

	local function release()
		if dragging then
			dragging = nil
			Motion.tween(knobScale, Tokens.motion.releaseDuration, "Spring", { Scale = 1 })
			commit()
		end
	end

	table.insert(
		conns,
		hit.InputBegan:Connect(function(input: InputObject)
			if disabled then
				return
			end
			local t = input.UserInputType
			if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
				dragging = input
				Motion.tween(knobScale, Tokens.motion.pressDuration, "Enter", { Scale = 1.12 })
				moveTo(input.Position.X)
			elseif input.KeyCode == Enum.KeyCode.DPadRight or input.KeyCode == Enum.KeyCode.Right then
				setValue(value + step)
				commit()
			elseif input.KeyCode == Enum.KeyCode.DPadLeft or input.KeyCode == Enum.KeyCode.Left then
				setValue(value - step)
				commit()
			end
		end)
	)
	table.insert(
		conns,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			local d = dragging
			if d == nil then
				return
			end
			if
				input == d
				or (
					d.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseMovement
				)
			then
				moveTo(input.Position.X)
			end
		end)
	)
	table.insert(
		conns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			local d = dragging
			-- Touch: only the finger that grabbed the knob lets go of it, not a second finger.
			if
				d
				and (
					input == d
					or (d.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType == d.UserInputType)
				)
			then
				release()
			end
		end)
	)

	local function setDisabled(v: boolean)
		disabled = v
		hit.Active = not v
		if v then
			release()
		end
		Common.setDimmed(root, v)
	end

	paint()
	setDisabled(disabled)
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			getValue = function()
				return value
			end,
			setValue = setValue,
			setDisabled = setDisabled,
			destroy = function()
				for _, c in conns do
					c:Disconnect()
				end
				root:Destroy()
			end,
		}
end

return Slider
