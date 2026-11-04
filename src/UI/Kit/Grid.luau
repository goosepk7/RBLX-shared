--!strict
--[[
	Grid (§5.3): auto-cell scrolling grid. Column count follows the
	container width (Layout.gridColumns) so shop cards and part cards
	reflow from phone to PC without per-screen math.

		local root, grid = Kit.Grid.new({ MinCellWidth = 150, CellAspect = 1.25 })
		for _, item in items do makeCard(item).Parent = grid.content end
]]

local Common = require("./Common")
local Create = require("../Create")
local Layout = require("../Layout")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Scroll" | "Static"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	MinCellWidth: number?,
	CellAspect: number?, -- height / width
	Gap: number?,
	Variant: Variant?,
	Size: UDim2?,
}

export type Handle = {
	content: GuiObject,
	columns: () -> number,
	destroy: () -> (),
}

local Grid = {}

Grid.Variants = { "Scroll", "Static" } :: { Variant }

function Grid.new(props: Props): (GuiObject, Handle)
	local minCell = props.MinCellWidth or 150
	local aspect = props.CellAspect or 1.2
	local gap = props.Gap or Tokens.space.md
	local scroll = props.Variant ~= "Static"

	local root: GuiObject
	if scroll then
		root = Create.new("ScrollingFrame", {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.color("lineDark"),
			Size = props.Size or UDim2.fromScale(1, 1),
		})
	else
		root = Create.group({ Size = props.Size or UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y })
	end
	Common.applyBase(root, props, "Grid")
	-- Room for the 3D edges and selection rings at the grid border.
	Create.padding(Tokens.space.xs, Tokens.space.xs, Tokens.space.lg, Tokens.space.xs).Parent = root

	local grid = Create.new("UIGridLayout", {
		CellPadding = UDim2.fromOffset(gap, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		Parent = root,
	})

	local columns = 1
	local function reflow()
		local width = root.AbsoluteSize.X - Tokens.space.xs * 2 - (if scroll then 8 else 0)
		if width <= 0 then
			return
		end
		columns = Layout.gridColumns(width, minCell, gap)
		local cellW = math.floor((width - gap * (columns - 1)) / columns)
		grid.CellSize = UDim2.fromOffset(cellW, math.floor(cellW * aspect))
	end
	local conn = root:GetPropertyChangedSignal("AbsoluteSize"):Connect(reflow)
	reflow()

	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			content = root,
			columns = function()
				return columns
			end,
			destroy = function()
				conn:Disconnect()
				root:Destroy()
			end,
		}
end

return Grid
