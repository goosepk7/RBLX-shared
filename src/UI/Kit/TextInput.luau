--!strict
--[[
	TextInput: a single-line text field (Codes, Admin console, search).

	An inset field rather than a pressable one, so it has no 3D edge: Paper-2
	fill and a Line border at rest, Paper fill and an Info border while
	focused, and a Success or Danger border plus a helper line under the
	field for validation results ("Code redeemed", "That code expired").

	Height is the small button height (48), so it sits next to a Small
	button in a row and stays a valid tap target at the smallest UI scale.
	Text is never filtered here; anything shown to other players still goes
	through TextService on the server (§3.4).
]]

local Common = require("./Common")
local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Default" | "Success" | "Danger"

export type Props = {
	Name: string?,
	Disabled: boolean?,
	Loading: boolean?,
	LayoutOrder: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Parent: Instance?,
	Placeholder: string, -- already localized
	Text: string?,
	Variant: Variant?,
	Message: string?, -- helper line under the field (already localized)
	Icon: string?, -- asset name shown at the left edge
	Width: number?, -- px at reference scale; nil fills the parent's width
	MaxLength: number?, -- characters (UTF-8 codepoints); default 64
	-- Rewrites typed text before it is shown, e.g. string.upper for codes.
	-- The result is clamped to MaxLength again.
	Transform: ((string) -> string)?,
	OnChanged: ((string) -> ())?,
	-- Enter / Done on the on-screen keyboard. Not called while Disabled or Loading.
	OnSubmit: ((string) -> ())?,
}

export type Handle = {
	getText: () -> string,
	setText: (string) -> (),
	setVariant: (Variant, string?) -> (),
	setDisabled: (boolean) -> (),
	setLoading: (boolean) -> (),
	focus: () -> (),
	release: () -> (),
	box: TextBox,
	destroy: () -> (),
}

local TextInput = {}

TextInput.Variants = { "Default", "Success", "Danger" } :: { Variant }

local BORDER: { [Variant]: Theme.ColorName } = {
	Default = "line",
	Success = "successEdge",
	Danger = "dangerEdge",
}

local MESSAGE: { [Variant]: Theme.ColorName } = {
	Default = "inkSoft",
	Success = "successEdge",
	Danger = "dangerEdge",
}

local DEFAULT_MAX_LENGTH = 64
local FOCUS_BORDER = 3

-- utf8.codes errors on invalid UTF-8; keep the longest valid prefix.
local function validPrefix(text: string): string
	local length, bad = utf8.len(text)
	if length ~= nil then
		return text
	end
	return string.sub(text, 1, (bad :: number) - 1)
end

--- Cuts `text` to at most `max` UTF-8 codepoints. Invalid UTF-8 (pasted
--- bytes) is dropped from the first bad byte on.
function TextInput.clamp(text: string, max: number): string
	local valid = validPrefix(text)
	local count = 0
	for position in utf8.codes(valid) do
		count += 1
		if count > max then
			return string.sub(valid, 1, position - 1)
		end
	end
	return valid
end

