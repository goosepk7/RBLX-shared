--!strict
--[[
	Stat (§5.3): icon + caption label + big stroked number. Used on result
	cards, rebirth before/after, profile panels.
]]

local Common = require("./Common")
local Create = require("../Create")
local Format = require("../Format")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Default" | "Accent" | "Gold"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Label: string,
	Value: number,
	Icon: string?,
	Variant: Variant?,
	Formatter: ((number) -> string)?, -- default Format.compact
	Suffix: string?, -- e.g. " studs" (already localized)
	Width: number?,
}

export type Handle = {
	setValue: (value: number, animate: boolean?) -> (),
	destroy: () -> (),
}

local Stat = {}

Stat.Variants = { "Default", "Accent", "Gold" } :: { Variant }

function Stat.new(props: Props): (Frame, Handle)
	local format = props.Formatter or Format.compact
	local suffix = props.Suffix or ""
	local value = props.Value
	local variant: Variant = props.Variant or "Default"
	local numberColor: Theme.ColorName = if variant == "Accent"
		then "primary"
		elseif variant == "Gold" then "gold"
		else "white"

	local root = Create.group({
		Size = UDim2.fromOffset(props.Width or 180, 72),
	}, {
		Create.list("Horizontal", Tokens.space.sm, "Left", "Center"),
	})
	Common.applyBase(root, props, "Stat")

	if props.Icon then
		Create.new("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Image = props.Icon,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(Tokens.size.iconLg, Tokens.size.iconLg),
			LayoutOrder = 1,
			Parent = root,
		})
	end
	local column = Create.group({
		Name = "Column",
		Size = UDim2.new(1, -(Tokens.size.iconLg + Tokens.space.sm), 1, 0),
		LayoutOrder = 2,
		Parent = root,
	}, { Create.list("Vertical", 0, "Left", "Center") })
	Create.text({
		Name = "Label",
		Text = props.Label,
		Role = "caption",
		SizeName = "caption",
		Color = "inkSoft",
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = 1,
		Parent = column,
	})
	local number = Create.text({
		Name = "Value",
		Text = format(value) .. suffix,
		Role = "number",
		SizeName = "h2",
		Color = numberColor,
		Stroke = "ink",
		StrokeThickness = Tokens.border.numberStroke,
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = 2,
		Parent = column,
	})

	if props.Disabled then
		Common.setDimmed(root, true)
	end
	if props.Parent then
		root.Parent = props.Parent
	end

	local cancel: (() -> ())? = nil
	return root,
		{
			setValue = function(v: number, animate: boolean?)
				if cancel then
					cancel()
				end
				if animate == false then
					number.Text = format(v) .. suffix
				else
					cancel = Motion.countUp(number, value, v, Tokens.motion.countUp, function(n)
						return format(math.floor(n)) .. suffix
					end)
				end
				value = v
			end,
			destroy = function()
				if cancel then
					cancel()
				end
				root:Destroy()
			end,
		}
end

return Stat
