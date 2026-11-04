--!strict
--[[
	Chip (§5.3): 10 px radius, 4 px edge. Used for the bottom-center
	contextual prompt ("Hold E / tap to enter Pit"), tags ("Min height 12"),
	and filters. Interactive when OnActivated is given; the total height
	(44 + 4 edge) keeps it a valid tap target at the smallest UI scale.
]]

local Common = require("./Common")
local Create = require("../Create")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Secondary" | "Primary" | "Success" | "Danger" | "Warning" | "Info" | "Gold"

export type Props = Common.BaseProps & {
	Text: string,
	Variant: Variant?,
	Icon: string?,
	KeyHint: string?, -- e.g. "E" or "ButtonX" glyph text, shown in a keycap
	OnActivated: (() -> ())?,
}

export type Handle = {
	setText: (string) -> (),
	setKeyHint: (string?) -> (),
	setDisabled: (boolean) -> (),
	destroy: () -> (),
}

local Chip = {}

Chip.Variants = { "Secondary", "Primary", "Success", "Danger", "Warning", "Info", "Gold" } :: { Variant }

function Chip.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Secondary"
	local colors = Theme.variant(variant)
	local height = Tokens.size.chipHeight
	local edgeSize = Tokens.edge.chip
	local interactive = props.OnActivated ~= nil
	local disabled = props.Disabled == true

	local ef = Common.edgeFace({
		height = height,
		edge = edgeSize,
		radius = Tokens.radius.chip,
		fill = colors.fill,
		edgeColor = colors.edge,
		border = colors.border,
		interactive = interactive,
	})
	local root = ef.root
	Common.applyBase(root, props, "Chip")
	root.AutomaticSize = Enum.AutomaticSize.X
	root.Size = UDim2.fromOffset(0, height + edgeSize)
	ef.face.AutomaticSize = Enum.AutomaticSize.X
	ef.face.Size = UDim2.fromOffset(0, height)
	ef.edge.Size = UDim2.new(1, 0, 0, height)

	local row = Create.group({
		Name = "Content",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 3,
		Parent = ef.face,
	}, {
		Create.list("Horizontal", Tokens.space.sm, "Left", "Center"),
		Create.padding(0, Tokens.space.md),
	})

	local keycap = Create.new("Frame", {
		Name = "KeyHint",
		BackgroundColor3 = Theme.color("ink"),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(28, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 0,
		Visible = false,
		ZIndex = 3,
		Parent = row,
	}, { Create.corner(6), Create.padding(0, 6) })
	local keyText = Create.text({
		Text = "",
		Role = "button",
		SizeName = "caption",
		Color = "white",
		XAlign = "Center",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 16, 1, 0),
		ZIndex = 3,
		Parent = keycap,
	})

	if props.Icon then
		Create.new("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Image = props.Icon,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(Tokens.size.iconSm, Tokens.size.iconSm),
			LayoutOrder = 1,
			ZIndex = 3,
			Parent = row,
		})
	end

	local label = Create.text({
		Name = "Label",
		Text = props.Text,
		Role = "button",
		SizeName = "body",
		Color = colors.text,
		Stroke = colors.textStroke,
		StrokeThickness = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		ZIndex = 3,
		Parent = row,
	})

	local function setKeyHint(hint: string?)
		keycap.Visible = hint ~= nil
		keyText.Text = hint or ""
	end

	local conns: { RBXScriptConnection } = {}
	if interactive then
		conns = Common.bindPress(ef, edgeSize, {
			isEnabled = function()
				return not disabled
			end,
			onActivated = props.OnActivated,
		})
	end

	local function setDisabled(v: boolean)
		disabled = v
		if interactive then
			(ef.face :: TextButton).Active = not v
		end
		Common.setFlat(ef, edgeSize, v)
		Common.setDimmed(root, v)
	end

	setKeyHint(props.KeyHint)
	setDisabled(disabled)
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			setText = function(t: string)
				label.Text = t
			end,
			setKeyHint = setKeyHint,
			setDisabled = setDisabled,
			destroy = function()
				for _, c in conns do
					c:Disconnect()
				end
				root:Destroy()
			end,
		}
end

return Chip
