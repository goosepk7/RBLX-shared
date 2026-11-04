--!strict
--[[
	Button (§5.3). Variants: Primary, Secondary, Success, Danger, Gold, Ghost.

		local root, handle = Kit.Button.new({
			Text = Loc.t("shop.buy"), Variant = "Primary", Icon = Assets.get("icon_wins"),
			OnActivated = function() ... end,
		})
		handle.setLoading(true)
]]

local Common = require("./Common")
local Create = require("../Create")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Secondary" | "Success" | "Danger" | "Gold" | "Ghost"
export type Size = "Large" | "Small"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Text: string,
	Variant: Variant?,
	Size: Size?,
	Icon: string?, -- image content id (from Assets.get), shown left of the text
	Width: number?, -- px at reference scale; ignored when Fill is true
	Fill: boolean?, -- stretch to parent width
	OnActivated: (() -> ())?,
}

export type Handle = {
	setText: (string) -> (),
	setDisabled: (boolean) -> (),
	setLoading: (boolean) -> (),
	destroy: () -> (),
}

local Button = {}

Button.Variants = { "Primary", "Secondary", "Success", "Danger", "Gold", "Ghost" } :: { Variant }

function Button.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Primary"
	local colors = Theme.variant(variant)
	local isGhost = variant == "Ghost"
	local height = if props.Size == "Small" then Tokens.size.buttonHeightSmall else Tokens.size.buttonHeight
	local edgeSize = if isGhost then 0 else Tokens.edge.button
	local disabled = props.Disabled == true
	local loading = props.Loading == true

	local ef = Common.edgeFace({
		height = height,
		edge = edgeSize,
		radius = Tokens.radius.button,
		fill = colors.fill,
		edgeColor = colors.edge,
		border = colors.border,
		interactive = true,
		transparentFill = isGhost,
	})
	local root = ef.root
	Common.applyBase(root, props, "Button")
	if props.Fill then
		root.Size = UDim2.new(1, 0, 0, height + edgeSize)
	else
		root.Size = UDim2.fromOffset(props.Width or 200, height + edgeSize)
	end

	local content = Create.group({ Name = "Content", ZIndex = 3, Parent = ef.face }, {
		Create.list("Horizontal", Tokens.space.sm, "Center", "Center"),
		Create.padding(0, Tokens.space.lg),
	})

	if props.Icon then
		Create.new("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Image = props.Icon,
			Size = UDim2.fromOffset(Tokens.size.iconMd, Tokens.size.iconMd),
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = 1,
			ZIndex = 3,
			Parent = content,
		})
	end

	local label = Create.text({
		Name = "Label",
		Text = props.Text,
		Role = "button",
		SizeName = "button",
		Color = if isGhost then "primaryEdge" else colors.text,
		Stroke = colors.textStroke,
		StrokeThickness = 1.5,
		XAlign = "Center",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		ZIndex = 3,
		Parent = content,
	})

	local spinner = Common.spinner(colors.text, 8)
	spinner.Parent = ef.face

	local function refresh()
		local face = ef.face :: TextButton
		face.Active = not disabled and not loading
		face.Selectable = not disabled
		content.Visible = not loading
		spinner.Visible = loading
		Common.setFlat(ef, edgeSize, disabled)
		Common.setDimmed(root, disabled)
	end

	local conns = Common.bindPress(ef, edgeSize, {
		isEnabled = function()
			return not disabled and not loading
		end,
		onActivated = props.OnActivated,
	})

	refresh()
	if props.Parent then
		root.Parent = props.Parent
	end

	local handle: Handle = {
		setText = function(text: string)
			label.Text = text
		end,
		setDisabled = function(value: boolean)
			disabled = value
			refresh()
		end,
		setLoading = function(value: boolean)
			loading = value
			refresh()
		end,
		destroy = function()
			for _, c in conns do
				c:Disconnect()
			end
			root:Destroy()
		end,
	}
	return root, handle
end

return Button
