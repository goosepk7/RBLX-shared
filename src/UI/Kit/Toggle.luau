--!strict
--[[
	Toggle: an on/off switch for Settings rows ("Camera shake", "Flashes").

	A pill track with a 4 px edge and a Paper knob that slides across. Off is the Line-dark
	track; on is the accent (Primary) or Success fill. The hit box is the full 52 x 48 control,
	so it stays a valid tap target, and the whole switch is one console-selectable button.
	Changes are instant (no confirm): the knob springs over in 0.18 s with a click.
]]

local Common = require("./Common")
local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Success"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Value: boolean,
	Variant: Variant?,
	OnChanged: ((value: boolean) -> ())?,
}

export type Handle = {
	getValue: () -> boolean,
	setValue: (value: boolean, silent: boolean?) -> (),
	setDisabled: (boolean) -> (),
	button: TextButton,
	destroy: () -> (),
}

local Toggle = {}

Toggle.Variants = { "Primary", "Success" } :: { Variant }

local TRACK_W, TRACK_H = 60, 34
local KNOB = 26
local EDGE = Tokens.edge.chip

function Toggle.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Primary"
	local onFill: Theme.ColorName = if variant == "Success" then "success" else "primary"
	local onEdge: Theme.ColorName = if variant == "Success" then "successEdge" else "primaryEdge"
	local value = props.Value == true
	local disabled = props.Disabled == true
	local hitH = Tokens.size.buttonHeightSmall

	local root = Create.group({
		Size = UDim2.fromOffset(TRACK_W, hitH),
	})
	Common.applyBase(root, props, "Toggle")

	local button = Create.new("TextButton", {
		Name = "Hit",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		Selectable = true,
		ZIndex = 4,
		Parent = root,
	}) :: TextButton
	button.SelectionImageObject = Common.selectionRing(999)

	local top = math.floor((hitH - TRACK_H - EDGE) / 2)
	local edge = Create.new("Frame", {
		Name = "Edge",
		BackgroundColor3 = Theme.color("lineDark"),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(TRACK_W, TRACK_H),
		Position = UDim2.fromOffset(0, top + EDGE),
		Parent = root,
	}, { Create.pill() })
	local track = Create.new("Frame", {
		Name = "Track",
		BackgroundColor3 = Theme.color("line"),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(TRACK_W, TRACK_H),
		Position = UDim2.fromOffset(0, top),
		ZIndex = 2,
		Parent = root,
	}, { Create.pill() })
	local inset = (TRACK_H - KNOB) / 2
	local knob = Create.new("Frame", {
		Name = "Knob",
		BackgroundColor3 = Theme.color("paper"),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(KNOB, KNOB),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, inset, 0.5, 0),
		ZIndex = 3,
		Parent = track,
	}, { Create.pill(), Create.stroke("lineDark", Tokens.border.card) })

	local function paint(animate: boolean)
		local x = if value then TRACK_W - KNOB - inset else inset
		local goals = { Position = UDim2.new(0, x, 0.5, 0) }
		if animate then
			Motion.tween(knob, Tokens.motion.releaseDuration, "Spring", goals)
		else
			knob.Position = goals.Position
		end
		track.BackgroundColor3 = Theme.color(if value then onFill else "line")
		edge.BackgroundColor3 = Theme.color(if value then onEdge else "lineDark")
	end

	local function setValue(v: boolean, silent: boolean?)
		if v == value then
			return
		end
		value = v
		paint(button:IsDescendantOf(game))
		if not silent and props.OnChanged then
			props.OnChanged(value)
		end
	end

	local conns: { RBXScriptConnection } = {}
	table.insert(
		conns,
		button.Activated:Connect(function()
			if disabled then
				return
			end
			Hooks.sound("click")
			Hooks.haptic("light")
			setValue(not value)
		end)
	)

	local function setDisabled(v: boolean)
		disabled = v
		button.Active = not v
		Common.setDimmed(root, v)
	end

	paint(false)
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
			button = button,
			destroy = function()
				for _, c in conns do
					c:Disconnect()
				end
				root:Destroy()
			end,
		}
end

return Toggle
