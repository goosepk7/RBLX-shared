--!strict
--[[
	Panel (§5.3): Paper card with a gradient header strip (accent ->
	accent-dark), H2 title, and a 52 px close button top-right. Body scrolls
	when Scroll is true. Footer holds the panel's one primary action.

		local root, panel = Kit.Panel.new({ Title = "Shop", OnClose = close, Scroll = true })
		Kit.Button.new({ Text = "Buy", Fill = true, Parent = panel.footer })
]]

local Common = require("./Common")
local Create = require("../Create")
local Hooks = require("../Hooks")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Secondary" | "Danger" | "Gold"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Title: string,
	Variant: Variant?, -- header strip color family
	Icon: string?, -- optional title icon
	Size: UDim2?,
	Scroll: boolean?,
	FooterHeight: number?, -- px; 0 hides the footer
	OnClose: (() -> ())?,
}

export type Handle = {
	body: GuiObject, -- Frame or ScrollingFrame
	footer: Frame,
	closeButton: GuiObject?,
	setTitle: (string) -> (),
	destroy: () -> (),
}

local Panel = {}

Panel.Variants = { "Primary", "Secondary", "Danger", "Gold" } :: { Variant }

local HEADER_COLORS: { [Variant]: { Theme.ColorName } } = {
	Primary = { "primary", "primaryEdge" },
	Secondary = { "secondary", "secondaryEdge" },
	Danger = { "danger", "dangerEdge" },
	Gold = { "gold", "goldEdge" },
}

function Panel.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Primary"
	local header = HEADER_COLORS[variant]
	local headerH = Tokens.size.panelHeader
	local edgeSize = Tokens.edge.card
	local footerH = props.FooterHeight or (Tokens.size.buttonHeight + Tokens.edge.button + Tokens.space.lg * 2)

	local ef = Common.edgeFace({
		height = 0,
		edge = edgeSize,
		radius = Tokens.radius.card,
		fill = "paper2",
		edgeColor = "lineDark",
		border = "line",
		interactive = false,
	})
	local root = ef.root
	Common.applyBase(root, props, "Panel")
	root.Size = props.Size or UDim2.fromOffset(520, 360)
	ef.face.Size = UDim2.new(1, 0, 1, -edgeSize)
	ef.edge.Size = UDim2.new(1, 0, 1, -edgeSize)
	ef.face.ClipsDescendants = true

	local strip = Create.new("Frame", {
		Name = "Header",
		BackgroundColor3 = Theme.color("white"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, headerH),
		ZIndex = 3,
		Parent = ef.face,
	}, {
		Create.corner(Tokens.radius.card),
		Create.new("UIGradient", {
			Color = ColorSequence.new(Theme.color(header[1]), Theme.color(header[2])),
			Rotation = 90,
		}),
	})
	-- Square off the strip's bottom corners.
	Create.new("Frame", {
		Name = "HeaderBase",
		BackgroundColor3 = Theme.color(header[2]),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Tokens.radius.card),
		Position = UDim2.fromOffset(0, headerH - Tokens.radius.card),
		ZIndex = 2,
		Parent = ef.face,
	})

	local titleRow = Create.group({
		Name = "TitleRow",
		Size = UDim2.new(1, -(Tokens.size.closeButton + Tokens.space.lg), 1, 0),
		ZIndex = 4,
		Parent = strip,
	}, {
		Create.list("Horizontal", Tokens.space.sm, "Left", "Center"),
		Create.padding(0, 0, 0, Tokens.space.lg),
	})
	if props.Icon then
		Common.icon(props.Icon :: string, {
			Name = "Icon",
			Size = UDim2.fromOffset(Tokens.size.iconLg - 8, Tokens.size.iconLg - 8),
			ZIndex = 4,
			Parent = titleRow,
		})
	end
	local lightHeader = variant == "Gold"
	local title = Create.text({
		Name = "Title",
		Text = props.Title,
		Role = "display",
		SizeName = "h2",
		Color = if lightHeader then "ink" else "white",
		Stroke = if lightHeader then nil else header[2],
		StrokeThickness = 2,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 4,
		Parent = titleRow,
	})

	local closeButton: GuiObject? = nil
	if props.OnClose then
		local close = Create.new("TextButton", {
			Name = "Close",
			AutoButtonColor = false,
			Text = "",
			BackgroundColor3 = Theme.color("white"),
			BackgroundTransparency = 0.8,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -Tokens.space.sm, 0.5, 0),
			Size = UDim2.fromOffset(Tokens.size.closeButton, Tokens.size.closeButton),
			ZIndex = 5,
			Parent = strip,
		}, {
			Create.pill(),
			Create.stroke("white", 2, 0.2),
		})
		close.SelectionImageObject = Common.selectionRing(999)
		-- The "x" is two rounded bars so it never depends on an asset.
		for i, rot in { 45, -45 } do
			Create.new("Frame", {
				Name = "Bar" .. i,
				BackgroundColor3 = Theme.color(if lightHeader then "ink" else "white"),
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(20, 4),
				Rotation = rot,
				ZIndex = 6,
				Parent = close,
			}, { Create.pill() })
		end
		local onClose = props.OnClose :: () -> ()
		close.Activated:Connect(function()
			Hooks.sound("close")
			onClose()
		end)
		closeButton = close
	end

	local body: GuiObject
	local bodyProps = {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, headerH),
		Size = UDim2.new(1, 0, 1, -(headerH + footerH)),
		ZIndex = 2,
	}
	if props.Scroll then
		local scroll = Create.new("ScrollingFrame", bodyProps)
		scroll.CanvasSize = UDim2.new()
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroll.ScrollingDirection = Enum.ScrollingDirection.Y
		scroll.ScrollBarThickness = 6
		scroll.ScrollBarImageColor3 = Theme.color("lineDark")
		scroll.ElasticBehavior = Enum.ElasticBehavior.Always
		body = scroll
	else
		body = Create.new("Frame", bodyProps)
	end
	Create.padding(Tokens.space.lg).Parent = body
	Create.list("Vertical", Tokens.space.md, "Center", "Top").Parent = body
	body.Parent = ef.face

	local footer = Create.group({
		Name = "Footer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, footerH),
		Visible = footerH > 0,
		ZIndex = 3,
		Parent = ef.face,
	}, {
		Create.padding(Tokens.space.lg),
		Create.list("Horizontal", Tokens.space.md, "Center", "Center"),
	})

	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			body = body,
			footer = footer,
			closeButton = closeButton,
			setTitle = function(t: string)
				title.Text = t
			end,
			destroy = function()
				root:Destroy()
			end,
		}
end

return Panel
