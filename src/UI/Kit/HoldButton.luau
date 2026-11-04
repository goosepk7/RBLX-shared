--!strict
--[[
	HoldButton (§5.3, §5.4): the big round action button for the bottom-right thumb arc. It
	fills while held, so a hold-to-confirm action ("Hold to hop off") or a charged action
	("hold, release to lunge") shows its progress under the thumb.

	Modes:
	  "Hold"   `OnHeld` fires once the fill completes (`HoldTime` seconds). Letting go early
	           fires `OnCancelled`. `HoldTime = 0` behaves like a tap.
	  "Charge" The fill grows to full over `HoldTime` and stays there. Letting go fires
	           `OnReleased(charge)` with charge in 0..1.

	88 px circle (68 px for `Size = "Medium"`) with the kit's 6 px edge, a 40 px icon and a
	caption label under it. The fill is a disc blooming from the center (no CanvasGroup, so
	it costs nothing on mobile). Touch tracks the finger that pressed, so a second finger on
	the thumbstick never releases it. Keyboard and gamepad bindings drive the same visual
	through `handle.press()` and `handle.release()`.

	`HoldButton.progress` and `HoldButton.outcome` are the pure rules, tested under lune.
]]

local Common = require("./Common")
local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Secondary" | "Success" | "Danger" | "Gold"
export type Mode = "Hold" | "Charge"
export type Size = "Large" | "Medium"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Icon: string, -- asset name
	Label: string, -- caption under the button; already localized
	Variant: Variant?,
	Mode: Mode?, -- default "Hold"
	Size: Size?, -- default "Large"
	HoldTime: number?, -- seconds to fill; default 1
	OnBegan: (() -> ())?,
	OnHeld: (() -> ())?, -- Hold mode: the fill completed
	OnCancelled: (() -> ())?, -- Hold mode: released early (or disabled while held)
	OnReleased: ((charge: number) -> ())?, -- Charge mode
}

export type Handle = {
	press: () -> (),
	release: () -> (),
	cancel: () -> (),
	isHeld: () -> boolean,
	setDisabled: (boolean) -> (),
	setLoading: (boolean) -> (),
	setLabel: (string) -> (),
	setIcon: (string) -> (),
	-- Shows a value on the fill while not held (a cooldown or a ready state), 0..1.
	setProgress: (number) -> (),
	destroy: () -> (),
}

export type Outcome = "held" | "cancelled" | "pending"

local HoldButton = {}

HoldButton.Variants = { "Primary", "Secondary", "Success", "Danger", "Gold" } :: { Variant }
HoldButton.Modes = { "Hold", "Charge" } :: { Mode }

HoldButton.SIZES = table.freeze({ Large = 88, Medium = 68 }) :: { [Size]: number }
HoldButton.LABEL_HEIGHT = 22

--- Fill fraction after `elapsed` seconds of a `holdTime` hold (a zero hold is full at once).
function HoldButton.progress(elapsed: number, holdTime: number): number
	if holdTime <= 0 then
		return 1
	end
	if elapsed ~= elapsed then
		return 0
	end
	return math.clamp(elapsed / holdTime, 0, 1)
end

--- What a Hold-mode press amounts to: "held" once it has filled, "cancelled" when released
--- before that, "pending" while still held and filling.
function HoldButton.outcome(elapsed: number, holdTime: number, released: boolean): Outcome
	if HoldButton.progress(elapsed, holdTime) >= 1 then
		return "held"
	end
	return if released then "cancelled" else "pending"
end

--[[
	What letting go of a Hold-mode press does. `fired` is whether OnHeld already ran (from the
	frame loop). A release that lands after the fill completed but before the next frame still
	counts as held, so a zero hold time pressed and released in one frame is a tap, not a
	cancel. A cancel or a disable (`released = false`) never fires held.
]]
function HoldButton.releaseAction(
	elapsed: number,
	holdTime: number,
	fired: boolean,
	released: boolean
): "held" | "cancelled" | "none"
	if fired then
		return "none"
	end
	if released and HoldButton.outcome(elapsed, holdTime, true) == "held" then
		return "held"
	end
	return "cancelled"
end

