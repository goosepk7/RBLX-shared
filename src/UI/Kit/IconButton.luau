--!strict
--[[
	IconButton (§5.3): circular 52 px, used for the HUD side rail and the
	top-right gear/bag. Optional count badge and a label that appears on
	hover (PC) or long-press (touch) via Tooltip.
]]

local Common = require("./Common")
local Create = require("../Create")
local Format = require("../Format")
local Theme = require("../Theme")
local Tokens = require("../Tokens")
local Tooltip = require("./Tooltip")

export type Variant = "Secondary" | "Primary" | "Gold" | "Danger"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Icon: string, -- asset name ("icon_settings")
	Label: string, -- tooltip + accessibility; already localized
	Variant: Variant?,
	Badge: number?, -- notification count; 0/nil hides it
	OnActivated: (() -> ())?,
}

export type Handle = {
	setBadge: (number?) -> (),
	setDisabled: (boolean) -> (),
	setLoading: (boolean) -> (),
	destroy: () -> (),
}

local IconButton = {}

IconButton.Variants = { "Secondary", "Primary", "Gold", "Danger" } :: { Variant }

function IconButton.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Secondary"
	local colors = Theme.variant(variant)
	local size = Tokens.size.iconButton
	local edgeSize = Tokens.edge.chip
	local disabled = props.Disabled == true
	local loading = props.Loading == true

	local ef = Common.edgeFace({
		height = size,
		edge = edgeSize,
		radius = nil,
		fill = colors.fill,
		edgeColor = colors.edge,
		border = colors.border,
		interactive = true,
	})
	local root = ef.root
	Common.applyBase(root, props, "IconButton")
	root.Size = UDim2.fromOffset(size, size + edgeSize)

	local icon = Common.icon(props.Icon :: string, {
		Name = "Icon",
		Size = UDim2.fromOffset(Tokens.size.iconMd, Tokens.size.iconMd),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ZIndex = 3,
		Parent = ef.face,
	})

	local badge = Create.new("Frame", {
		Name = "Badge",
		BackgroundColor3 = Theme.color("danger"),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 4, 0, -4),
		Size = UDim2.fromOffset(22, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 6,
		Visible = false,
		Parent = ef.face,
	}, {
		Create.pill(),
		Create.stroke("white", 2),
		Create.padding(0, 6),
	})
	local badgeText = Create.text({
		Name = "Count",
		Text = "",
		Role = "number",
		SizeName = "caption",
		Color = "white",
		XAlign = "Center",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 10, 1, 0),
		ZIndex = 6,
		Parent = badge,
	})

	local spinner = Common.spinner(colors.text, 6)
	spinner.Parent = ef.face

	local tip = Tooltip.attach(ef.face, props.Label)

	local function refresh()
		local face = ef.face :: TextButton
		face.Active = not disabled and not loading
		face.Selectable = not disabled
		icon.Visible = not loading
		spinner.Visible = loading
		Common.setFlat(ef, edgeSize, disabled)
		Common.setDimmed(root, disabled)
	end

	local function setBadge(n: number?)
		local count = n or 0
		badge.Visible = count > 0
		badgeText.Text = if count > 99 then "99+" else Format.showCompact(count)
	end

	local conns = Common.bindPress(ef, edgeSize, {
		isEnabled = function()
			return not disabled and not loading
		end,
		onActivated = props.OnActivated,
	})

	setBadge(props.Badge)
	refresh()
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			setBadge = setBadge,
			setDisabled = function(v: boolean)
				disabled = v
				refresh()
			end,
			setLoading = function(v: boolean)
				loading = v
				refresh()
			end,
			destroy = function()
				for _, c in conns do
					c:Disconnect()
				end
				tip.destroy()
				root:Destroy()
			end,
		}
end

return IconButton
