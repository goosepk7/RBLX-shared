--!strict
--[[
	Building blocks the shared screens share: the Env every screen gets, themed text that sizes
	to its content, stacks, item tiles, and the call-a-remote-then-toast pattern. Everything
	visual comes from the UI kit; nothing here picks a color or font of its own.
]]

local Button = require("../UI/Kit/Button")
local Common = require("../UI/Kit/Common")
local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Loc = require("../Loc")
local Models = require("./Models")
local Panel = require("../UI/Kit/Panel")
local Roblox = require("../Util/Roblox")
local SafeArea = require("../UI/SafeArea")
local ScreenManager = require("../UI/ScreenManager")
local Theme = require("../UI/Theme")
local Toast = require("../UI/Kit/Toast")
local Tokens = require("../UI/Tokens")

export type Env = {
	loc: Loc.Loc,
	manager: ScreenManager.ScreenManager,
	area: SafeArea.SafeArea,
	catalog: Models.Catalog,
	-- The local player's UserId (pinned leaderboard row, "you" in announcements).
	userId: number,
	now: () -> number,
	-- Client remotes for a module ("Shop", "Codes", ...): Remotes.client(module, context).
	remotes: (module: string) -> any,
	-- Current balances, to grey out what the player can't afford yet.
	balances: (() -> { [string]: number })?,
	-- Board defs in tab order (the same list the server's Leaderboards.new got).
	boards: { any }?,
	-- Event id -> EventDef and badge key -> BadgeDef, for names and icons.
	events: { [string]: any }?,
	badges: { [string]: any }?,
}

export type TextOptions = { size: Theme.TextSize?, role: Theme.FontRole?, color: Theme.ColorName?, align: string? }
export type PanelOptions = { variant: Panel.Variant?, footer: boolean?, size: UDim2? }

local Parts = {}

-- Runs `fn` in its own thread (remote calls yield; button handlers must not).
function Parts.spawn(fn: () -> ())
	local taskLib = Roblox.task()
	if taskLib then
		taskLib.spawn(fn)
	else
		fn()
	end
end

-- A LayoutOrder counter: `local order = Parts.counter(); x.LayoutOrder = order()`.
function Parts.counter(): () -> number
	local n = 0
	return function()
		n += 1
		return n
	end
end

-- Themed text that grows to fit (wrapped) inside a fixed width.
function Parts.text(parent: Instance, order: number, text: string, options: TextOptions?): TextLabel
	local o: TextOptions = options or {}
	local label = Create.text({
		Text = text,
		Role = o.role or "body",
		SizeName = o.size or "body",
		Color = o.color or "ink",
		XAlign = (o.align or "Left") :: any,
		Wrapped = true,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	})
	label.Parent = parent
	return label
end

-- A frame that lays its children out in a list and grows to fit them.
function Parts.stack(parent: Instance, order: number, direction: ("Vertical" | "Horizontal")?, gap: number?): Frame
	local vertical = direction ~= "Horizontal"
	local frame = Create.group({
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	}, {
		Create.list(if vertical then "Vertical" else "Horizontal", gap or Tokens.space.sm, "Left", "Center"),
	})
	frame.Parent = parent
	return frame
end

-- Empties a container, keeping its layout and padding objects.
function Parts.clear(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function Parts.toast(env: Env, text: string, variant: Toast.Variant?, title: string?, icon: string?)
	env.area.toasts.show({ Text = text, Variant = variant or "Info", Title = title, Icon = icon })
end

--[[
	Invokes `remote` with `payload` off-thread and hands the answer to `done` as Models.answer
	gives it: (true, value) or (false, localized message). `button` shows loading meanwhile.
]]
function Parts.call(
	env: Env,
	area: string,
	remote: any,
	payload: any,
	button: Button.Handle?,
	done: (ok: boolean, value: any) -> ()
)
	if button then
		button.setLoading(true)
	end
	Parts.spawn(function()
		local result = remote:invokeAsync(payload)
		if button then
			button.setLoading(false)
		end
		local ok, value = Models.answer(env.loc, area, result)
		done(ok, value)
	end)
end

-- A panel sized for the screen layer, centered, with the close button wired to the context.
function Parts.panel(
	ctx: ScreenManager.ScreenContext,
	title: string,
	icon: string?,
	options: PanelOptions?
): (Frame, Panel.Handle)
	local o: PanelOptions = options or {}
	local root, panel = Kit.Panel.new({
		Title = title,
		Icon = icon,
		Variant = o.variant,
		Scroll = true,
		FooterHeight = if o.footer then nil else 0,
		Size = o.size or UDim2.fromScale(0.92, 0.88),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		OnClose = ctx.close,
	})
	Create.new("UISizeConstraint", { MaxSize = Vector2.new(760, 560), Parent = root })
	return root, panel
end

--[[
	A shop/reward tile: icon, title, subtitle, price and one action button. `onAction` runs when
	the button is pressed; `onOdds` adds an Odds button (crates).
]]
function Parts.tile(
	parent: Instance,
	order: number,
	card: Models.ShopCard,
	onAction: ((card: Models.ShopCard, button: Button.Handle) -> ())?,
	onOdds: ((card: Models.ShopCard) -> ())?,
	oddsLabel: string?
): Frame
	local root, handle = Kit.Card.new({
		Variant = if card.kind == "pass" or card.kind == "product" then "Elevated" else "Plain",
		Size = UDim2.fromScale(1, 1),
		Padding = Tokens.space.md,
		LayoutOrder = order,
	})
	local content = handle.content
	Create.list("Vertical", Tokens.space.xs, "Center", "Top").Parent = content
	local next = Parts.counter()
	if card.icon then
		Common.icon(card.icon, {
			Size = UDim2.fromOffset(Tokens.size.iconLg + 16, Tokens.size.iconLg + 16),
			LayoutOrder = next(),
			Parent = content,
		}, 64)
	end
	Parts.text(content, next(), card.title, { size = "h3", role = "display", align = "Center" })
	if card.subtitle and card.subtitle ~= "" then
		Parts.text(content, next(), card.subtitle, { size = "caption", color = "inkSoft", align = "Center" })
	end
	if card.price then
		local row = Parts.stack(content, next(), "Horizontal", Tokens.space.xs)
		local layout = row:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		end
		if card.priceIcon then
			Common.icon(card.priceIcon, {
				Size = UDim2.fromOffset(Tokens.size.iconSm, Tokens.size.iconSm),
				LayoutOrder = 1,
				Parent = row,
			}, 64)
		end
		local price = Create.text({
			Text = card.price,
			Role = "number",
			SizeName = "body",
			Size = UDim2.fromScale(0, 0),
			AutomaticSize = Enum.AutomaticSize.XY,
			LayoutOrder = 2,
		})
		price.Parent = row
	end
	if card.reason then
		Parts.text(content, next(), card.reason, { size = "caption", color = "danger", align = "Center" })
	end
	-- The handler needs the button's own handle (to show loading), which exists only after new().
	local actionHandle: Button.Handle? = nil
	local _, built = Kit.Button.new({
		Text = card.actionLabel,
		Variant = card.variant,
		Size = "Small",
		Fill = true,
		Disabled = card.disabled or card.action == "none",
		LayoutOrder = next(),
		Parent = content,
		OnActivated = function()
			if onAction and actionHandle then
				onAction(card, actionHandle)
			end
		end,
	})
	actionHandle = built
	if card.odds and onOdds then
		Kit.Button.new({
			Text = oddsLabel or "",
			Variant = "Ghost",
			Size = "Small",
			Fill = true,
			LayoutOrder = next(),
			Parent = content,
			OnActivated = function()
				onOdds(card)
			end,
		})
	end
	root.Parent = parent
	return root
end

return Parts
