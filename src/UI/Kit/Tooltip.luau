--!strict
--[[
	Tooltip (§5.3): an Ink bubble with white text above a target. Shows on
	mouse hover (PC), long-press 0.4 s (touch), or selection (console).

		local tip = Tooltip.attach(button, Loc.t("hud.shop"))
		tip.destroy()

	Tooltip.new builds a standalone bubble (used by the gallery and by
	coachmarks).
]]

local Create = require("../Create")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Ink" | "Accent"

export type Props = {
	Text: string,
	Variant: Variant?,
	Name: string?,
}

export type Handle = {
	setText: (string) -> (),
	show: () -> (),
	hide: () -> (),
	destroy: () -> (),
}

local Tooltip = {}

Tooltip.Variants = { "Ink", "Accent" } :: { Variant }
Tooltip.LONG_PRESS = 0.4

function Tooltip.new(props: Props): (Frame, TextLabel)
	local fill: Theme.ColorName = if props.Variant == "Accent" then "primaryEdge" else "ink"
	local bubble = Create.new("Frame", {
		Name = props.Name or "Tooltip",
		BackgroundColor3 = Theme.color(fill),
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 32),
		ZIndex = 20,
	}, {
		Create.corner(Tokens.radius.chip),
		Create.padding(Tokens.space.xs, Tokens.space.md),
	})
	local label = Create.text({
		Name = "Text",
		Text = props.Text,
		Role = "button",
		SizeName = "caption",
		Color = "white",
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 24),
		ZIndex = 21,
		Parent = bubble,
	})
	-- Pointer nub under the bubble.
	Create.new("Frame", {
		Name = "Nub",
		BackgroundColor3 = Theme.color(fill),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(10, 10),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, 0),
		Rotation = 45,
		ZIndex = 20,
		Parent = bubble,
	})
	return bubble, label
end

local function screenGuiOf(inst: Instance): LayerCollector?
	return inst:FindFirstAncestorWhichIsA("LayerCollector")
end

function Tooltip.attach(target: GuiObject, text: string): Handle
	local bubble, label = Tooltip.new({ Text = text })
	bubble.Visible = false
	bubble.AnchorPoint = Vector2.new(0.5, 1)
	local scale = Create.new("UIScale", { Scale = 1, Parent = bubble })
	local conns: { RBXScriptConnection } = {}
	local holdToken = 0

	local function show()
		local gui = screenGuiOf(target)
		if gui == nil then
			return
		end
		bubble.Parent = gui
		local pos, size = target.AbsolutePosition - gui.AbsolutePosition, target.AbsoluteSize
		bubble.Position = UDim2.fromOffset(pos.X + size.X / 2, pos.Y - 10)
		bubble.Visible = true
		scale.Scale = 0.85
		Motion.tween(scale, Tokens.motion.fastDuration, "EnterBack", { Scale = 1 })
	end

	local function hide()
		holdToken += 1
		bubble.Visible = false
	end

	table.insert(conns, target.MouseEnter:Connect(show))
	table.insert(conns, target.MouseLeave:Connect(hide))
	table.insert(conns, target.SelectionGained:Connect(show))
	table.insert(conns, target.SelectionLost:Connect(hide))
	table.insert(
		conns,
		target.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch then
				holdToken += 1
				local token = holdToken
				task.delay(Tooltip.LONG_PRESS, function()
					if token == holdToken then
						show()
					end
				end)
			end
		end)
	)
	table.insert(
		conns,
		target.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch then
				hide()
			end
		end)
	)

	return {
		setText = function(t: string)
			label.Text = t
		end,
		show = show,
		hide = hide,
		destroy = function()
			for _, c in conns do
				c:Disconnect()
			end
			bubble:Destroy()
		end,
	}
end

return Tooltip
