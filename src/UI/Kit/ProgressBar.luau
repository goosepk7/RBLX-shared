--!strict
--[[
	ProgressBar (§5.3): rounded pill track, two-tone fill (fill + darker
	lower band, the same 3D language as buttons), animated fill, optional
	segment ticks, optional centered label with stroke.

		local root, bar = Kit.ProgressBar.new({ Value = 0.4, Segments = 5, Label = "24 / 60" })
		bar.setValue(0.6)

	`Bipolar = true` takes a value in -1..1 and fills from the center tick toward either end:
	a lean or balance meter ("tipping left / right"), a tug of war.
]]

local Common = require("./Common")
local Create = require("../Create")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Secondary" | "Success" | "Danger" | "Warning" | "Info" | "Gold"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Value: number, -- 0..1, or -1..1 when Bipolar
	Bipolar: boolean?,
	Variant: Variant?,
	Segments: number?, -- draws Segments-1 ticks
	Label: string?,
	Height: number?,
	Width: number?, -- px; default fills parent width
}

export type Handle = {
	setValue: (value: number, animate: boolean?) -> (),
	setLabel: (string?) -> (),
	destroy: () -> (),
}

local ProgressBar = {}

--- The fill's x position and width (scale of the track) for a value. Pure; tested under lune.
function ProgressBar.fillSpan(value: number, bipolar: boolean): (number, number)
	if value ~= value then
		value = 0
	end
	if bipolar then
		local v = math.clamp(value, -1, 1)
		return 0.5 + math.min(v, 0) / 2, math.abs(v) / 2
	end
	return 0, math.clamp(value, 0, 1)
end

ProgressBar.Variants = { "Primary", "Secondary", "Success", "Danger", "Warning", "Info", "Gold" } :: { Variant }

local FILLS: { [Variant]: { Theme.ColorName } } = {
	Primary = { "primary", "primaryEdge" },
	Secondary = { "secondary", "secondaryEdge" },
	Success = { "success", "successEdge" },
	Danger = { "danger", "dangerEdge" },
	Warning = { "warning", "warningEdge" },
	Info = { "info", "infoEdge" },
	Gold = { "gold", "goldEdge" },
}

function ProgressBar.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Primary"
	local colors = FILLS[variant]
	local h = props.Height or Tokens.size.progressHeight
	local bipolar = props.Bipolar == true
	local startX, startW = ProgressBar.fillSpan(props.Value, bipolar)

	local root = Create.new("Frame", {
		BackgroundColor3 = Theme.color("paper2"),
		BorderSizePixel = 0,
		Size = if props.Width then UDim2.fromOffset(props.Width, h) else UDim2.new(1, 0, 0, h),
		ClipsDescendants = false,
	}, {
		Create.pill(),
		Create.stroke("line", Tokens.border.card),
	})
	Common.applyBase(root, props, "ProgressBar")

	local clip = Create.group({ Name = "Clip", ClipsDescendants = true, Parent = root }, { Create.pill() })

	-- Lower band (dark) with the light fill on top covering the upper 60%.
	local fill = Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.color(colors[2]),
		BorderSizePixel = 0,
		Position = UDim2.fromScale(startX, 0),
		Size = UDim2.fromScale(startW, 1),
		ZIndex = 2,
		Parent = clip,
	}, { Create.pill() })
	Create.new("Frame", {
		Name = "Light",
		BackgroundColor3 = Theme.color(colors[1]),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0.62),
		ZIndex = 3,
		Parent = fill,
	}, { Create.pill() })
	-- Sticker highlight on the light band.
	Create.new("Frame", {
		Name = "Shine",
		BackgroundColor3 = Theme.color("white"),
		BackgroundTransparency = Tokens.alpha.highlight - 0.2,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(6, 2),
		Size = UDim2.new(1, -12, 0.22, 0),
		ZIndex = 4,
		Parent = fill,
	}, { Create.pill() })

	if bipolar then
		Create.new("Frame", {
			Name = "Center",
			BackgroundColor3 = Theme.color("ink"),
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.new(0, 3, 1, 0),
			ZIndex = 5,
			Parent = clip,
		})
	end

	local segments = props.Segments or 0
	if segments > 1 then
		for i = 1, segments - 1 do
			Create.new("Frame", {
				Name = "Tick" .. i,
				BackgroundColor3 = Theme.color("paper"),
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(i / segments, 0),
				Size = UDim2.new(0, 2, 1, 0),
				ZIndex = 5,
				Parent = clip,
			})
		end
	end

	local label = Create.text({
		Name = "Label",
		Text = props.Label or "",
		Role = "number",
		SizeName = "caption",
		Color = "white",
		Stroke = "ink",
		StrokeThickness = 1.5,
		XAlign = "Center",
		ZIndex = 6,
		Visible = props.Label ~= nil,
		Parent = root,
	})

	if props.Disabled then
		Common.setDimmed(root, true)
	end
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			setValue = function(v: number, animate: boolean?)
				local x, w = ProgressBar.fillSpan(v, bipolar)
				local position = UDim2.fromScale(x, 0)
				local size = UDim2.fromScale(w, 1)
				if animate == false then
					fill.Position = position
					fill.Size = size
				else
					Motion.tween(fill, Tokens.motion.progressFill, "Enter", { Position = position, Size = size })
				end
			end,
			setLabel = function(t: string?)
				label.Visible = t ~= nil
				label.Text = t or ""
			end,
			destroy = function()
				root:Destroy()
			end,
		}
end

return ProgressBar
