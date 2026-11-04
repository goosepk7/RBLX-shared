--!strict
--[[
	Confirm (§5.3): a Modal + Panel with a message and two actions. The
	confirm button is the visible primary action; Destructive turns it into
	the big red confirm used by Rebirth (§5.5).

		Kit.Confirm.show(screenGui, {
			Title = Loc.t("rebirth.title"), Message = Loc.t("rebirth.body"),
			ConfirmText = Loc.t("rebirth.go"), CancelText = Loc.t("common.cancel"),
			Variant = "Destructive", OnResult = function(ok) ... end,
		})
]]

local Button = require("./Button")
local Create = require("../Create")
local Modal = require("./Modal")
local Panel = require("./Panel")

export type Variant = "Default" | "Destructive" | "Purchase"

export type Props = {
	Title: string,
	Message: string,
	ConfirmText: string,
	CancelText: string,
	Variant: Variant?,
	Icon: string?,
	OnResult: (confirmed: boolean) -> (),
}

local Confirm = {}

Confirm.Variants = { "Default", "Destructive", "Purchase" } :: { Variant }

local CONFIRM_BUTTON: { [Variant]: Button.Variant } = {
	Default = "Primary",
	Destructive = "Danger",
	Purchase = "Gold",
}

local PANEL_HEADER: { [Variant]: Panel.Variant } = {
	Default = "Primary",
	Destructive = "Danger",
	Purchase = "Gold",
}

--- Builds the panel without a modal (gallery uses this directly).
function Confirm.build(props: Props, onChoice: (boolean) -> ()): Frame
	local variant: Variant = props.Variant or "Default"
	local root, panel = Panel.new({
		Title = props.Title,
		Icon = props.Icon,
		Variant = PANEL_HEADER[variant],
		Size = UDim2.fromOffset(440, 280),
		OnClose = function()
			onChoice(false)
		end,
	})
	Create.text({
		Name = "Message",
		Text = props.Message,
		Role = "body",
		SizeName = "body",
		Color = "ink",
		Wrapped = true,
		XAlign = "Center",
		Size = UDim2.fromScale(1, 1),
		Parent = panel.body,
	})
	Button.new({
		Text = props.CancelText,
		Variant = "Secondary",
		Width = 160,
		LayoutOrder = 1,
		OnActivated = function()
			onChoice(false)
		end,
		Parent = panel.footer,
	})
	Button.new({
		Name = "ConfirmButton",
		Text = props.ConfirmText,
		Variant = CONFIRM_BUTTON[variant],
		Width = 200,
		LayoutOrder = 2,
		OnActivated = function()
			onChoice(true)
		end,
		Parent = panel.footer,
	})
	return root
end

function Confirm.show(parent: Instance, props: Props): Modal.Handle
	local modal: Modal.Handle
	local answered = false
	local content = Confirm.build(props, function(ok: boolean)
		if answered then
			return
		end
		answered = true
		modal.close()
		props.OnResult(ok)
	end)
	modal = Modal.new({
		Name = "Confirm",
		Content = content,
		DismissOnBackdrop = false,
		OnClosed = function()
			modal.root:Destroy()
		end,
	})
	modal.open(parent)
	return modal
end

return Confirm
