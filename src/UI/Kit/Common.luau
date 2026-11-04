--!strict
--[[
	Shared plumbing for kit components: base props, the 3D "edge + face"
	construction, disabled dimming, loading spinner, console selection ring,
	and press/hover behaviour.
]]

local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type BaseProps = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
}

local Common = {}

function Common.applyBase(root: GuiObject, props: BaseProps, defaultName: string)
	root.Name = props.Name or defaultName
	if props.LayoutOrder then
		root.LayoutOrder = props.LayoutOrder
	end
	if props.Position then
		root.Position = props.Position
	end
	if props.AnchorPoint then
		root.AnchorPoint = props.AnchorPoint
	end
end

-- Disabled dimming without CanvasGroup (one render target per button is too
-- expensive on mobile). Each element's authored transparency is remembered
-- in an attribute, then blended toward invisible by Tokens.alpha.disabled.
local DIM_PROPS: { [string]: { string } } = {
	Frame = { "BackgroundTransparency" },
	TextButton = { "BackgroundTransparency", "TextTransparency" },
	TextLabel = { "BackgroundTransparency", "TextTransparency" },
	TextBox = { "BackgroundTransparency", "TextTransparency" },
	ImageLabel = { "BackgroundTransparency", "ImageTransparency" },
	ImageButton = { "BackgroundTransparency", "ImageTransparency" },
	UIStroke = { "Transparency" },
}

local function dimOne(inst: Instance, dimmed: boolean)
	local keys = DIM_PROPS[inst.ClassName]
	if keys == nil then
		return
	end
	for _, key in keys do
		local attr = "UIBase" .. key
		local base = inst:GetAttribute(attr)
		if base == nil then
			base = (inst :: any)[key]
			inst:SetAttribute(attr, base)
		end
		local b = base :: number
		(inst :: any)[key] = if dimmed then b + (1 - b) * Tokens.alpha.disabled else b
	end
end

function Common.setDimmed(root: Instance, dimmed: boolean)
	dimOne(root, dimmed)
	for _, d in root:GetDescendants() do
		if d.Name ~= "Edge" or not dimmed then
			dimOne(d, dimmed)
		end
	end
end

