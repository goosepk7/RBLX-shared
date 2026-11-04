--!strict
--[[
	ProgressBar (§5.3): rounded pill track, two-tone fill (fill + darker
	lower band, the same 3D language as buttons), animated fill, optional
	segment ticks, optional centered label with stroke.

		local root, bar = Kit.ProgressBar.new({ Value = 0.4, Segments = 5, Label = "24 / 60" })
		bar.setValue(0.6)
]]

local Common = require("./Common")
local Create = require("../Create")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Secondary" | "Success" | "Danger" | "Warning" | "Info" | "Gold"

export type Props = Common.BaseProps & {
	Value: number, -- 0..1
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
	local value = math.clamp(props.Value, 0, 1)

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
		Size = UDim2.fromScale(value, 1),
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
		Position = UDim2.new(0, 6, 0, 2),
		Size = UDim2.new(1, -12, 0.22, 0),
		ZIndex = 4,
		Parent = fill,
	}, { Create.pill() })

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
				local target = UDim2.fromScale(math.clamp(v, 0, 1), 1)
				if animate == false then
					fill.Size = target
				else
					Motion.tween(fill, Tokens.motion.progressFill, "Enter", { Size = target })
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
