--!strict
--[[
	Purchase prompt wrapper (brief §5.5). Every Robux purchase in both games goes through here:

	  Shared.Screens.Purchase.request(env, "product", "SkinCrate")

	Crates show their odds first and only prompt after the player confirms (paid random items
	always show odds, §6). The server decides whether the prompt opens (Shop.Prompt checks the
	product exists, is purchasable and allowed by PolicyService) and a failure becomes a toast.
	The success toast comes from Shop.Confirmed after the grant is saved (Screens.install wires it).
]]

local Kit = require("../UI/Kit")
local Models = require("./Models")
local Parts = require("./Parts")

local Purchase = {}

local function prompt(env: Parts.Env, kind: "product" | "pass", key: string)
	local remotes = env.remotes("Shop")
	Parts.call(env, "shop", remotes.Prompt, { kind = kind, key = key }, nil, function(ok: boolean, value: any)
		if not ok then
			Parts.toast(env, value, "Danger")
		end
	end)
end

-- The odds sheet for a crate card; `onBuy` adds a buy button (from the shop) instead of OK.
function Purchase.showOdds(env: Parts.Env, card: Models.ShopCard, onBuy: (() -> ())?)
	local loc = env.loc
	local modal: any = nil
	local function choose(confirmed: boolean)
		if modal then
			modal.close()
			modal = nil
			if confirmed and onBuy then
				onBuy()
			end
		end
	end
	local root, panel = Kit.Panel.new({
		Title = loc:t("shop.oddsTitle"),
		Icon = card.icon,
		Variant = "Gold",
		Scroll = true,
		Size = UDim2.fromOffset(460, 400),
		OnClose = function()
			choose(false)
		end,
	})
	local order = Parts.counter()
	Parts.text(panel.body, order(), card.title, { size = "h3", role = "display", align = "Center" })
	local odds: { string } = card.odds or {}
	for _, line in odds do
		Parts.text(panel.body, order(), line, { align = "Center" })
	end
	Parts.text(panel.body, order(), loc:t("shop.oddsNote"), { size = "caption", color = "inkSoft", align = "Center" })
	Kit.Button.new({
		Text = loc:t(if onBuy then "common.cancel" else "common.close"),
		Variant = "Secondary",
		Width = 160,
		LayoutOrder = 1,
		Parent = panel.footer,
		OnActivated = function()
			choose(false)
		end,
	})
	if onBuy then
		Kit.Button.new({
			Text = if card.price then card.actionLabel .. "  " .. card.price else card.actionLabel,
			Variant = "Gold",
			Width = 220,
			LayoutOrder = 2,
			Parent = panel.footer,
			OnActivated = function()
				choose(true)
			end,
		})
	end
	modal = env.manager:showModal(root, { DismissOnBackdrop = true })
end

--[[
	Prompts a product or pass. Crates (products with odds) show the odds sheet first. A product
	that isn't in the catalog still goes to the server, which refuses it with a reason.
]]
function Purchase.request(env: Parts.Env, kind: "product" | "pass", key: string)
	if kind == "product" then
		local product = Models.find(env.catalog.products, "key", key)
		if product and product.crate then
			local card = Models.productCard(env.loc, env.catalog, { blocked = {} }, product)
			Purchase.showOdds(env, card, function()
				prompt(env, kind, key)
			end)
			return
		end
	end
	prompt(env, kind, key)
end

-- Shop.Confirmed -> the success toast (called by Screens.install).
function Purchase.confirmed(env: Parts.Env, payload: any)
	Parts.toast(env, Models.purchaseConfirmed(env.loc, env.catalog, payload), "Success")
end

return Purchase
