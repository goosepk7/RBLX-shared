--!strict
--[[
	CurrencyPill (§5.3, §5.4): icon + animated number + "+" button that
	opens the shop. Stacked top-left in the HUD (Wins/Height, Cash/Parts).

		local root, pill = Kit.CurrencyPill.new({
			Icon = Assets.get("icon_wins"), Value = profile.wins, OnPlus = openShop,
		})
		pill.setValue(newWins) -- counts up and spawns a NumberPop for gains
]]

local Common = require("./Common")
local Create = require("../Create")
local Format = require("../Format")
local Motion = require("../Motion")
local NumberPop = require("./NumberPop")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Default" | "Gold" | "Accent"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Icon: string,
	Value: number,
	Variant: Variant?,
	Width: number?,
	Formatter: ((number) -> string)?,
	Suffix: string?,
	OnPlus: (() -> ())?, -- nil hides the "+" (e.g. Height, which cannot be bought)
}

export type Handle = {
	setValue: (value: number, pop: boolean?) -> (),
	getValue: () -> number,
	setDisabled: (boolean) -> (),
	setLoading: (boolean) -> (),
	destroy: () -> (),
}

local CurrencyPill = {}

CurrencyPill.Variants = { "Default", "Gold", "Accent" } :: { Variant }

function CurrencyPill.new(props: Props): (Frame, Handle)
	local format = props.Formatter or Format.compact
	local suffix = props.Suffix or ""
	local value = props.Value
	local variant: Variant = props.Variant or "Default"
	local h = Tokens.size.pillHeight
	local edgeSize = Tokens.edge.chip
	local disabled = props.Disabled == true
	local loading = props.Loading == true

	-- The pill body is deliberately not Active: on phones the stacked
	-- top-left pills can reach into the thumbstick zone (Layout.thumbstickZone),
	-- and inactive frames let those touches through to the stick. Only the
	-- compact "+" disc sinks input. Do not turn the whole pill into a button.
	local ef = Common.edgeFace({
		height = h,
		edge = edgeSize,
		radius = nil,
		fill = "paper",
		edgeColor = if variant == "Gold" then "goldEdge" elseif variant == "Accent" then "primaryEdge" else "lineDark",
		border = if variant == "Gold" then "gold" elseif variant == "Accent" then "primary" else "line",
		interactive = false,
	})
	local root = ef.root
	Common.applyBase(root, props, "CurrencyPill")
	root.Size = UDim2.fromOffset(props.Width or 176, h + edgeSize)

	local iconSize = h + 4
	Create.new("ImageLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		Image = props.Icon,
		ScaleType = Enum.ScaleType.Fit,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -8, 0.5, 0),
		Size = UDim2.fromOffset(iconSize, iconSize),
		ZIndex = 4,
		Parent = ef.face,
	})

	-- 48 px disc: still >= 44 px at Layout.MIN_SCALE.
	local plusSize = h - 4
	local rightPad = if props.OnPlus then plusSize + 8 else Tokens.space.md
	local number = Create.text({
		Name = "Value",
		Text = format(value) .. suffix,
		Role = "number",
		SizeName = "number",
		Color = "white",
		Stroke = "ink",
		StrokeThickness = Tokens.border.numberStroke,
		XAlign = "Center",
		Position = UDim2.fromOffset(iconSize - 8, 0),
		Size = UDim2.new(1, -(iconSize - 8) - rightPad, 1, 0),
		ZIndex = 3,
		Parent = ef.face,
	})
	local numberScale = Create.new("UIScale", { Scale = 1, Parent = number })
	local spinner = Common.spinner("inkSoft", 6)
	spinner.Parent = ef.face

	local plusButton: Frame? = nil
	local conns: { RBXScriptConnection } = {}
	if props.OnPlus then
		-- "+" is a mini 3D button.
		local plusFill: Theme.ColorName = if variant == "Gold" then "gold" else "success"
		local plusEdge: Theme.ColorName = if variant == "Gold" then "goldEdge" else "successEdge"
		local plusEf = Common.edgeFace({
			height = plusSize,
			edge = 3,
			radius = nil,
			fill = plusFill,
			edgeColor = plusEdge,
			interactive = true,
		})
		plusEf.root.Name = "Plus"
		plusEf.root.AnchorPoint = Vector2.new(1, 0.5)
		plusEf.root.Position = UDim2.new(1, -2, 0.5, 0)
		plusEf.root.Size = UDim2.fromOffset(plusSize, plusSize + 3)
		plusEf.root.ZIndex = 4
		for i, rot in { 0, 90 } do
			Create.new("Frame", {
				Name = "Bar" .. i,
				BackgroundColor3 = Theme.color("white"),
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(18, 5),
				Rotation = rot,
				ZIndex = 5,
				Parent = plusEf.face,
			}, { Create.pill(), Create.stroke(plusEdge, 1) })
		end
		conns = Common.bindPress(plusEf, 3, {
			isEnabled = function()
				return not disabled
			end,
			onActivated = function()
				local onPlus = props.OnPlus
				if onPlus then
					onPlus()
				end
			end,
			sound = "open",
		})
		plusEf.root.Parent = ef.face
		plusButton = plusEf.root
	end

	local cancel: (() -> ())? = nil
	local function setValue(v: number, pop: boolean?)
		local before = value
		value = v
		if cancel then
			cancel()
		end
		cancel = Motion.countUp(number, before, v, Tokens.motion.countUp, function(n)
			return format(math.floor(n + 0.5)) .. suffix
		end)
		local delta = v - before
		if delta ~= 0 and pop ~= false then
			numberScale.Scale = 1.18
			Motion.tween(numberScale, Tokens.motion.releaseDuration, "Spring", { Scale = 1 })
			NumberPop.spawn(ef.face, delta, {
				Before = before,
				Variant = if variant == "Gold" and delta > 0 then "Gold" else nil,
			})
		end
	end

	local function refresh()
		number.Visible = not loading
		spinner.Visible = loading
		if plusButton then
			plusButton.Visible = not disabled
		end
		Common.setDimmed(root, disabled)
	end
	refresh()
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			setValue = setValue,
			getValue = function()
				return value
			end,
			setDisabled = function(v: boolean)
				disabled = v
				refresh()
			end,
			setLoading = function(v: boolean)
				loading = v
				refresh()
			end,
			destroy = function()
				if cancel then
					cancel()
				end
				for _, c in conns do
					c:Disconnect()
				end
				root:Destroy()
			end,
		}
end

return CurrencyPill
