--!strict
--[[
	Shop: gamepasses, developer products and the soft-currency catalog (brief §4, §6.7, §7.9).
	Server only. Ownership checks and policy lookups yield in their own threads; everything a
	purchase or receipt does is synchronous.

	  local shop = Shared.Shop.new({
	  	economy = economy,
	  	passes = {
	  		{ key = "DoubleWins", id = 123, price = 399, multipliers = {
	  			{ group = "pass", factor = 2, currencies = { "Wins" } } } },
	  	},
	  	products = {
	  		{ key = "WinsSmall", id = 456, price = 99, reward = { currencies = { Wins = 100 } } },
	  		{ key = "SkinCrate", id = 789, price = 99, crate = {
	  			pool = { { item = "skin_neon", weight = 60 }, { item = "skin_gold", weight = 5 } },
	  			ifOwned = { Wins = 30 } } },
	  		{ key = "SkipWorld", id = 790, price = 199,
	  		  canPurchase = function(who) return progression:gateProgress(who, nextGate(who)) >= 0.5 end,
	  		  grant = function(ctx) return progression:unlock(ctx.userId, nextGate(ctx.userId), "product") or true end },
	  	},
	  	items = {
	  		{ id = "lunge", category = "Boosts", levels = { { currency = "Wins", amount = 20 }, ... } },
	  		{ id = "skin_neon", category = "Cosmetics", slot = "skin", price = { currency = "Wins", amount = 150 }, featured = true },
	  	},
	  })
	  shop:bindStore(Profiles)                                  -- also takes over ProcessReceipt

	Receipts are idempotent through Data (one grant per PurchaseId, confirmed only after the
	save). A product grant must be total and must not yield: return false only to retry later.
	Crates roll from the PurchaseId, so a retried receipt rolls the same item. Developer
	products marked `random` (crates) are hidden and refused for players whose policy restricts
	paid random items (PolicyService.ArePaidRandomItemsRestricted); until the policy is known it
	counts as restricted.

	Pass ownership is checked on load (three tries), cached in the profile, and applied as
	Economy multipliers ("pass.<key>.<n>") plus a `Pass_<key>` player attribute. When the check
	fails, the cache decides; when it succeeds, the check decides.
]]

local Log = require("./Util/Log")
local Remotes = require("./Remotes")
local Rewards = require("./Rewards")
local Rng = require("./Sim/Rng")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Slots = require("./Util/Slots")
local Types = require("./Types")

export type Price = { currency: string, amount: number }

export type PassDef = {
	key: string,
	-- Gamepass id; 0 = not created yet (hidden, never owned).
	id: number,
	price: number,
	nameKey: string?,
	descriptionKey: string?,
	icon: string?,
	multipliers: { Types.MultiplierSpec }?,
	-- Game effects that aren't multipliers (an extra lunge charge). Runs each time ownership is
	-- established in a session.
	onOwned: ((who: any) -> ())?,
}

export type CrateDef = {
	pool: { { item: string, weight: number } },
	-- Paid instead when the rolled item is already owned.
	ifOwned: { [string]: number }?,
}

export type GrantContext = {
	shop: Shop,
	economy: any,
	userId: number,
	player: any?,
	profile: any,
	data: any,
	receipt: Types.PurchaseReceipt,
	product: ProductDef,
	-- Seeded from the PurchaseId: a retried receipt draws the same numbers.
	rng: Rng.Rng,
	-- Details for the client confirmation ("you got Neon Stilts").
	details: { [string]: any },
}

export type ProductDef = {
	key: string,
	-- Developer product id; 0 = not created yet (hidden).
	id: number,
	price: number,
	nameKey: string?,
	descriptionKey: string?,
	icon: string?,
	-- Simple grants: a reward paid with the "purchase" reason (a grant: exact, no lifetime).
	reward: Types.Reward?,
	crate: CrateDef?,
	-- Custom grants. Return false to retry later; must not yield.
	grant: ((ctx: GrantContext) -> boolean?)?,
	-- Checked before prompting (Skip-to-World at 50% of the gate).
	canPurchase: ((who: any) -> (boolean, string?))?,
	-- A paid random item: hidden where policy restricts them. Crates are random by default.
	random: boolean?,
}

export type ItemDef = {
	id: string,
	category: string,
	-- Equip slot ("skin", "cap", "trail"); nil = not equippable (upgrades, consumables).
	slot: string?,
	-- Single purchase price. Nil (and no levels) = not sold, only granted.
	price: Price?,
	-- Upgrade prices: levels[n] is the price of level n.
	levels: { Price }?,
	-- Extra condition (a world unlocked); return (false, reason) to hide the buy button.
	available: ((who: any) -> (boolean, string?))?,
	nameKey: string?,
	descriptionKey: string?,
	icon: string?,
	-- In the featured rotation pool.
	featured: boolean?,
	rarity: string?,
	-- Owned from the start (the default skin).
	default: boolean?,
	order: number?,
}

