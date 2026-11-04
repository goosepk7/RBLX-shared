--!strict
--[[
	Toast (§5.3): short confirmation card (code redeemed, badge earned,
	purchase granted). Toasts stack in a lane under the banner lane,
	slide/pop in, and auto-dismiss.

		local lane = Kit.Toast.lane(screenGui) -- SafeArea creates one for you
		lane.show({ Text = Loc.t("codes.ok"), Variant = "Success", Icon = Assets.get("icon_check") })
]]

local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Success" | "Danger" | "Info" | "Warning" | "Gold" | "Badge"

export type Props = {
	Text: string,
	Title: string?, -- bold first line (badge/milestone toasts)
	Variant: Variant?,
	Icon: string?,
	Duration: number?,
}

export type Lane = {
	root: Frame,
	show: (Props) -> Frame,
	clear: () -> (),
}

local Toast = {}

Toast.Variants = { "Success", "Danger", "Info", "Warning", "Gold", "Badge" } :: { Variant }
Toast.MAX_VISIBLE = 3

local ACCENT: { [Variant]: { Theme.ColorName } } = {
	Success = { "success", "successEdge" },
	Danger = { "danger", "dangerEdge" },
	Info = { "info", "infoEdge" },
	Warning = { "warning", "warningEdge" },
	Gold = { "gold", "goldEdge" },
	Badge = { "secondary", "secondaryEdge" },
}

--- Builds a toast card (no animation); used by lanes and the gallery.
function Toast.build(props: Props): Frame
	local variant: Variant = props.Variant or "Info"
	local accent = ACCENT[variant]
	local edgeSize = Tokens.edge.chip
	local card = Create.group({
		Name = "Toast",
		Size = UDim2.fromOffset(340, 64 + edgeSize),
	})
	Create.new("Frame", {
		Name = "Edge",
		BackgroundColor3 = Theme.color(accent[2]),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, edgeSize),
		Size = UDim2.new(1, 0, 1, -edgeSize),
		Parent = card,
	}, { Create.corner(Tokens.radius.card) })
	local face = Create.new("Frame", {
		Name = "Face",
		BackgroundColor3 = Theme.color("paper"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -edgeSize),
		ZIndex = 2,
		Parent = card,
	}, {
		Create.corner(Tokens.radius.card),
		Create.stroke(accent[1], Tokens.border.card),
		Create.padding(0, Tokens.space.md),
		Create.list("Horizontal", Tokens.space.md, "Left", "Center"),
	})
	-- Accent disc behind the icon so the toast reads at a glance.
	local disc = Create.new("Frame", {
		Name = "Disc",
		BackgroundColor3 = Theme.color(accent[1]),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(44, 44),
		LayoutOrder = 1,
		ZIndex = 2,
		Parent = face,
	}, { Create.pill(), Create.stroke(accent[2], 2) })
	if props.Icon then
		Create.new("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Image = props.Icon,
			ScaleType = Enum.ScaleType.Fit,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(32, 32),
			ZIndex = 3,
			Parent = disc,
		})
	end
	local column = Create.group({
		Name = "Text",
		Size = UDim2.new(1, -56, 1, 0),
		LayoutOrder = 2,
		ZIndex = 2,
		Parent = face,
	}, { Create.list("Vertical", 0, "Left", "Center") })
	if props.Title then
		Create.text({
			Name = "Title",
			Text = props.Title,
			Role = "display",
			SizeName = "h3",
			Color = "ink",
			Size = UDim2.new(1, 0, 0, 24),
			ZIndex = 2,
			Parent = column,
		})
	end
	Create.text({
		Name = "Body",
		Text = props.Text,
		Role = if props.Title then "body" else "button",
		SizeName = "body",
		Color = if props.Title then "inkSoft" else "ink",
		Size = UDim2.new(1, 0, 0, 22),
		ZIndex = 2,
		Parent = column,
	})
	return card
end

function Toast.lane(parent: Instance): Lane
	local root = Create.group({
		Name = "ToastLane",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 72), -- under the banner lane
		Size = UDim2.new(0, 360, 1, -72),
		ZIndex = 70,
		Parent = parent,
	}, { Create.list("Vertical", Tokens.space.sm, "Center", "Top") })

	local order = 0
	local lane: Lane
	local function dismiss(card: Frame)
		if card:GetAttribute("Leaving") then
			return
		end
		card:SetAttribute("Leaving", true)
		local scale = card:FindFirstChildOfClass("UIScale")
		if scale then
			Motion.exit(scale, { Scale = 0.6 })
		end
		task.delay(Tokens.motion.exitDuration, function()
			card:Destroy()
		end)
	end

	lane = {
		root = root,
		show = function(props: Props): Frame
			local live: { Frame } = {}
			for _, child in root:GetChildren() do
				if child:IsA("Frame") and not child:GetAttribute("Leaving") then
					table.insert(live, child :: Frame)
				end
			end
			table.sort(live, function(a, b)
				return a.LayoutOrder < b.LayoutOrder
			end)
			while #live >= Toast.MAX_VISIBLE do
				dismiss(table.remove(live, 1) :: Frame)
			end
			order += 1
			local card = Toast.build(props)
			card.LayoutOrder = order
			local scale = Create.new("UIScale", { Scale = 0.6, Parent = card })
			card.Parent = root
			Motion.enter(scale, { Scale = 1 })
			Hooks.sound(if props.Variant == "Danger" then "fail" else "toast")
			task.delay(props.Duration or Tokens.motion.toastHold, function()
				if card.Parent then
					dismiss(card)
				end
			end)
			return card
		end,
		clear = function()
			for _, child in root:GetChildren() do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end
		end,
	}
	return lane
end

return Toast