--- Three bouncing dots, used for Loading on any control.
function Common.spinner(colorName: Theme.ColorName, dotSize: number): Frame
	local holder = Create.group({
		Name = "Spinner",
		Size = UDim2.fromOffset(dotSize * 3 + 8, dotSize * 2),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Visible = false,
		ZIndex = 5,
	})
	local dots: { Frame } = {}
	for i = 1, 3 do
		dots[i] = Create.new("Frame", {
			Name = "Dot" .. i,
			Size = UDim2.fromOffset(dotSize, dotSize),
			Position = UDim2.new(0, (i - 1) * (dotSize + 4), 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = Theme.color(colorName),
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = holder,
		}, { Create.pill() })
	end
	local alive = true
	holder.Destroying:Connect(function()
		alive = false
	end)
	holder:GetPropertyChangedSignal("Visible"):Connect(function()
		if not holder.Visible then
			return
		end
		task.spawn(function()
			local step = 0
			while alive and holder.Visible do
				for i, dot in dots do
					local up = (step % 3) + 1 == i
					Motion.tween(dot, Tokens.motion.fastDuration, "Enter", {
						Position = UDim2.new(0, (i - 1) * (dotSize + 4), 0.5, if up then -dotSize * 0.5 else 0),
					})
				end
				step += 1
				task.wait(Tokens.motion.fastDuration + 0.04)
			end
		end)
	end)
	return holder
end

--- Rounded accent ring shown when a console player selects a control.
function Common.selectionRing(radius: number): Frame
	return Create.new("Frame", {
		Name = "SelectionRing",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 8, 1, 8),
		Position = UDim2.fromOffset(-4, -4),
	}, {
		Create.new("UICorner", { CornerRadius = UDim.new(0, radius + 4) }),
		Create.new("UIStroke", {
			Color = Theme.color("info"),
			Thickness = 3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
	})
end

export type EdgeFaceOptions = {
	height: number, -- face height (edge is extra, below)
	edge: number,
	radius: number?, -- nil = pill
	fill: Theme.ColorName,
	edgeColor: Theme.ColorName,
	border: Theme.ColorName?,
	interactive: boolean,
	transparentFill: boolean?,
}

export type EdgeFace = {
	root: Frame,
	edge: Frame,
	face: GuiObject, -- TextButton when interactive, Frame otherwise
	scale: UIScale,
}

--- Builds the signature 3D construction: a darker Edge frame peeking out
--- below a Face. Root height = height + edge.
function Common.edgeFace(opts: EdgeFaceOptions): EdgeFace
	local function cornerFor(): UICorner
		return if opts.radius then Create.corner(opts.radius) else Create.pill()
	end
	local root = Create.group({
		Size = UDim2.new(1, 0, 0, opts.height + opts.edge),
	})
	local scale = Create.new("UIScale", { Scale = 1, Parent = root })
	local edge = Create.new("Frame", {
		Name = "Edge",
		BackgroundColor3 = Theme.color(opts.edgeColor),
		BackgroundTransparency = if opts.transparentFill or opts.edge == 0 then 1 else 0,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, opts.height),
		Position = UDim2.fromOffset(0, opts.edge),
		Parent = root,
	}, { cornerFor() })
	local face: GuiObject
	if opts.interactive then
		face = Create.new("TextButton", {
			AutoButtonColor = false,
			Text = "",
			Selectable = true,
		});
		(face :: TextButton).SelectionImageObject = Common.selectionRing(opts.radius or 999)
	else
		face = Create.new("Frame", {})
	end
	face.Name = "Face"
	face.BackgroundColor3 = Theme.color(opts.fill)
	face.BackgroundTransparency = if opts.transparentFill then 1 else 0
	face.BorderSizePixel = 0
	face.Size = UDim2.new(1, 0, 0, opts.height)
	face.Position = UDim2.fromOffset(0, 0)
	face.ZIndex = 2
	cornerFor().Parent = face
	if opts.border then
		Create.stroke(opts.border, Tokens.border.card).Parent = face
	end
	face.Parent = root
	return { root = root, edge = edge, face = face, scale = scale }
end

export type PressState = {
	isEnabled: () -> boolean,
	onActivated: (() -> ())?,
	sound: Hooks.SoundName?,
}

--- Wires press (scale 0.96, edge collapses to 2 px over 0.08 s), release
--- (back-out spring 0.18 s) and PC hover lift (2 px).
function Common.bindPress(ef: EdgeFace, edgeSize: number, state: PressState): { RBXScriptConnection }
	local face = ef.face :: TextButton
	local m = Tokens.motion
	local pressedY = edgeSize - Tokens.edge.pressed
	local pressed = false
	local hovered = false
	local conns: { RBXScriptConnection } = {}

	local function rest()
		local y = if hovered then -m.hoverLift else 0
		Motion.tween(face, m.releaseDuration, "Spring", { Position = UDim2.fromOffset(0, y) })
		Motion.tween(ef.scale, m.releaseDuration, "Spring", { Scale = 1 })
	end

	table.insert(
		conns,
		face.InputBegan:Connect(function(input: InputObject)
			if not state.isEnabled() then
				return
			end
			local t = input.UserInputType
			if
				t == Enum.UserInputType.MouseButton1
				or t == Enum.UserInputType.Touch
				or (input.KeyCode == Enum.KeyCode.ButtonA)
			then
				pressed = true
				Motion.tween(face, m.pressDuration, "Enter", { Position = UDim2.fromOffset(0, pressedY) })
				Motion.tween(ef.scale, m.pressDuration, "Enter", { Scale = m.pressScale })
			elseif t == Enum.UserInputType.MouseMovement then
				hovered = true
				if not pressed then
					Motion.tween(face, m.fastDuration, "Enter", { Position = UDim2.fromOffset(0, -m.hoverLift) })
				end
			end
		end)
	)
	table.insert(
		conns,
		face.InputEnded:Connect(function(input: InputObject)
			local t = input.UserInputType
			if t == Enum.UserInputType.MouseMovement then
				hovered = false
				if not pressed then
					rest()
				end
			elseif pressed then
				pressed = false
				rest()
			end
		end)
	)
	table.insert(
		conns,
		face.Activated:Connect(function()
			if not state.isEnabled() then
				return
			end
			Hooks.sound(state.sound or "click")
			if state.onActivated then
				state.onActivated()
			end
		end)
	)
	return conns
end

--- Moves the face to its resting place for the current enabled state:
--- disabled controls have no edge (§5.3), so the face sits flush at the bottom.
function Common.setFlat(ef: EdgeFace, edgeSize: number, flat: boolean)
	ef.edge.Visible = not flat
	ef.face.Position = UDim2.fromOffset(0, if flat then edgeSize else 0)
end

return Common
