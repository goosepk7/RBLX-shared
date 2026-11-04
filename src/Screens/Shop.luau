--!strict
--[[
	Shop screen (brief §5.5): tabs Boosts, Cosmetics and Passes, a featured card on top, crate
	odds one tap away. Opens on `params.tab` ("boosts" | "cosmetics" | "passes"). Robux buys go
	through Screens.Purchase (the prompt wrapper), currency buys and equips through the Shop
	remotes; the screen redraws from every State push, so the server's answer is what shows.
]]

local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Models = require("./Models")
local Parts = require("./Parts")
local Purchase = require("./Purchase")
local ScreenManager = require("../UI/ScreenManager")
local Tokens = require("../UI/Tokens")

local ShopScreen = {}

function ShopScreen.build(env: Parts.Env, ctx: ScreenManager.ScreenContext): ScreenManager.Screen
	local loc = env.loc
	local remotes = env.remotes("Shop")
	local params = ctx.params or {}
	local root, panel = Parts.panel(ctx, loc:t("shop.title"), "icon_shop", { variant = "Gold" })
	local body = panel.body

	local selected = math.max(1, table.find(Models.SHOP_TABS, params.tab) or 1)
	local snapshot: any = nil
	local tabsFrame: Frame
	local content = Create.group(
		{ Name = "Content", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 },
		{
			Create.list("Vertical", Tokens.space.md, "Center", "Top"),
		}
	)
	content.Parent = body

	local function onAction(card: Models.ShopCard, button: any)
		if card.action == "prompt" then
			Purchase.request(env, card.kind :: any, card.key)
		elseif card.action == "buy" or card.action == "upgrade" then
			Parts.call(env, "shop", remotes.Buy, card.key, button, function(ok: boolean, value: any)
				if ok then
					Parts.toast(env, loc:t("shop.bought", { item = card.title }), "Success")
				else
					Parts.toast(env, value, "Danger")
				end
			end)
		elseif card.action == "equip" then
			Parts.call(env, "shop", remotes.Equip, card.key, button, function(ok: boolean, value: any)
				if not ok then
					Parts.toast(env, value, "Danger")
				end
			end)
		elseif card.action == "unequip" then
			local item = Models.find(env.catalog.items, "id", card.key)
			if item and item.slot then
				Parts.call(env, "shop", remotes.Unequip, item.slot, button, function(ok: boolean, value: any)
					if not ok then
						Parts.toast(env, value, "Danger")
					end
				end)
			end
		end
	end

	local function onOdds(card: Models.ShopCard)
		Purchase.showOdds(env, card)
	end

	local function render()
		Parts.clear(content)
		if snapshot == nil then
			Parts.text(content, 1, loc:t("common.loading"), { color = "inkSoft", align = "Center" })
			return
		end
		local balances = if env.balances then env.balances() else nil
		local model = Models.shop(loc, env.catalog, snapshot, env.now(), balances)
		local next = Parts.counter()
		if #model.featured > 0 then
			local _, featured =
				Kit.Card.new({ Variant = "Accent", AutoHeight = true, LayoutOrder = next(), Parent = content })
			Create.list("Vertical", Tokens.space.sm, "Left", "Top").Parent = featured.content
			Parts.text(featured.content, 1, model.featuredTitle, { size = "h3", role = "display" })
			if model.featuredEnds then
				Parts.text(featured.content, 2, model.featuredEnds, { size = "caption", color = "inkSoft" })
			end
			local _, strip = Kit.Grid.new({
				Variant = "Static",
				MinCellWidth = 150,
				CellAspect = 1.45,
				LayoutOrder = 3,
				Parent = featured.content,
			})
			for i, card in model.featured do
				Parts.tile(strip.content, i, card, onAction, onOdds, loc:t("shop.odds"))
			end
		end
		local cards: { Models.ShopCard } = model.cards[Models.SHOP_TABS[selected]] or {}
		if #cards == 0 then
			Parts.text(content, next(), model.empty, { color = "inkSoft", align = "Center" })
			return
		end
		local _, grid = Kit.Grid.new({
			Variant = "Static",
			MinCellWidth = 150,
			CellAspect = 1.45,
			LayoutOrder = next(),
			Parent = content,
		})
		for i, card in cards do
			Parts.tile(grid.content, i, card, onAction, onOdds, loc:t("shop.odds"))
		end
	end

	local labels: { string } = {}
	for _, id in Models.SHOP_TABS do
		table.insert(labels, loc:t("shop.tab." .. id))
	end
	tabsFrame = Kit.Tabs.new({
		Items = labels,
		Selected = selected,
		LayoutOrder = 1,
		Parent = body,
		OnChanged = function(index: number)
			selected = index
			render()
		end,
	})

	local connection = remotes.State:connect(function(next: any)
		snapshot = next
		render()
	end)
	Parts.spawn(function()
		local result = remotes.GetState:invokeAsync()
		if result.ok and result.value then
			snapshot = result.value
		end
		render()
	end)
	render()

	-- Screens under another stay alive; stop listening only when this one is destroyed.
	root.Destroying:Connect(function()
		connection:Disconnect()
	end)
	return { root = root, defaultFocus = tabsFrame }
end

return ShopScreen