function TextInput.new(props: Props): (Frame, Handle)
	local height = Tokens.size.buttonHeightSmall
	local maxLength = props.MaxLength or DEFAULT_MAX_LENGTH
	local variant: Variant = props.Variant or "Default"
	local disabled = props.Disabled == true
	local loading = props.Loading == true
	local focused = false

	local root = Create.group({
		Size = if props.Width then UDim2.fromOffset(props.Width, 0) else UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		Create.list("Vertical", Tokens.space.xs),
	})
	Common.applyBase(root, props, "TextInput")

	local field = Create.new("Frame", {
		Name = "Field",
		BackgroundColor3 = Theme.color("paper2"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = 1,
		Parent = root,
	}, {
		Create.corner(Tokens.radius.button),
	}) :: Frame
	local border = Create.stroke("line", Tokens.border.card) :: UIStroke
	border.Parent = field

	local inset = Tokens.space.md
	local iconSize = Tokens.size.iconSm
	if props.Icon then
		Common.icon(props.Icon :: string, {
			Name = "Icon",
			Size = UDim2.fromOffset(iconSize, iconSize),
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, inset, 0.5, 0),
			ZIndex = 2,
			Parent = field,
		})
	end
	local left = inset + (if props.Icon then iconSize + Tokens.space.sm else 0)
	local spinnerWidth = 6 * 3 + 8

	local box = Create.new("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		MultiLine = false,
		Text = TextInput.clamp(props.Text or "", maxLength),
		PlaceholderText = props.Placeholder,
		PlaceholderColor3 = Theme.color("inkSoft"),
		TextColor3 = Theme.color("ink"),
		FontFace = Theme.font("value"),
		TextSize = Theme.textSize("button"),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(left, 0),
		Size = UDim2.new(1, -(left + inset + spinnerWidth), 1, 0),
		Selectable = true,
		ZIndex = 2,
		Parent = field,
	}) :: TextBox
	box.SelectionImageObject = Common.selectionRing(Tokens.radius.button)

	local spinner = Common.spinner("inkSoft", 6)
	spinner.AnchorPoint = Vector2.new(1, 0.5)
	spinner.Position = UDim2.new(1, -inset, 0.5, 0)
	spinner.Parent = field

	local message = Create.text({
		Name = "Message",
		Text = "",
		Role = "caption",
		SizeName = "caption",
		Color = "inkSoft",
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = 2,
		Visible = false,
		Parent = root,
	})
	Create.padding(0, 0, 0, Tokens.space.xs).Parent = message

	local function paint()
		local borderColor: Theme.ColorName = if variant ~= "Default"
			then BORDER[variant]
			elseif focused then "info"
			else "line"
		Motion.tween(border, Tokens.motion.fastDuration, "Enter", {
			Color = Theme.color(borderColor),
			Thickness = if focused or variant ~= "Default" then FOCUS_BORDER else Tokens.border.card,
		})
		field.BackgroundColor3 = Theme.color(if focused then "paper" else "paper2")
		message.TextColor3 = Theme.color(MESSAGE[variant])
	end

	local function setVariant(v: Variant, text: string?)
		variant = v
		message.Text = text or ""
		message.Visible = text ~= nil and text ~= ""
		paint()
	end

	local function editable(): boolean
		return not disabled and not loading
	end

	local function applyEditable()
		box.TextEditable = editable()
		box.Active = editable()
		if not editable() and box:IsFocused() then
			box:ReleaseFocus(false)
		end
	end

	local conns: { RBXScriptConnection } = {}
	local writing = false
	table.insert(
		conns,
		box:GetPropertyChangedSignal("Text"):Connect(function()
			if writing then
				return
			end
			local raw = box.Text
			local text = TextInput.clamp(raw, maxLength)
			if props.Transform then
				text = TextInput.clamp(props.Transform(text), maxLength)
			end
			if text ~= raw then
				writing = true
				box.Text = text
				box.CursorPosition = #text + 1
				writing = false
			end
			if variant ~= "Default" then
				-- Typing again clears a stale validation result.
				setVariant("Default", nil)
			end
			if props.OnChanged then
				props.OnChanged(text)
			end
		end)
	)
	table.insert(
		conns,
		box.Focused:Connect(function()
			focused = true
			Hooks.sound("tab")
			paint()
		end)
	)
	table.insert(
		conns,
		box.FocusLost:Connect(function(enterPressed: boolean)
			focused = false
			paint()
			if enterPressed and editable() and props.OnSubmit then
				props.OnSubmit(box.Text)
			end
		end)
	)

	local function setDisabled(v: boolean)
		disabled = v
		applyEditable()
		Common.setDimmed(root, v)
	end

	local function setLoading(v: boolean)
		loading = v
		spinner.Visible = v
		applyEditable()
	end

	setVariant(variant, props.Message)
	setLoading(loading)
	setDisabled(disabled)
	if props.Parent then
		root.Parent = props.Parent
	end

	return root,
		{
			getText = function()
				return box.Text
			end,
			setText = function(text: string)
				box.Text = text -- the Text handler clamps and transforms it
			end,
			setVariant = setVariant,
			setDisabled = setDisabled,
			setLoading = setLoading,
			focus = function()
				if editable() then
					box:CaptureFocus()
				end
			end,
			release = function()
				box:ReleaseFocus(false)
			end,
			box = box,
			destroy = function()
				for _, c in conns do
					c:Disconnect()
				end
				root:Destroy()
			end,
		}
end

return TextInput