export type Options = {
	economy: any,
	passes: { PassDef }?,
	products: { ProductDef }?,
	items: { ItemDef }?,
	-- Category display order for the soft-currency catalog.
	categories: { string }?,
	featured: { count: number?, period: number?, seed: string?, pool: { string }? }?,
	field: string?,
	-- Economy reasons. Defaults "shop" (spend) and "purchase" (grant).
	spendReason: string?,
	purchaseReason: string?,
	-- Equip an equippable item when it is bought or granted and nothing is in its slot. Default true.
	autoEquip: boolean?,
	analytics: any?,
	-- Dependencies.
	marketplace: any?,
	policy: any?,
	players: any?,
	task: any?,
	now: (() -> number)?,
	-- Ownership check attempts and the wait between them. Defaults 3 and 2 s.
	ownershipRetries: number?,
	ownershipRetryDelay: number?,
}

export type State = {
	-- Item id -> level (1 for plain items).
	owned: { [string]: number },
	-- Slot -> item id.
	equipped: { [string]: string },
	-- Pass key -> true when ownership was last confirmed.
	passes: { [string]: boolean },
	-- Robux spent on products, and product purchases (for "first purchase" style checks).
	robuxSpent: number,
	purchases: number,
}

-- What a client needs to render the shop, for one player.
export type Snapshot = {
	owned: { [string]: number },
	equipped: { [string]: string },
	passes: { [string]: boolean },
	-- Product key -> nil if purchasable, else the reason it isn't.
	blocked: { [string]: string },
	-- Item id -> reason it can't be bought now (beyond price), e.g. "locked".
	unavailable: { [string]: string },
	featured: { string },
	featuredEndsAt: number,
	randomItemsAllowed: boolean,
}

export type Failure =
	"notLoaded"
	| "unknown"
	| "notForSale"
	| "owned"
	| "maxed"
	| "unavailable"
	| "insufficient"
	| "notEquippable"
	| "notOwned"
	| "notCreated" -- id is 0
	| "restricted" -- paid random items not allowed for this player
	| string

export type Shop = {
	-- (player?, userId, itemId, level) after a soft-currency purchase.
	Purchased: Signal.Signal<any, number, string, number>,
	-- (player?, userId, itemId, reason) after an item is granted (reward, crate, purchase).
	ItemGranted: Signal.Signal<any, number, string, string>,
	-- (player?, userId, slot, itemId or nil)
	Equipped: Signal.Signal<any, number, string, string?>,
	-- (player?, userId, passKey) when ownership is established in a session.
	PassOwned: Signal.Signal<any, number, string>,
	-- (player?, userId, kind, key, details) once a purchase is saved (product) or completed (pass).
	Confirmed: Signal.Signal<any, number, string, string, { [string]: any }>,
	-- (player?, userId) after anything in the snapshot changes.
	Changed: Signal.Signal<any, number>,

	bindStore: (self: Shop, store: any, options: { processReceipt: boolean? }?) -> (),
	attach: (self: Shop, who: any, data: any) -> (),
	detach: (self: Shop, who: any) -> (),
	isAttached: (self: Shop, who: any) -> boolean,

	item: (self: Shop, itemId: string) -> ItemDef?,
	items: (self: Shop, category: string?) -> { ItemDef },
	categories: (self: Shop) -> { string },
	pass: (self: Shop, key: string) -> PassDef?,
	passes: (self: Shop) -> { PassDef },
	product: (self: Shop, key: string) -> ProductDef?,
	products: (self: Shop) -> { ProductDef },
	-- Odds for a crate product: { { item, chance } } with chances summing to 1.
	odds: (self: Shop, productKey: string) -> { { item: string, chance: number } },

	hasItem: (self: Shop, who: any, itemId: string) -> boolean,
	level: (self: Shop, who: any, itemId: string) -> number,
	-- Price of the next purchase of an item (next level for upgrades), or nil.
	priceOf: (self: Shop, who: any, itemId: string) -> Price?,
	buy: (self: Shop, who: any, itemId: string) -> (boolean, Failure?, number?),
	grantItem: (self: Shop, who: any, itemId: string, reason: string) -> (boolean, Failure?),
	revokeItem: (self: Shop, who: any, itemId: string) -> (),
	equip: (self: Shop, who: any, itemId: string) -> (boolean, Failure?),
	unequip: (self: Shop, who: any, slot: string) -> (),
	equipped: (self: Shop, who: any, slot: string) -> string?,

	ownsPass: (self: Shop, who: any, key: string) -> boolean,
	-- Re-checks every pass for a player (yields).
	refreshPassesAsync: (self: Shop, player: any) -> (),
	canPurchase: (self: Shop, who: any, productKey: string) -> (boolean, Failure?),
	-- Shows the Roblox purchase prompt after the server-side checks.
	prompt: (self: Shop, player: any, kind: "product" | "pass", key: string) -> (boolean, Failure?),
	-- The ProcessReceipt body (bindStore sets it on MarketplaceService unless told not to).
	processReceipt: (self: Shop, receipt: Types.PurchaseReceipt) -> any,

	featured: (self: Shop, time: number?) -> ({ string }, number),
	snapshot: (self: Shop, who: any) -> Snapshot?,
	randomItemsAllowed: (self: Shop, who: any) -> boolean,
	-- For tests and admin: set what the policy lookup would return.
	setRandomItemsAllowed: (self: Shop, who: any, allowed: boolean) -> (),

	-- Server: binds this module's remotes (Remotes.shop) and wires the handlers. Once, at startup.
	bindNet: (self: Shop, context: any?) -> any,
}

