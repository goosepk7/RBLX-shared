--!strict
--[[
	Drawer (§5.3): bottom sheet on phone (touch or portrait), side panel on
	PC/console. The style is picked from the current input mode at open time
	(Layout.drawerStyle), so the same call site works everywhere.

		local drawer = Kit.Drawer.new({ Title = "Parts", Mode = manager:getInputMode() })
		-- parent rows into drawer.body
		drawer.open(area.modalLayer, area.backdropLayer)
]]

local Create = require("../Create")
local Hooks = require("../Hooks")
local Layout = require("../Layout")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Sheet" | "Side"

export type Props = {
	Title: string,
	Variant: Variant?, -- force a style; default picks from Mode + viewport
	Mode: Layout.InputMode?,
	Extent: number?, -- fraction of screen height (sheet) or width (side); default 0.55 / 0.36
	OnClosed: (() -> ())?,
	Name: string?,
}

export type Handle = {
	root: Frame,
	body: ScrollingFrame,
	open: (parent: Instance, backdropParent: Instance?) -> (), -- see Modal.open
	close: () -> (),
}

local Drawer = {}

Drawer.Variants = { "Sheet", "Side" } :: { Variant }

function Drawer.new(props: Props): Handle
	local root = Create.group({ Name = props.Name or "Drawer", ZIndex = 40, Visible = false })
	local scrim = Create.new("TextButton", {
		Name = "Scrim",
		AutoButtonColor = false,
		Text = "",
		Selectable = false,
		BackgroundColor3 = Theme.color("ink"),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 40,
		Parent = root,
	})
	local sheet = Create.new("Frame", {
		Name = "Sheet",
		BackgroundColor3 = Theme.color("paper2"),
		BorderSizePixel = 0,
		ZIndex = 41,
		Parent = root,
	}, {
		Create.corner(Tokens.radius.card + 6),
		Create.stroke("line", Tokens.border.card),
	})
	local grabber = Create.new("Frame", {
		Name = "Grabber",
		BackgroundColor3 = Theme.color("lineDark"),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, Tokens.space.sm),
		Size = UDim2.fromOffset(48, 6),
		ZIndex = 42,
		Parent = sheet,
	}, { Create.pill() })
	Create.text({
		Name = "Title",
		Text = props.Title,
		Role = "display",
		SizeName = "h3",
		Color = "ink",
		Position = UDim2.fromOffset(Tokens.space.lg, Tokens.space.lg),
		Size = UDim2.new(1, -Tokens.space.lg * 2, 0, 32),
		ZIndex = 42,
		Parent = sheet,
	})
	local body = Create.new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.new(1, 0, 1, -56),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.color("lineDark"),
		ZIndex = 42,
		Parent = sheet,
	}, {
		Create.padding(0, Tokens.space.lg, Tokens.space.xl, Tokens.space.lg),
		Create.list("Vertical", Tokens.space.sm, "Center", "Top"),
	})

	local style: Variant = "Sheet"
	local opened = false
	root.Destroying:Connect(function()
		scrim:Destroy()
	end)

	local function shownPos(): UDim2
		return if style == "Sheet" then UDim2.fromScale(0, 1) else UDim2.fromScale(1, 0)
	end
	local function hiddenPos(): UDim2
		return if style == "Sheet" then UDim2.fromScale(0, 2) else UDim2.fromScale(2, 0)
	end

	local function layout(parent: Instance)
		local mode: Layout.InputMode = props.Mode or "Touch"
		local w, h = 844, 390
		if parent:IsA("GuiBase2d") then
			local size = (parent :: GuiBase2d).AbsoluteSize
			w, h = size.X, size.Y
		end
		style = props.Variant or Layout.drawerStyle(mode, w, h)
		grabber.Visible = style == "Sheet"
		if style == "Sheet" then
			local extent = props.Extent or 0.55
			sheet.AnchorPoint = Vector2.new(0, 1)
			sheet.Size = UDim2.new(1, 0, extent, Tokens.radius.card + 6)
		else
			local extent = props.Extent or 0.36
			sheet.AnchorPoint = Vector2.new(1, 0)
			sheet.Size = UDim2.new(extent, Tokens.radius.card + 6, 1, 0)
		end
	end

	local function close()
		if not opened then
			return
		end
		opened = false
		Hooks.sound("close")
		Motion.exit(scrim, { BackgroundTransparency = 1 })
		Motion.exit(sheet, { Position = hiddenPos() }).Completed:Once(function()
			if not opened then
				root.Visible = false
				scrim.Visible = false
				if props.OnClosed then
					props.OnClosed()
				end
			end
		end)
	end

	local function open(parent: Instance, backdropParent: Instance?)
		scrim.Parent = backdropParent or root
		scrim.Visible = true
		root.Parent = parent
		layout(parent)
		opened = true
		root.Visible = true
		Hooks.sound("open")
		sheet.Position = hiddenPos()
		-- The extra radius pushes the far rounded corners off-screen.
		local target = shownPos()
		if style == "Sheet" then
			target = UDim2.new(target.X, UDim.new(1, Tokens.radius.card + 6))
		else
			target = UDim2.new(UDim.new(1, Tokens.radius.card + 6), target.Y)
		end
		Motion.enter(scrim, { BackgroundTransparency = 0.7 })
		Motion.tween(sheet, Tokens.motion.enterDuration, "Enter", { Position = target })
	end

	scrim.Activated:Connect(close)

	return { root = root, body = body, open = open, close = close }
end

return Drawer
