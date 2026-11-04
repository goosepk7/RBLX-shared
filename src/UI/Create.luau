--!strict
--[[
	Tiny declarative Instance builder plus the styling primitives every kit
	component uses (corners, strokes, padding, themed text). Keeping these in
	one place is what stops one-off styling from creeping into game code.
]]

local Theme = require("./Theme")
local Tokens = require("./Tokens")

type Props = { [string]: any }

local Create = {}

--- Create.new("Frame", { Size = ..., Name = "Card" }, { child1, Named = child2 })
function Create.new(className: string, props: Props?, children: any?): any
	local inst = Instance.new(className :: any)
	local parent: Instance? = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				(inst :: any)[key] = value
			end
		end
	end
	if children then
		for key, child in children do
			if type(key) == "string" then
				child.Name = key
			end
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function Create.corner(radius: number): Instance
	return Create.new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

function Create.pill(): Instance
	return Create.new("UICorner", { CornerRadius = UDim.new(1, 0) })
end

function Create.stroke(colorName: Theme.ColorName, thickness: number, transparency: number?): Instance
	return Create.new("UIStroke", {
		Color = Theme.color(colorName),
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

--- Text outline (UIStroke in Contextual mode on a TextLabel strokes the glyphs).
function Create.textStroke(colorName: Theme.ColorName, thickness: number?, transparency: number?): Instance
	return Create.new("UIStroke", {
		Color = Theme.color(colorName),
		Thickness = thickness or Tokens.border.numberStroke,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

function Create.padding(top: number, right: number?, bottom: number?, left: number?): Instance
	local r = right or top
	return Create.new("UIPadding", {
		PaddingTop = UDim.new(0, top),
		PaddingRight = UDim.new(0, r),
		PaddingBottom = UDim.new(0, bottom or top),
		PaddingLeft = UDim.new(0, left or r),
	})
end

function Create.list(direction: "Horizontal" | "Vertical", gap: number, hAlign: string?, vAlign: string?): Instance
	return Create.new("UIListLayout", {
		FillDirection = (Enum.FillDirection :: any)[direction],
		Padding = UDim.new(0, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = (Enum.HorizontalAlignment :: any)[hAlign or "Left"],
		VerticalAlignment = (Enum.VerticalAlignment :: any)[vAlign or "Top"],
	})
end

--- A transparent container frame.
function Create.group(props: Props?, children: any?): Frame
	local base: Props = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	}
	if props then
		for k, v in props do
			base[k] = v
		end
	end
	return Create.new("Frame", base, children)
end

export type TextProps = {
	Text: string,
	Role: Theme.FontRole?,
	SizeName: Theme.TextSize?,
	Color: Theme.ColorName?,
	Stroke: Theme.ColorName?,
	StrokeThickness: number?,
	XAlign: "Left" | "Center" | "Right" | nil,
	YAlign: "Top" | "Center" | "Bottom" | nil,
	Wrapped: boolean?,
	[string]: any,
}

local TEXT_KEYS = {
	Text = true,
	Role = true,
	SizeName = true,
	Color = true,
	Stroke = true,
	StrokeThickness = true,
	XAlign = true,
	YAlign = true,
	Wrapped = true,
}

--- Themed TextLabel. Always uses Theme fonts, never the legacy Font enum.
function Create.text(props: TextProps): TextLabel
	local role: Theme.FontRole = props.Role or "body"
	local label = Create.new("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = props.Text,
		FontFace = Theme.font(role),
		TextSize = Theme.textSize(props.SizeName or "body"),
		TextColor3 = Theme.color(props.Color or "ink"),
		TextXAlignment = (Enum.TextXAlignment :: any)[props.XAlign or "Left"],
		TextYAlignment = (Enum.TextYAlignment :: any)[props.YAlign or "Center"],
		TextWrapped = props.Wrapped == true,
		TextTruncate = if props.Wrapped then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
		RichText = false,
		Size = UDim2.fromScale(1, 1),
	})
	for key, value in props do
		if not TEXT_KEYS[key] then
			(label :: any)[key] = value
		end
	end
	if props.Stroke then
		Create.textStroke(props.Stroke, props.StrokeThickness).Parent = label
	end
	return label
end

return Create
