--!strict
--[[
	ListRow (§5.3): 64 px row with optional leading rank/icon, title +
	subtitle, and a trailing value or action. "Pinned" is the accent-edged
	row used for "your rank" at the bottom of Leaderboards (§5.5).
]]

local Common = require("./Common")
local Create = require("../Create")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Default" | "Pinned" | "Gold" | "Silver" | "Bronze"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Title: string,
	Subtitle: string?,
	Icon: string?,
	Rank: number?, -- leaderboard rank, drawn in a medal disc
	Value: string?, -- trailing, already formatted
	Variant: Variant?,
	OnActivated: (() -> ())?,
}

export type Handle = {
	setValue: (string) -> (),
	setTitle: (string) -> (),
	trailing: Frame, -- parent a Button here for row actions
	destroy: () -> (),
}

local ListRow = {}

ListRow.Variants = { "Default", "Pinned", "Gold", "Silver", "Bronze" } :: { Variant }

local MEDAL: { [Variant]: { Theme.ColorName } } = {
	Gold = { "gold", "goldEdge" },
	Silver = { "line", "lineDark" },
	Bronze = { "warning", "warningEdge" },
	Pinned = { "primary", "primaryEdge" },
	Default = { "paper2", "line" },
}

function ListRow.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Default"
	local h = Tokens.size.rowHeight
	local edgeSize = Tokens.edge.chip
	local pinned = variant == "Pinned"
	local ef = Common.edgeFace({
		height = h,
		edge = edgeSize,
		radius = Tokens.radius.card,
		fill = "paper",
		edgeColor = if pinned then "primaryEdge" else "lineDark",
		border = if pinned then "primary" else "line",
		interactive = props.OnActivated ~= nil,
	})
	local root = ef.root
	Common.applyBase(root, props, "ListRow")
	root.Size = UDim2.new(1, 0, 0, h + edgeSize)

	local row = Create.group({ Name = "Content", ZIndex = 3, Parent = ef.face }, {
		Create.list("Horizontal", Tokens.space.md, "Left", "Center"),
		Create.padding(0, Tokens.space.md),
	})

	local leadSize = h - 20
	if props.Rank then
		local medal = MEDAL[variant]
		local disc = Create.new("Frame", {
			Name = "Rank",
			BackgroundColor3 = Theme.color(medal[1]),
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(leadSize, leadSize),
			LayoutOrder = 1,
			ZIndex = 3,
			Parent = row,
		}, { Create.pill(), Create.stroke(medal[2], 2) })
		Create.text({
			Text = tostring(props.Rank),
			Role = "number",
			SizeName = "h3",
			Color = if variant == "Default" then "ink" else "white",
			Stroke = if variant == "Default" then nil else "ink",
			StrokeThickness = 1.5,
			XAlign = "Center",
			ZIndex = 4,
			Parent = disc,
		})
	end
	if props.Icon then
		Create.new("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Image = props.Icon,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(leadSize, leadSize),
			LayoutOrder = 2,
			ZIndex = 3,
			Parent = row,
		})
	end

	local leadWidth = (if props.Rank then leadSize + Tokens.space.md else 0)
		+ (if props.Icon then leadSize + Tokens.space.md else 0)
	local trailingWidth = 140
	local textColumn = Create.group({
		Name = "Text",
		Size = UDim2.new(1, -(leadWidth + trailingWidth + Tokens.space.md), 1, 0),
		LayoutOrder = 3,
		ZIndex = 3,
		Parent = row,
	}, { Create.list("Vertical", 0, "Left", "Center") })
	local title = Create.text({
		Name = "Title",
		Text = props.Title,
		Role = "button",
		SizeName = "body",
		Color = "ink",
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 1,
		ZIndex = 3,
		Parent = textColumn,
	})
	if props.Subtitle then
		Create.text({
			Name = "Subtitle",
			Text = props.Subtitle,
			Role = "caption",
			SizeName = "caption",
			Color = "inkSoft",
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 2,
			ZIndex = 3,
			Parent = textColumn,
		})
	end

	local trailing = Create.group({
		Name = "Trailing",
		Size = UDim2.new(0, trailingWidth, 1, 0),
		LayoutOrder = 4,
		ZIndex = 3,
		Parent = row,
	}, { Create.list("Horizontal", Tokens.space.sm, "Right", "Center") })
	local valueLabel = Create.text({
		Name = "Value",
		Text = props.Value or "",
		Role = "number",
		SizeName = "h3",
		Color = if pinned then "primary" else "ink",
		Stroke = if pinned then "primaryEdge" else nil,
		StrokeThickness = 1,
		XAlign = "Right",
		Visible = props.Value ~= nil,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = trailing,
	})

	local conns: { RBXScriptConnection } = {}
	if props.OnActivated then
		conns = Common.bindPress(ef, edgeSize, {
			isEnabled = function()
				return props.Disabled ~= true
			end,
			onActivated = props.OnActivated,
		})
	end
	if props.Disabled then
		Common.setDimmed(root, true)
	end
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			setValue = function(t: string)
				valueLabel.Visible = true
				valueLabel.Text = t
			end,
			setTitle = function(t: string)
				title.Text = t
			end,
			trailing = trailing,
			destroy = function()
				for _, c in conns do
					c:Disconnect()
				end
				root:Destroy()
			end,
		}
end

return ListRow
