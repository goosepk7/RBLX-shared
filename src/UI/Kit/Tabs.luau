--!strict
--[[
	Tabs (§5.3): pill tabs on a Paper-2 track with a sliding accent
	indicator. Shop (Boosts/Cosmetics/Passes) and Leaderboards use these.

		local root, tabs = Kit.Tabs.new({ Items = { "Boosts", "Cosmetics", "Passes" }, OnChanged = show })
		tabs.select(2)
]]

local Common = require("./Common")
local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Secondary"

export type Props = Common.BaseProps & {
	Items: { string }, -- localized labels
	Selected: number?,
	Variant: Variant?,
	Width: number?, -- px; default fills parent
	OnChanged: ((index: number) -> ())?,
}

export type Handle = {
	select: (index: number, silent: boolean?) -> (),
	getSelected: () -> number,
	setDisabled: (boolean) -> (),
	destroy: () -> (),
}

local Tabs = {}

Tabs.Variants = { "Primary", "Secondary" } :: { Variant }

function Tabs.new(props: Props): (Frame, Handle)
	local count = math.max(1, #props.Items)
	local variant: Variant = props.Variant or "Primary"
	local fill: Theme.ColorName = if variant == "Secondary" then "secondary" else "primary"
	local edge: Theme.ColorName = if variant == "Secondary" then "secondaryEdge" else "primaryEdge"
	local h = Tokens.size.tabHeight
	local inset = Tokens.space.xs
	local selected = math.clamp(props.Selected or 1, 1, count)
	local disabled = props.Disabled == true

	local root = Create.new("Frame", {
		BackgroundColor3 = Theme.color("paper2"),
		BorderSizePixel = 0,
		Size = if props.Width then UDim2.fromOffset(props.Width, h + inset * 2) else UDim2.new(1, 0, 0, h + inset * 2),
	}, {
		Create.pill(),
		Create.stroke("line", Tokens.border.card),
	})
	Common.applyBase(root, props, "Tabs")

	-- Indicator: accent pill with a 4 px edge, slides between tabs.
	local indicator = Create.new("Frame", {
		Name = "Indicator",
		BackgroundColor3 = Theme.color(edge),
		BorderSizePixel = 0,
		Size = UDim2.new(1 / count, -inset * 2, 0, h),
		Position = UDim2.new((selected - 1) / count, inset, 0, inset),
		ZIndex = 2,
		Parent = root,
	}, { Create.pill() })
	Create.new("Frame", {
		Name = "Face",
		BackgroundColor3 = Theme.color(fill),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -Tokens.edge.chip),
		ZIndex = 2,
		Parent = indicator,
	}, { Create.pill() })

	local labels: { TextLabel } = {}
	local buttons: { TextButton } = {}
	local handle: Handle

	local function paint()
		for i, label in labels do
			label.TextColor3 = Theme.color(if i == selected then "white" else "inkSoft")
			local stroke = label:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Enabled = i == selected
			end
		end
	end

	local function selectTab(index: number, silent: boolean?)
		index = math.clamp(index, 1, count)
		if index == selected and not silent then
			return
		end
		selected = index
		Motion.tween(indicator, Tokens.motion.tabSlide, "EnterBack", {
			Position = UDim2.new((index - 1) / count, inset, 0, inset),
		})
		paint()
		if not silent then
			Hooks.sound("tab")
			if props.OnChanged then
				props.OnChanged(index)
			end
		end
	end

	for i, text in props.Items do
		local button = Create.new("TextButton", {
			Name = "Tab" .. i,
			AutoButtonColor = false,
			Text = "",
			BackgroundTransparency = 1,
			Size = UDim2.new(1 / count, 0, 1, 0),
			Position = UDim2.fromScale((i - 1) / count, 0),
			ZIndex = 3,
			Parent = root,
		})
		button.SelectionImageObject = Common.selectionRing(999)
		labels[i] = Create.text({
			Name = "Label",
			Text = text,
			Role = "button",
			SizeName = "body",
			Color = "inkSoft",
			Stroke = edge,
			StrokeThickness = 1,
			XAlign = "Center",
			Size = UDim2.new(1, 0, 1, -Tokens.edge.chip),
			ZIndex = 4,
			Parent = button,
		})
		button.Activated:Connect(function()
			if not disabled then
				selectTab(i)
			end
		end)
		buttons[i] = button
	end
	paint()

	if disabled then
		Common.setDimmed(root, true)
	end
	if props.Parent then
		root.Parent = props.Parent
	end

	handle = {
		select = selectTab,
		getSelected = function()
			return selected
		end,
		setDisabled = function(v: boolean)
			disabled = v
			for _, b in buttons do
				b.Active = not v
			end
			Common.setDimmed(root, v)
		end,
		destroy = function()
			root:Destroy()
		end,
	}
	return root, handle
end

return Tabs