local Shop = {}

function Shop.newState(): State
	return { owned = {}, equipped = {}, passes = {}, robuxSpent = 0, purchases = 0 }
end

local function finiteAtLeast(value: any, min: number): boolean
	return type(value) == "number" and value == value and value >= min and value < math.huge
end

function Shop.repair(state: any): State
	local out = Shop.newState()
	if type(state) ~= "table" then
		return out
	end
	if type(state.owned) == "table" then
		for id, level in state.owned do
			if type(id) == "string" then
				if level == true then
					out.owned[id] = 1
				elseif finiteAtLeast(level, 1) then
					out.owned[id] = math.floor(level)
				end
			end
		end
	end
	if type(state.equipped) == "table" then
		for slot, id in state.equipped do
			if type(slot) == "string" and type(id) == "string" then
				out.equipped[slot] = id
			end
		end
	end
	if type(state.passes) == "table" then
		for key, owned in state.passes do
			if type(key) == "string" and owned == true then
				out.passes[key] = true
			end
		end
	end
	out.robuxSpent = if finiteAtLeast(state.robuxSpent, 0) then state.robuxSpent else 0
	out.purchases = if finiteAtLeast(state.purchases, 0) then math.floor(state.purchases) else 0
	return out
end

-- Odds of a crate pool, in pool order (pure). Used by the crate screen and the roll.
function Shop.oddsOf(crate: CrateDef): { { item: string, chance: number } }
	local total = 0
	for _, entry in crate.pool do
		total += entry.weight
	end
	local out: { { item: string, chance: number } } = {}
	for _, entry in crate.pool do
		table.insert(out, { item = entry.item, chance = if total > 0 then entry.weight / total else 0 })
	end
	return out
end

