--!strict
--[[
	Banner (§5.3, §5.4): server-wide announcement strip, top-center. Slides
	down, holds, auto-dismisses; queued so two announcements never overlap.

		local lane = Kit.Banner.lane(screenGui) -- SafeArea creates one for you
		lane.show({ Text = "FLASH FLOOD IN 10s!", Variant = "Warning", Icon = Assets.get("icon_event") })
]]

local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Primary" | "Warning" | "Danger" | "Success" | "Info" | "Gold"

export type Props = {
	Text: string,
	Variant: Variant?,
	Icon: string?,
	Duration: number?,
}

export type Lane = {
	root: Frame,
	show: (Props) -> (),
	clear: () -> (),
}

local Banner = {}

Banner.Variants = { "Primary", "Warning", "Danger", "Success", "Info", "Gold" } :: { Variant }
Banner.HEIGHT = 52
Banner.MAX_QUEUE = 4

local COLORS: { [Variant]: { Theme.ColorName } } = {
	Primary = { "primary", "primaryEdge" },
	Warning = { "warning", "warningEdge" },
	Danger = { "danger", "dangerEdge" },
	Success = { "success", "successEdge" },
	Info = { "info", "infoEdge" },
	Gold = { "gold", "goldEdge" },
}

local LIGHT: { [Variant]: boolean } = { Warning = true, Gold = true }

function Banner.build(props: Props): Frame
	local variant: Variant = props.Variant or "Primary"
	local c = COLORS[variant]
	local light = LIGHT[variant] == true
	local edgeSize = Tokens.edge.chip
	local strip = Create.group({
		Name = "Banner",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, Banner.HEIGHT + edgeSize),
	})
	Create.new("Frame", {
		Name = "Edge",
		BackgroundColor3 = Theme.color(c[2]),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, edgeSize),
		Size = UDim2.new(1, 0, 0, Banner.HEIGHT),
		Parent = strip,
	}, { Create.pill() })
	local face = Create.new("Frame", {
		Name = "Face",
		BackgroundColor3 = Theme.color("white"),
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, Banner.HEIGHT),
		ZIndex = 2,
		Parent = strip,
	}, {
		Create.pill(),
		Create.new("UIGradient", {
			Color = ColorSequence.new(Theme.color(c[1]), Theme.color(c[2])),
			Rotation = 90,
		}),
		Create.padding(0, Tokens.space.xl),
		Create.list("Horizontal", Tokens.space.sm, "Center", "Center"),
	})
	if props.Icon then
		Create.new("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Image = props.Icon,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(36, 36),
			LayoutOrder = 1,
			ZIndex = 3,
			Parent = face,
		})
	end
	Create.text({
		Name = "Text",
		Text = props.Text,
		Role = "display",
		SizeName = "h3",
		Color = if light then "ink" else "white",
		Stroke = if light then nil else c[2],
		StrokeThickness = 2,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = 2,
		ZIndex = 3,
		Parent = face,
	})
	return strip
end

function Banner.lane(parent: Instance): Lane
	local root = Create.group({
		Name = "BannerLane",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, Tokens.space.sm),
		Size = UDim2.new(0.6, 0, 0, Banner.HEIGHT + Tokens.edge.chip),
		ClipsDescendants = false,
		ZIndex = 75,
		Parent = parent,
	})
	local queue: { Props } = {}
	local busy = false

	local function nextBanner()
		local props = table.remove(queue, 1)
		if props == nil then
			busy = false
			return
		end
		busy = true
		local strip = Banner.build(props)
		strip.AnchorPoint = Vector2.new(0.5, 0)
		strip.Position = UDim2.new(0.5, 0, 0, -(Banner.HEIGHT + 24))
		strip.Parent = root
		Hooks.sound("open")
		Motion.enter(strip, { Position = UDim2.new(0.5, 0, 0, 0) })
		task.delay(props.Duration or Tokens.motion.bannerHold, function()
			if strip.Parent == nil then
				nextBanner()
				return
			end
			Motion.exit(strip, { Position = UDim2.new(0.5, 0, 0, -(Banner.HEIGHT + 24)) }).Completed:Once(function()
				strip:Destroy()
				nextBanner()
			end)
		end)
	end

	return {
		root = root,
		show = function(props: Props)
			if #queue >= Banner.MAX_QUEUE then
				table.remove(queue, 1)
			end
			table.insert(queue, props)
			if not busy then
				nextBanner()
			end
		end,
		clear = function()
			table.clear(queue)
			root:ClearAllChildren()
		end,
	}
end

return Banner