function HoldButton.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Primary"
	local mode: Mode = props.Mode or "Hold"
	local holdTime = math.max(props.HoldTime or 1, 0)
	local colors = Theme.variant(variant)
	local sizeName: Size = props.Size or "Large"
	local size = HoldButton.SIZES[sizeName]
	local edgeSize = Tokens.edge.button
	local disabled = props.Disabled == true
	local loading = props.Loading == true

	local root = Create.group({
		Size = UDim2.fromOffset(size, size + edgeSize + HoldButton.LABEL_HEIGHT),
	})
	Common.applyBase(root, props, "HoldButton")

	local ef = Common.edgeFace({
		height = size,
		edge = edgeSize,
		radius = nil,
		fill = colors.fill,
		edgeColor = colors.edge,
		border = colors.border,
		interactive = true,
	})
	ef.root.Name = "Button"
	ef.root.Size = UDim2.fromOffset(size, size + edgeSize)
	ef.root.Parent = root

	-- The fill: a white disc that blooms from the center as the hold progresses.
	local bloom = Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.color("white"),
		BackgroundTransparency = 0.62,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0, 0),
		ZIndex = 3,
		Parent = ef.face,
	}, { Create.pill() })
	local ring = Create.new("Frame", {
		Name = "Ring",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Visible = false,
		Parent = ef.face,
	}, { Create.pill(), Create.stroke("white", 3) })

	local icon = Common.icon(props.Icon, {
		Name = "Icon",
		Size = UDim2.fromOffset(math.floor(size * 0.46), math.floor(size * 0.46)),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ZIndex = 4,
		Parent = ef.face,
	})

	local label = Create.text({
		Name = "Label",
		Text = props.Label,
		Role = "button",
		SizeName = "caption",
		Color = "white",
		Stroke = "ink",
		StrokeThickness = 1.5,
		XAlign = "Center",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, size + edgeSize + 2),
		Size = UDim2.new(1, 40, 0, HoldButton.LABEL_HEIGHT - 2),
		ZIndex = 4,
		Parent = root,
	})

	local spinner = Common.spinner(colors.text, 7)
	spinner.ZIndex = 5
	spinner.Parent = ef.face

	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")

	local holding: InputObject | boolean = false -- the input that pressed, or true for press()
	local heldAt = 0
	local fired = false
	local restProgress = 0
	local stepConn: RBXScriptConnection? = nil
	local conns: { RBXScriptConnection } = {}
	local m = Tokens.motion

	local function showFill(t: number)
		bloom.Size = UDim2.fromScale(t, t)
		ring.Visible = t >= 1
	end

	local function stopStep()
		if stepConn then
			stepConn:Disconnect()
			stepConn = nil
		end
	end

	local function pressVisual(down: boolean)
		local y = if down then edgeSize - Tokens.edge.pressed else 0
		if down then
			Motion.tween(ef.face, m.pressDuration, "Enter", { Position = UDim2.fromOffset(0, y) })
			Motion.tween(ef.scale, m.pressDuration, "Enter", { Scale = m.pressScale })
		else
			Motion.tween(ef.face, m.releaseDuration, "Spring", { Position = UDim2.fromOffset(0, y) })
			Motion.tween(ef.scale, m.releaseDuration, "Spring", { Scale = 1 })
		end
	end

	local function enabled(): boolean
		return not disabled and not loading
	end

	local function fireHeld()
		fired = true
		Hooks.sound("pop")
		Hooks.haptic("light")
		Motion.tween(ef.scale, m.fastDuration, "Enter", { Scale = 1.06 })
		if props.OnHeld then
			props.OnHeld()
		end
	end

	local function finish(released: boolean)
		if holding == false then
			return
		end
		holding = false
		stopStep()
		pressVisual(false)
		local elapsed = os.clock() - heldAt
		if mode == "Charge" then
			showFill(restProgress)
			if released and props.OnReleased then
				props.OnReleased(HoldButton.progress(elapsed, holdTime))
			end
			return
		end
		showFill(restProgress)
		local action = HoldButton.releaseAction(elapsed, holdTime, fired, released)
		if action == "held" then
			fireHeld()
		elseif action == "cancelled" then
			Hooks.sound("close")
			if props.OnCancelled then
				props.OnCancelled()
			end
		end
	end

	local function begin(input: InputObject | boolean)
		if not enabled() or holding ~= false then
			return
		end
		holding = input
		heldAt = os.clock()
		fired = false
		pressVisual(true)
		Hooks.sound("click")
		if props.OnBegan then
			props.OnBegan()
		end
		showFill(HoldButton.progress(0, holdTime))
		stopStep()
		stepConn = RunService.Heartbeat:Connect(function()
			local elapsed = os.clock() - heldAt
			local t = HoldButton.progress(elapsed, holdTime)
			showFill(t)
			if mode == "Hold" and not fired and HoldButton.outcome(elapsed, holdTime, false) == "held" then
				fireHeld()
			end
		end)
	end

	local face = ef.face :: TextButton
	table.insert(
		conns,
		face.InputBegan:Connect(function(input: InputObject)
			local t = input.UserInputType
			if
				t == Enum.UserInputType.MouseButton1
				or t == Enum.UserInputType.Touch
				or input.KeyCode == Enum.KeyCode.ButtonA
			then
				begin(input)
			end
		end)
	)
	table.insert(
		conns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			local h = holding
			if typeof(h) ~= "Instance" then
				return
			end
			local pressedBy = h :: InputObject
			-- Touch: only the finger that pressed releases it, not the thumbstick finger.
			if
				input == pressedBy
				or (
					pressedBy.UserInputType ~= Enum.UserInputType.Touch
					and input.UserInputType == pressedBy.UserInputType
					and input.KeyCode == pressedBy.KeyCode
				)
			then
				finish(true)
			end
		end)
	)

	local function refresh()
		face.Active = enabled()
		face.Selectable = not disabled
		icon.Visible = not loading
		spinner.Visible = loading
		Common.setFlat(ef, edgeSize, disabled)
		Common.setDimmed(root, disabled)
	end

	local function setDisabled(v: boolean)
		if v == disabled then
			return
		end
		disabled = v
		if v then
			finish(false)
		end
		refresh()
	end

	showFill(0)
	refresh()
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			press = function()
				begin(true)
			end,
			release = function()
				finish(true)
			end,
			cancel = function()
				finish(false)
			end,
			isHeld = function()
				return holding ~= false
			end,
			setDisabled = setDisabled,
			setLoading = function(v: boolean)
				loading = v
				if v then
					finish(false)
				end
				refresh()
			end,
			setLabel = function(text: string)
				label.Text = text
			end,
			setIcon = function(name: string)
				Common.icon(name, {
					Name = "Icon",
					Size = icon.Size,
					AnchorPoint = icon.AnchorPoint,
					Position = icon.Position,
					ZIndex = icon.ZIndex,
					Visible = icon.Visible,
					Parent = ef.face,
				})
				icon:Destroy()
				icon = ef.face:FindFirstChild("Icon") :: ImageLabel
			end,
			setProgress = function(t: number)
				restProgress = math.clamp(if t ~= t then 0 else t, 0, 1)
				if holding == false then
					showFill(restProgress)
				end
			end,
			destroy = function()
				stopStep()
				for _, c in conns do
					c:Disconnect()
				end
				root:Destroy()
			end,
		}
end

return HoldButton
