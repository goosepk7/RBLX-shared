--!strict
--[[
	Card (§5.3): Paper surface, 14 px radius, 2 px Line border. "Elevated"
	adds the 6 px 3D bottom edge (primary cards); "Accent" uses the game
	accent for border and edge (featured cards); "Inset" is a flat Paper-2
	well for grouping inside panels.

	Returns the root and the Content frame to parent children into.
]]

local Common = require("./Common")
local Create = require("../Create")
local Tokens = require("../Tokens")

export type Variant = "Plain" | "Elevated" | "Accent" | "Inset"

export type Props = Common.BaseProps & {
	Variant: Variant?,
	Size: UDim2?, -- default fills parent width, 160 px tall
	AutoHeight: boolean?, -- grow to fit content
	Padding: number?,
}

export type Handle = {
	content: Frame,
	setDisabled: (boolean) -> (),
	destroy: () -> (),
}

local Card = {}

Card.Variants = { "Plain", "Elevated", "Accent", "Inset" } :: { Variant }

function Card.new(props: Props): (Frame, Handle)
	local variant: Variant = props.Variant or "Plain"
	local hasEdge = variant == "Elevated" or variant == "Accent"
	local edgeSize = if hasEdge then Tokens.edge.card else 0
	local ef = Common.edgeFace({
		height = 0,
		edge = edgeSize,
		radius = Tokens.radius.card,
		fill = if variant == "Inset" then "paper2" else "paper",
		edgeColor = if variant == "Accent" then "primaryEdge" else "lineDark",
		border = if variant == "Accent" then "primary" else "line",
		interactive = false,
	})
	local root = ef.root
	Common.applyBase(root, props, "Card")
	root.Size = props.Size or UDim2.new(1, 0, 0, 160)

	-- Face and edge track the root size; the edge peeks out below.
	ef.face.Size = UDim2.new(1, 0, 1, -edgeSize)
	ef.edge.Size = UDim2.new(1, 0, 1, -edgeSize)

	local content = Create.group({ Name = "Content", ZIndex = 2, Parent = ef.face }, {
		Create.padding(props.Padding or Tokens.space.lg),
	})

	if props.AutoHeight then
		root.AutomaticSize = Enum.AutomaticSize.Y
		ef.face.AutomaticSize = Enum.AutomaticSize.Y
		content.AutomaticSize = Enum.AutomaticSize.Y
		content.Size = UDim2.fromScale(1, 0)
		root.Size = UDim2.new(root.Size.X, UDim.new(0, edgeSize))
		ef.face.Size = UDim2.fromScale(1, 0)
		-- With automatic height the edge is drawn as a stroke-free underlay
		-- sized from the face each frame it changes.
		ef.face:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			ef.edge.Size = UDim2.new(1, 0, 0, ef.face.AbsoluteSize.Y)
		end)
	end

	if props.Disabled then
		Common.setDimmed(root, true)
	end
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			content = content,
			setDisabled = function(value: boolean)
				Common.setDimmed(root, value)
			end,
			destroy = function()
				root:Destroy()
			end,
		}
end

return Card