-- The item a crate gives for a draw in [0, 1) (pure).
function Shop.rollCrate(crate: CrateDef, draw: number): string
	local total = 0
	for _, entry in crate.pool do
		total += entry.weight
	end
	local target = draw * total
	local running = 0
	for _, entry in crate.pool do
		running += entry.weight
		if target < running then
			return entry.item
		end
	end
	return crate.pool[#crate.pool].item
end

local function validatePrice(where: string, price: any, economy: any)
	assert(type(price) == "table", where .. " must be { currency, amount }")
	assert(
		type(price.currency) == "string" and economy:currency(price.currency),
		where .. ": unknown currency " .. tostring(price.currency)
	)
	assert(finiteAtLeast(price.amount, 0), where .. ".amount must be >= 0")
end

function Shop.new(options: Options): Shop
	local economy = options.economy
	assert(economy ~= nil, "Shop.new: economy is required")
	local now: () -> number = options.now or os.time
	local spendReason = options.spendReason or "shop"
	local purchaseReason = options.purchaseReason or "purchase"
	local autoEquip = options.autoEquip ~= false
	local retries = options.ownershipRetries or 3
	local retryDelay = options.ownershipRetryDelay or 2

	local itemById: { [string]: ItemDef } = {}
	local itemList: { ItemDef } = {}
	local orderOf: { [string]: number } = {}
	local itemDefs: { ItemDef } = options.items or {}
	for index, item in itemDefs do
		assert(
			type(item.id) == "string" and #item.id > 0 and #item.id <= 64,
			"Shop.new: item id must be 1-64 characters"
		)
		assert(itemById[item.id] == nil, "Shop.new: duplicate item " .. item.id)
		assert(type(item.category) == "string", "Shop.new: item " .. item.id .. " needs a category")
		if item.price then
			validatePrice("Shop.new: item " .. item.id .. ".price", item.price, economy)
		end
		if item.levels then
			assert(item.price == nil, "Shop.new: item " .. item.id .. " has both price and levels")
			assert(#item.levels > 0, "Shop.new: item " .. item.id .. ".levels must not be empty")
			assert(item.slot == nil, "Shop.new: upgrade " .. item.id .. " can't have a slot")
			for level, price in item.levels do
				validatePrice("Shop.new: item " .. item.id .. ".levels[" .. level .. "]", price, economy)
			end
		end
		itemById[item.id] = item
		table.insert(itemList, item)
		orderOf[item.id] = item.order or index
	end

	local passByKey: { [string]: PassDef } = {}
	local passById: { [number]: PassDef } = {}
	local passList: { PassDef } = {}
	local passDefs: { PassDef } = options.passes or {}
	for _, pass in passDefs do
		assert(type(pass.key) == "string" and #pass.key > 0, "Shop.new: pass key must be a non-empty string")
		assert(passByKey[pass.key] == nil, "Shop.new: duplicate pass " .. pass.key)
		assert(finiteAtLeast(pass.id, 0), "Shop.new: pass " .. pass.key .. ".id must be a number (0 = not created)")
		passByKey[pass.key] = pass
		if pass.id > 0 then
			assert(passById[pass.id] == nil, "Shop.new: two passes share id " .. pass.id)
			passById[pass.id] = pass
		end
		table.insert(passList, pass)
	end

	local productByKey: { [string]: ProductDef } = {}
	local productById: { [number]: ProductDef } = {}
	local productList: { ProductDef } = {}
	local productDefs: { ProductDef } = options.products or {}
	for _, product in productDefs do
		assert(type(product.key) == "string" and #product.key > 0, "Shop.new: product key must be a non-empty string")
		assert(productByKey[product.key] == nil, "Shop.new: duplicate product " .. product.key)
		assert(
			finiteAtLeast(product.id, 0),
			"Shop.new: product " .. product.key .. ".id must be a number (0 = not created)"
		)
		local grants = (if product.reward then 1 else 0)
			+ (if product.crate then 1 else 0)
			+ (if product.grant then 1 else 0)
		assert(grants == 1, "Shop.new: product " .. product.key .. " needs exactly one of reward, crate or grant")
		if product.crate then
			assert(#product.crate.pool > 0, "Shop.new: crate " .. product.key .. " has an empty pool")
			for _, entry in product.crate.pool do
				assert(
					itemById[entry.item],
					"Shop.new: crate " .. product.key .. " has unknown item " .. tostring(entry.item)
				)
				assert(
					finiteAtLeast(entry.weight, 0) and entry.weight > 0,
					"Shop.new: crate " .. product.key .. " weights must be positive"
				)
			end
		end
		productByKey[product.key] = product
		if product.id > 0 then
			assert(productById[product.id] == nil, "Shop.new: two products share id " .. product.id)
			productById[product.id] = product
		end
		table.insert(productList, product)
	end

	local categoryList: { string } = table.clone(options.categories or {})
	for _, item in itemList do
		if not table.find(categoryList, item.category) then
			table.insert(categoryList, item.category)
		end
	end

	local featuredOptions: { count: number?, period: number?, seed: string?, pool: { string }? } = options.featured
		or {}
	local featuredCount = featuredOptions.count or 3
	local featuredPeriod = featuredOptions.period or 6 * 3600
	local featuredSeed = featuredOptions.seed or "shop.featured"
	local featuredPool: { string } = {}
	if featuredOptions.pool then
		for _, ref in featuredOptions.pool do
			local kind, key = string.match(ref, "^(%a+):(.+)$")
			assert(
				(kind == "item" and itemById[key :: string])
					or (kind == "pass" and passByKey[key :: string])
					or (kind == "product" and productByKey[key :: string]),
				"Shop.new: featured pool entry " .. ref .. " must be item:<id>, pass:<key> or product:<key>"
			)
			table.insert(featuredPool, ref)
		end
	else
		for _, item in itemList do
			if item.featured then
				table.insert(featuredPool, "item:" .. item.id)
			end
		end
	end

	local slots = Slots.new(options.field or "shop", Shop.newState, Shop.repair)
	local randomAllowed: { [number]: boolean } = {}
	-- PurchaseId -> details of a grant waiting for its save (ReceiptGranted).
	local pendingDetails: { [string]: { [string]: any } } = {}
	local boundStore: any = nil

	local shop = {
		Purchased = Signal.new(),
		ItemGranted = Signal.new(),
		Equipped = Signal.new(),
		PassOwned = Signal.new(),
		Confirmed = Signal.new(),
		Changed = Signal.new(),
	} :: Shop

	local function taskLib(): any
		return options.task or Roblox.task()
	end

	local function marketplace(): any
		return options.marketplace or Roblox.service("MarketplaceService")
	end

	local function userIdOf(who: any): number?
		return Slots.userIdOf(who)
	end

	local function changed(who: any)
		local id = userIdOf(who)
		if id then
			shop.Changed:Fire(slots:player(who), id)
		end
	end

	local function setAttribute(who: any, name: string, value: any)
		Slots.setAttribute(slots:player(who), name, value)
	end

	local function applyPass(who: any, pass: PassDef)
		local specs: { Types.MultiplierSpec } = pass.multipliers or {}
		for i, spec in specs do
			economy:setMultiplier(who, "pass." .. pass.key .. "." .. i, spec)
		end
		setAttribute(who, "Pass_" .. pass.key, true)
		if pass.onOwned then
			pass.onOwned(who)
		end
		shop.PassOwned:Fire(slots:player(who), userIdOf(who) :: number, pass.key)
	end

	local function removePass(who: any, pass: PassDef)
		local specs: { Types.MultiplierSpec } = pass.multipliers or {}
		for i in specs do
			economy:setMultiplier(who, "pass." .. pass.key .. "." .. i, nil)
		end
		setAttribute(who, "Pass_" .. pass.key, nil)
	end

	local function setPassOwned(who: any, pass: PassDef, owned: boolean)
		local state = slots:get(who)
		local was = state ~= nil and state.passes[pass.key] == true
		if state then
			if owned then
				state.passes[pass.key] = true
			else
				state.passes[pass.key] = nil
			end
		end
		if owned then
			applyPass(who, pass)
		elseif was then
			removePass(who, pass)
		end
		changed(who)
	end

	local function equipIn(who: any, state: State, item: ItemDef)
		local slot = item.slot :: string
		state.equipped[slot] = item.id
		setAttribute(who, "Equipped_" .. slot, item.id)
		shop.Equipped:Fire(slots:player(who), userIdOf(who) :: number, slot, item.id)
	end

	local function giveItem(who: any, state: State, item: ItemDef, reason: string): (boolean, Failure?, number?)
		local level = state.owned[item.id] or 0
		if item.levels then
			if level >= #item.levels then
				return false, "maxed", level
			end
		elseif level >= 1 then
			return false, "owned", level
		end
		level += 1
		state.owned[item.id] = level
		if item.slot and autoEquip and state.equipped[item.slot] == nil then
			equipIn(who, state, item)
		end
		shop.ItemGranted:Fire(slots:player(who), userIdOf(who) :: number, item.id, reason)
		return true, nil, level
	end

	slots.Attached:Connect(function(player: any, userId: number, state: State)
		local who: any = player or userId
		for _, item in itemList do
			if item.default and (state.owned[item.id] or 0) < 1 then
				state.owned[item.id] = 1
				if item.slot and state.equipped[item.slot] == nil then
					state.equipped[item.slot] = item.id
				end
			end
		end
		-- Drop equips of items that are gone or no longer owned.
		for slot, itemId in state.equipped do
			local item = itemById[itemId]
			if item == nil or item.slot ~= slot or (state.owned[itemId] or 0) < 1 then
				state.equipped[slot] = nil
			end
		end
		for slot, itemId in state.equipped do
			setAttribute(who, "Equipped_" .. slot, itemId)
		end
		-- Cached passes apply at once; the live check below corrects them.
		for key in state.passes do
			local pass = passByKey[key]
			if pass and pass.id > 0 then
				applyPass(who, pass)
			end
		end
		if player ~= nil then
			taskLib().spawn(function()
				shop:refreshPassesAsync(player)
			end)
			local policy = options.policy
			if policy == nil and Roblox.isRoblox() then
				policy = Roblox.service("PolicyService")
			end
			if policy then
				taskLib().spawn(function()
					local ok, info = pcall(function()
						return policy:GetPolicyInfoForPlayerAsync(player)
					end)
					if ok and type(info) == "table" then
						randomAllowed[userId] = info.ArePaidRandomItemsRestricted ~= true
						changed(player)
					elseif not ok then
						Log.warn("Shop", "policy lookup failed for " .. tostring(userId) .. ": " .. tostring(info))
					end
				end)
			end
		end
	end)

	slots.Detached:Connect(function(_player: any, userId: number)
		randomAllowed[userId] = nil
	end)

	function shop.bindStore(self: Shop, store: any, bindOptions: { processReceipt: boolean? }?)
		boundStore = store
		slots:bindStore(store)
		store.ReceiptGranted:Connect(function(player: any, profile: any, receipt: Types.PurchaseReceipt)
			local details = pendingDetails[receipt.PurchaseId]
			pendingDetails[receipt.PurchaseId] = nil
			local product = productById[receipt.ProductId]
			if product then
				self.Confirmed:Fire(player, profile.userId, "product", product.key, details or {})
			end
		end)
		local mps = options.marketplace
		if mps == nil and Roblox.isRoblox() then
			mps = Roblox.service("MarketplaceService")
		end
		if mps then
			mps.PromptGamePassPurchaseFinished:Connect(function(player: any, passId: number, purchased: boolean)
				local pass = passById[passId]
				if pass and purchased and slots:isAttached(player) then
					setPassOwned(player, pass, true)
					self.Confirmed:Fire(player, player.UserId, "pass", pass.key, {})
					local sink = options.analytics
					if sink and type(sink.purchase) == "function" then
						-- Analytics counts receipts; a pass purchase has none, so it gets the same shape.
						sink:purchase(player, {
							PlayerId = player.UserId,
							ProductId = pass.id,
							CurrencySpent = pass.price,
							CurrencyType = "Robux",
						})
					end
				end
			end)
			local o: { processReceipt: boolean? } = bindOptions or {}
			if o.processReceipt ~= false then
				mps.ProcessReceipt = function(receipt: any)
					return self:processReceipt(receipt)
				end
			end
		end
		local players = options.players
		if players == nil and Roblox.isRoblox() then
			players = Roblox.service("Players")
		end
		if players then
			for _, player in players:GetPlayers() do
				local profile = store:get(player)
				if profile and not slots:isAttached(player) then
					self:attach(player, function()
						return profile.data
					end)
				end
			end
		end
	end

	function shop.attach(_self: Shop, who: any, data: any)
		slots:attach(who, data)
	end

	function shop.detach(_self: Shop, who: any)
		slots:detach(who)
	end

	function shop.isAttached(_self: Shop, who: any): boolean
		return slots:isAttached(who)
	end

	function shop.item(_self: Shop, itemId: string): ItemDef?
		return itemById[itemId]
	end

	function shop.items(_self: Shop, category: string?): { ItemDef }
		local out: { ItemDef } = {}
		for _, item in itemList do
			if category == nil or item.category == category then
				table.insert(out, item)
			end
		end
		table.sort(out, function(a: ItemDef, b: ItemDef): boolean
			local oa, ob = orderOf[a.id], orderOf[b.id]
			if oa ~= ob then
				return oa < ob
			end
			return a.id < b.id
		end)
		return out
	end

	function shop.categories(_self: Shop): { string }
		return table.clone(categoryList)
	end

	function shop.pass(_self: Shop, key: string): PassDef?
		return passByKey[key]
	end

	function shop.passes(_self: Shop): { PassDef }
		return table.clone(passList)
	end

	function shop.product(_self: Shop, key: string): ProductDef?
		return productByKey[key]
	end

	function shop.products(_self: Shop): { ProductDef }
		return table.clone(productList)
	end

	function shop.odds(_self: Shop, productKey: string): { { item: string, chance: number } }
		local product = productByKey[productKey]
		if product == nil or product.crate == nil then
			return {}
		end
		return Shop.oddsOf(product.crate)
	end

	function shop.hasItem(_self: Shop, who: any, itemId: string): boolean
		local state = slots:get(who)
		return state ~= nil and (state.owned[itemId] or 0) >= 1
	end

	function shop.level(_self: Shop, who: any, itemId: string): number
		local state = slots:get(who)
		return if state then state.owned[itemId] or 0 else 0
	end

	function shop.priceOf(self: Shop, who: any, itemId: string): Price?
		local item = itemById[itemId]
		if item == nil then
			return nil
		end
		if item.levels then
			return item.levels[self:level(who, itemId) + 1]
		end
		return item.price
	end

	function shop.buy(self: Shop, who: any, itemId: string): (boolean, Failure?, number?)
		local state = slots:get(who)
		if state == nil or not economy:isAttached(who) then
			return false, "notLoaded", nil
		end
		local item = itemById[itemId]
		if item == nil then
			return false, "unknown", nil
		end
		if item.price == nil and item.levels == nil then
			return false, "notForSale", nil
		end
		local level = state.owned[itemId] or 0
		if item.levels and level >= #item.levels then
			return false, "maxed", level
		end
		if not item.levels and level >= 1 then
			return false, "owned", level
		end
		if item.available then
			local ok, reason = item.available(who)
			if not ok then
				return false, reason or "unavailable", level
			end
		end
		local price = self:priceOf(who, itemId) :: Price
		if price.amount > 0 then
			local paid, failure = economy:spend(who, price.currency, price.amount, spendReason)
			if not paid then
				return false, failure, level
			end
		end
		local _, _, newLevel = giveItem(who, state, item, spendReason)
		self.Purchased:Fire(slots:player(who), userIdOf(who) :: number, itemId, newLevel :: number)
		changed(who)
		return true, nil, newLevel
	end

	function shop.grantItem(_self: Shop, who: any, itemId: string, reason: string): (boolean, Failure?)
		local state = slots:get(who)
		if state == nil then
			return false, "notLoaded"
		end
		local item = itemById[itemId]
		if item == nil then
			Log.warn("Shop", "grantItem: unknown item " .. itemId)
			return false, "unknown"
		end
		local ok, failure = giveItem(who, state, item, reason)
		if ok then
			changed(who)
		end
		return ok, failure
	end

	function shop.revokeItem(_self: Shop, who: any, itemId: string)
		local state = slots:get(who)
		if state == nil or state.owned[itemId] == nil then
			return
		end
		state.owned[itemId] = nil
		for slot, equippedId in state.equipped do
			if equippedId == itemId then
				state.equipped[slot] = nil
				setAttribute(who, "Equipped_" .. slot, nil)
				shop.Equipped:Fire(slots:player(who), userIdOf(who) :: number, slot, nil)
			end
		end
		changed(who)
	end

	function shop.equip(_self: Shop, who: any, itemId: string): (boolean, Failure?)
		local state = slots:get(who)
		if state == nil then
			return false, "notLoaded"
		end
		local item = itemById[itemId]
		if item == nil then
			return false, "unknown"
		end
		if item.slot == nil then
			return false, "notEquippable"
		end
		if (state.owned[itemId] or 0) < 1 then
			return false, "notOwned"
		end
		equipIn(who, state, item)
		changed(who)
		return true, nil
	end

	function shop.unequip(_self: Shop, who: any, slot: string)
		local state = slots:get(who)
		if state == nil or state.equipped[slot] == nil then
			return
		end
		state.equipped[slot] = nil
		setAttribute(who, "Equipped_" .. slot, nil)
		shop.Equipped:Fire(slots:player(who), userIdOf(who) :: number, slot, nil)
		changed(who)
	end

	function shop.equipped(_self: Shop, who: any, slot: string): string?
		local state = slots:get(who)
		return if state then state.equipped[slot] else nil
	end

	function shop.ownsPass(_self: Shop, who: any, key: string): boolean
		local state = slots:get(who)
		return state ~= nil and state.passes[key] == true
	end

	function shop.refreshPassesAsync(_self: Shop, player: any)
		local mps = marketplace()
		for _, pass in passList do
			if pass.id > 0 then
				local owned: boolean? = nil
				for attempt = 1, retries do
					local ok, result = pcall(function()
						return mps:UserOwnsGamePassAsync(player.UserId, pass.id)
					end)
					if ok then
						owned = result == true
						break
					end
					Log.warn(
						"Shop",
						string.format(
							"pass check %s for %d failed (try %d): %s",
							pass.key,
							player.UserId,
							attempt,
							tostring(result)
						)
					)
					if attempt < retries then
						taskLib().wait(retryDelay * attempt)
					end
				end
				if not slots:isAttached(player) then
					return
				end
				if owned ~= nil then
					local state = slots:get(player)
					local was = state ~= nil and state.passes[pass.key] == true
					if owned ~= was then
						setPassOwned(player, pass, owned)
					end
				end
			end
		end
	end

	function shop.randomItemsAllowed(_self: Shop, who: any): boolean
		local id = userIdOf(who)
		return id ~= nil and randomAllowed[id] == true
	end

	function shop.setRandomItemsAllowed(_self: Shop, who: any, allowed: boolean)
		local id = userIdOf(who)
		if id then
			randomAllowed[id] = allowed
			changed(who)
		end
	end

	local function isRandom(product: ProductDef): boolean
		if product.random ~= nil then
			return product.random
		end
		return product.crate ~= nil
	end

	function shop.canPurchase(self: Shop, who: any, productKey: string): (boolean, Failure?)
		local product = productByKey[productKey]
		if product == nil then
			return false, "unknown"
		end
		if product.id <= 0 then
			return false, "notCreated"
		end
		if not slots:isAttached(who) then
			return false, "notLoaded"
		end
		if isRandom(product) and not self:randomItemsAllowed(who) then
			return false, "restricted"
		end
		if product.canPurchase then
			local ok, reason = product.canPurchase(who)
			if not ok then
				return false, reason or "unavailable"
			end
		end
		return true, nil
	end

	function shop.prompt(self: Shop, player: any, kind: "product" | "pass", key: string): (boolean, Failure?)
		if kind == "pass" then
			local pass = passByKey[key]
			if pass == nil then
				return false, "unknown"
			end
			if pass.id <= 0 then
				return false, "notCreated"
			end
			if self:ownsPass(player, key) then
				return false, "owned"
			end
			marketplace():PromptGamePassPurchase(player, pass.id)
			return true, nil
		end
		local ok, failure = self:canPurchase(player, key)
		if not ok then
			return false, failure
		end
		marketplace():PromptProductPurchase(player, (productByKey[key] :: ProductDef).id)
		return true, nil
	end

	local function grantProduct(profile: any, receipt: Types.PurchaseReceipt): boolean
		local product = productById[receipt.ProductId]
		if product == nil then
			Log.error("Shop", "receipt for unknown product id " .. tostring(receipt.ProductId) .. "; left unprocessed")
			return false
		end
		local userId = profile.userId
		if not slots:isAttached(userId) then
			slots:attach(userId, function()
				return profile.data
			end)
		end
		local state = slots:get(userId) :: State
		local details: { [string]: any } = {}
		local ctx: GrantContext = {
			shop = shop,
			economy = economy,
			userId = userId,
			player = slots:player(userId),
			profile = profile,
			data = profile.data,
			receipt = receipt,
			product = product,
			rng = Rng.new("receipt:" .. receipt.PurchaseId),
			details = details,
		}
		local granted: boolean
		if product.reward then
			local target: Rewards.Target = { economy = economy, shop = shop :: any }
			local applied = Rewards.apply(target, userId, product.reward :: Types.Reward, purchaseReason)
			granted = applied.ok
			details.items = applied.items
			details.currencies = applied.currencies
		elseif product.crate then
			local itemId = Shop.rollCrate(product.crate, ctx.rng:next())
			details.item = itemId
			if shop:hasItem(userId, itemId) then
				details.duplicate = true
				local applied = Rewards.apply(
					{ economy = economy },
					userId,
					{ currencies = product.crate.ifOwned or {} },
					purchaseReason
				)
				granted = applied.ok
				details.currencies = applied.currencies
			else
				granted = (shop:grantItem(userId, itemId, purchaseReason))
			end
		else
			local grant = product.grant :: (GrantContext) -> boolean?
			granted = grant(ctx) ~= false
		end
		if granted then
			state.purchases += 1
			state.robuxSpent += receipt.CurrencySpent or 0
			pendingDetails[receipt.PurchaseId] = details
			changed(userId)
		end
		return granted
	end

	function shop.processReceipt(_self: Shop, receipt: Types.PurchaseReceipt): any
		local store = boundStore
		assert(store, "Shop.processReceipt: call shop:bindStore(store) first")
		return store:processReceipt(receipt, grantProduct)
	end

	function shop.featured(_self: Shop, time: number?): ({ string }, number)
		local t = time or now()
		local period = math.floor(t / featuredPeriod)
		local endsAt = (period + 1) * featuredPeriod
		local pool = table.clone(featuredPool)
		local rng = Rng.new(string.format("%s:%d", featuredSeed, period))
		local picks: { string } = {}
		for _ = 1, math.min(featuredCount, #pool) do
			table.insert(picks, table.remove(pool, rng:int(1, #pool)) :: string)
		end
		return picks, endsAt
	end

	function shop.snapshot(self: Shop, who: any): Snapshot?
		local state = slots:get(who)
		if state == nil then
			return nil
		end
		local blocked: { [string]: string } = {}
		for _, product in productList do
			local ok, failure = self:canPurchase(who, product.key)
			if not ok then
				blocked[product.key] = failure or "unavailable"
			end
		end
		local unavailable: { [string]: string } = {}
		for _, item in itemList do
			if item.available then
				local ok, reason = item.available(who)
				if not ok then
					unavailable[item.id] = reason or "unavailable"
				end
			end
		end
		local featured, endsAt = self:featured()
		return {
			owned = table.clone(state.owned),
			equipped = table.clone(state.equipped),
			passes = table.clone(state.passes),
			blocked = blocked,
			unavailable = unavailable,
			featured = featured,
			featuredEndsAt = endsAt,
			randomItemsAllowed = self:randomItemsAllowed(who),
		}
	end

	function shop.bindNet(self: Shop, context: any?): any
		return Remotes.serve("Shop", self, context)
	end
	return shop
end

return Shop
