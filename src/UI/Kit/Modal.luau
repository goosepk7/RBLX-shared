--!strict
--[[
	Modal (§5.3): 55% Ink backdrop, content pops in from scale 0.9 with
	back-out easing. Use through ScreenManager:showModal so the 2-modal cap
	(§5.4) is enforced; Modal.new alone is for the gallery and tests.

		local modal = Kit.Modal.new({ Content = panelRoot, DismissOnBackdrop = true })
		modal.open(area.modalLayer, area.backdropLayer)
]]

local Create = require("../Create")
local Hooks = require("../Hooks")
local Motion = require("../Motion")
local Theme = require("../Theme")
local Tokens = require("../Tokens")

export type Variant = "Center" | "Fullscreen"

export type Props = {
	Content: GuiObject,
	Variant: Variant?,
	DismissOnBackdrop: boolean?,
	OnClosed: (() -> ())?,
	Name: string?,
}

export type Handle = {
	root: Frame,
	-- backdropParent: a full-screen (no insets) layer so the dim covers the
	-- notch bands; SafeArea.backdropLayer. Defaults to `parent`.
	open: (parent: Instance, backdropParent: Instance?) -> (),
	close: () -> (),
	isOpen: () -> boolean,
}

local Modal = {}

Modal.Variants = { "Center", "Fullscreen" } :: { Variant }

function Modal.new(props: Props): Handle
	local root = Create.group({
		Name = props.Name or "Modal",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Visible = false,
	})
	local backdrop = Create.new("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		Selectable = false,
		BackgroundColor3 = Theme.color("ink"),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Parent = root,
	})
	local holder = Create.group({
		Name = "Holder",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if props.Variant == "Fullscreen" then UDim2.fromScale(0.96, 0.92) else UDim2.fromScale(1, 1),
		ZIndex = 51,
		Parent = root,
	})
	local scale = Create.new("UIScale", { Scale = 1, Parent = holder })
	local content = props.Content
	if props.Variant ~= "Fullscreen" then
		content.AnchorPoint = Vector2.new(0.5, 0.5)
		content.Position = UDim2.fromScale(0.5, 0.5)
	else
		content.Size = UDim2.fromScale(1, 1)
	end
	content.Parent = holder

	local opened = false
	-- The backdrop may live in another ScreenGui; it goes when the modal goes.
	root.Destroying:Connect(function()
		backdrop:Destroy()
	end)

	local handle: Handle
	local function close()
		if not opened then
			return
		end
		opened = false
		Hooks.sound("close")
		Motion.exit(backdrop, { BackgroundTransparency = 1 })
		local t = Motion.exit(scale, { Scale = Tokens.motion.modalStartScale })
		t.Completed:Once(function()
			if not opened then
				root.Visible = false
				backdrop.Visible = false
				if props.OnClosed then
					props.OnClosed()
				end
			end
		end)
	end

	local function open(parent: Instance, backdropParent: Instance?)
		backdrop.Parent = backdropParent or root
		backdrop.Visible = true
		root.Parent = parent
		opened = true
		root.Visible = true
		Hooks.sound("open")
		scale.Scale = Tokens.motion.modalStartScale
		backdrop.BackgroundTransparency = 1
		Motion.enter(backdrop, { BackgroundTransparency = Tokens.alpha.backdrop })
		Motion.enter(scale, { Scale = 1 })
	end

	if props.DismissOnBackdrop then
		backdrop.Activated:Connect(close)
	end

	handle = {
		root = root,
		open = open,
		close = close,
		isOpen = function()
			return opened
		end,
	}
	return handle
end

return Modal
