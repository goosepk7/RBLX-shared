--!strict
--[[
	Screen models: pure functions that turn what the server sends (Remotes payloads) plus the
	game's config into exactly what each shared screen shows, already localized. The screen
	builders only lay these out, so everything a player reads is decided (and tested) here.

	Every function takes the game's Loc instance first. Content names follow the conventions
	in the Screens header (currency.<Id>, item.<id>, ... or a def's nameKey).
]]

local Loc = require("../Loc")
local Shop = require("../Shop")
local Types = require("../Types")

local Models = {}

--[[ Text helpers ]]

-- The first key Loc has, else `fallback` (an id, so a gap is visible but never blank).
function Models.label(loc: Loc.Loc, keys: { string? }, fallback: string): string
	for _, key in keys do
		if key and loc:has(key) then
			return loc:t(key)
		end
	end
	return fallback
end

function Models.currency(loc: Loc.Loc, id: string): string
	return Models.label(loc, { "currency." .. id }, id)
end

-- `n` with up to `places` decimals (trailing zeros dropped), in the locale's separator.
function Models.decimal(loc: Loc.Loc, n: number, places: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "0"
	end
	local scale = 10 ^ places
	local rounded = math.round(n * scale) / scale
	if rounded == math.floor(rounded) then
		return loc:grouped(rounded)
	end
	local text = string.format("%." .. places .. "f", rounded)
	text = (string.gsub(text, "0+$", ""))
	local whole, frac = string.match(text, "^(-?%d+)%.(%d+)$")
	if whole == nil or frac == nil then
		return text
	end
	-- loc:number(0.5) is "0.5" or "0,5": its second character is the locale's decimal mark.
	local mark = string.sub(loc:number(0.5), 2, 2)
	local wholeNumber = tonumber(whole) :: number
	local grouped = loc:grouped(math.abs(wholeNumber))
	local sign = if string.sub(whole, 1, 1) == "-" then "-" else ""
	return sign .. grouped .. mark .. frac
end

-- 0..1 -> "12.5%" (two decimals at most; never "0%" for a real chance).
function Models.percent(loc: Loc.Loc, chance: number): string
	local value = chance * 100
	local places = if value < 1 then 2 else 1
	local shown = Models.decimal(loc, value, places)
	if value > 0 and tonumber((string.gsub(shown, ",", "."))) == 0 then
		shown = Models.decimal(loc, 0.01, 2)
	end
	return loc:t("common.percent", { value = shown })
end

-- Seconds left -> "2d 3h", "1h 05m", "4m 09s", "12s".
-- A countdown as a clock: "0:42", "9:59", "1:02:03"; days fall back to `duration` ("2d 3h").
-- Digits and colons read the same in every locale and stay short, so it is the form a chip
-- keeps when nothing else fits.
function Models.clock(loc: Loc.Loc, seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	if s >= 86400 then
		return Models.duration(loc, s)
	end
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local rest = s % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, rest)
	end
	return string.format("%d:%02d", m, rest)
end

function Models.duration(loc: Loc.Loc, seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	local d = math.floor(s / 86400)
	local h = math.floor((s % 86400) / 3600)
	local m = math.floor((s % 3600) / 60)
	local rest = s % 60
	if d > 0 then
		return loc:t("time.days", { d = d, h = h })
	elseif h > 0 then
		return loc:t("time.hours", { h = h, m = string.format("%02d", m) })
	elseif m > 0 then
		return loc:t("time.minutes", { m = m, s = string.format("%02d", rest) })
	end
	return loc:t("time.seconds", { s = rest })
end

function Models.multiplier(loc: Loc.Loc, factor: number): string
	return loc:t("rewards.multiplier", { value = Models.decimal(loc, factor, 2) })
end

--[[
	A failure code -> the player-facing sentence: the area's own text ("<area>.fail.<code>"), then
	the game's for its own reasons ("fail.<code>", e.g. fail.tooNew from a code's `requires`),
	then the request-level one ("errors.<code>"), then the generic line.
]]
function Models.failure(loc: Loc.Loc, area: string, code: string?): string
	local reason = code or "generic"
	return Models.label(loc, {
		area .. ".fail." .. reason,
		"fail." .. reason,
		"errors." .. reason,
	}, loc:t("common.error"))
end

--[[
	The outcome of a remote call: (ok, value) when the server answered with { ok = true, ... },
	else (false, message) with the request's or the module's failure already localized.
]]
function Models.answer(loc: Loc.Loc, area: string, result: any): (boolean, any)
	if type(result) ~= "table" or result.ok ~= true then
		local code = if type(result) == "table" then result.error else nil
		return false, Models.failure(loc, area, code)
	end
	local value = result.value
	if type(value) == "table" and value.ok == false then
		return false, Models.failure(loc, area, value.failure)
	end
	return true, value
end

--[[ Rewards ]]

local function itemName(loc: Loc.Loc, id: string, catalog: Catalog?): string
	local def = if catalog then Models.find(catalog.items, "id", id) else nil
	return Models.label(loc, { def and def.nameKey, "item." .. id }, id)
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--[[
	One line per thing a reward gives: "+50 Wins", the item's name, "2x Wins for 30m". Takes a
	config Reward or the Rewards.Applied result the server returns.
]]
function Models.rewardLines(loc: Loc.Loc, reward: any, catalog: Catalog?): { string }
	local lines: { string } = {}
	if type(reward) ~= "table" then
		return lines
	end
	local currencies: { [string]: number } = reward.currencies or {}
	for _, id in sortedKeys(currencies) do
		local amount = currencies[id]
		if amount ~= 0 then
			table.insert(
				lines,
				loc:t("rewards.currency", { amount = loc:grouped(amount), currency = Models.currency(loc, id) })
			)
		end
	end
	local items: { string } = reward.items or {}
	for _, id in items do
		table.insert(lines, itemName(loc, id, catalog))
	end
	-- Applied results: items that were already owned (their ifOwned pay is in `currencies`).
	local duplicates: { any } = reward.duplicates or {}
	for _, id in duplicates do
		if type(id) == "string" then
			table.insert(lines, loc:t("rewards.duplicate", { item = itemName(loc, id, catalog) }))
		end
	end
	-- Config rewards list BoostReward tables; Applied results list the boost ids.
	local boosts: { any } = reward.boosts or {}
	for _, boost in boosts do
		if type(boost) == "string" then
			table.insert(lines, Models.label(loc, { "boost." .. boost }, boost))
		elseif type(boost) == "table" then
			local name = Models.label(loc, { "boost." .. tostring(boost.id) }, Models.multiplier(loc, boost.factor))
			table.insert(lines, loc:t("rewards.boost", { boost = name, time = Models.duration(loc, boost.seconds) }))
		end
	end
	return lines
end

-- The first currency a reward pays, for picking an icon.
function Models.rewardCurrency(reward: any): string?
	if type(reward) == "table" and type(reward.currencies) == "table" then
		return sortedKeys(reward.currencies)[1]
	end
	return nil
end

--[[ Shop ]]

-- The same config tables the server's Shop.new got (items, passes, products).
export type Catalog = {
	items: { Shop.ItemDef }?,
	passes: { Shop.PassDef }?,
	products: { Shop.ProductDef }?,
	-- Currency id -> icon asset name, for price and reward icons.
	currencyIcons: { [string]: string }?,
}

function Models.find(list: { any }?, field: string, value: any): any
	local entries: { any } = list or {}
	for _, entry in entries do
		if entry[field] == value then
			return entry
		end
	end
	return nil
end

export type ShopAction = "buy" | "upgrade" | "equip" | "unequip" | "prompt" | "none"

export type ShopCard = {
	kind: "item" | "pass" | "product",
	key: string,
	title: string,
	subtitle: string?,
	icon: string?,
	-- Already formatted: "500" (with priceIcon) or the Robux glyph and "99".
	price: string?,
	priceIcon: string?,
	action: ShopAction,
	actionLabel: string,
	variant: "Primary" | "Secondary" | "Success" | "Gold",
	disabled: boolean,
	-- Why it's disabled, already localized.
	reason: string?,
	rarity: string?,
	-- Crates: one line per possible item with its chance, and the note under them.
	odds: { string }?,
}

export type ShopModel = {
	title: string,
	tabs: { { id: string, label: string } },
	featuredTitle: string,
	featured: { ShopCard },
	featuredEnds: string?,
	cards: { [string]: { ShopCard } },
	empty: string,
	randomItemsAllowed: boolean,
}

Models.SHOP_TABS = table.freeze({ "boosts", "cosmetics", "passes" })

local function orderOf(def: any, index: number): number
	return if type(def.order) == "number" then def.order else index
end

local function sortedDefs(list: { any }?): { any }
	local out: { any } = {}
	local defs: { any } = list or {}
	for index, def in defs do
		table.insert(out, { def = def, order = orderOf(def, index), index = index })
	end
	table.sort(out, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.index < b.index
	end)
	local sorted: { any } = {}
	for _, entry in out do
		table.insert(sorted, entry.def)
	end
	return sorted
end

local function robux(loc: Loc.Loc, price: number): string
	return loc:t("shop.robux", { price = loc:grouped(price) })
end

function Models.itemCard(
	loc: Loc.Loc,
	catalog: Catalog,
	snapshot: any,
	item: Shop.ItemDef,
	balances: { [string]: number }?
): ShopCard
	local level = snapshot.owned[item.id] or 0
	local owned = level > 0
	local equipped = item.slot ~= nil and snapshot.equipped[item.slot] == item.id
	local nextPrice: Shop.Price? = if item.levels then item.levels[level + 1] else (if owned then nil else item.price)
	local card: ShopCard = {
		kind = "item",
		key = item.id,
		title = itemName(loc, item.id, catalog),
		subtitle = if item.levels and owned then loc:t("shop.level", { level = level }) else nil,
		icon = item.icon,
		action = "none",
		actionLabel = loc:t("shop.owned"),
		variant = "Secondary",
		disabled = true,
		rarity = item.rarity,
	}
	if nextPrice then
		card.price = loc:grouped(nextPrice.amount)
		card.priceIcon = if catalog.currencyIcons then catalog.currencyIcons[nextPrice.currency] else nil
		card.action = if owned then "upgrade" else "buy"
		card.actionLabel = loc:t(if owned then "shop.upgrade" else "shop.buy")
		card.variant = "Primary"
		card.disabled = false
		local blocked = snapshot.unavailable[item.id]
		if blocked then
			card.disabled = true
			card.reason = Models.failure(loc, "shop", blocked)
		elseif balances and (balances[nextPrice.currency] or 0) < nextPrice.amount then
			card.disabled = true
			card.reason = Models.failure(loc, "shop", "insufficient")
		end
	elseif owned and item.slot then
		card.action = if equipped then "unequip" else "equip"
		card.actionLabel = loc:t(if equipped then "shop.unequip" else "shop.equip")
		card.variant = if equipped then "Secondary" else "Success"
		card.subtitle = if equipped then loc:t("shop.equipped") else card.subtitle
		card.disabled = false
	elseif item.price == nil and item.levels == nil and not owned then
		card.actionLabel = loc:t("shop.fail.notForSale")
	end
	return card
end

function Models.passCard(loc: Loc.Loc, snapshot: any, pass: Shop.PassDef): ShopCard
	local owned = snapshot.passes[pass.key] == true
	return {
		kind = "pass",
		key = pass.key,
		title = Models.label(loc, { pass.nameKey, "pass." .. pass.key }, pass.key),
		subtitle = Models.label(loc, { pass.descriptionKey, "pass." .. pass.key .. ".description" }, ""),
		icon = pass.icon,
		price = if owned then nil else robux(loc, pass.price),
		action = if owned then "none" else "prompt",
		actionLabel = loc:t(if owned then "shop.owned" else "shop.buy"),
		variant = if owned then "Secondary" else "Gold",
		disabled = owned,
	}
end

function Models.productCard(loc: Loc.Loc, catalog: Catalog, snapshot: any, product: Shop.ProductDef): ShopCard
	local blocked = snapshot.blocked[product.key]
	local card: ShopCard = {
		kind = "product",
		key = product.key,
		title = Models.label(loc, { product.nameKey, "product." .. product.key }, product.key),
		subtitle = Models.label(loc, { product.descriptionKey, "product." .. product.key .. ".description" }, ""),
		icon = product.icon,
		price = robux(loc, product.price),
		action = "prompt",
		actionLabel = loc:t(if product.crate then "shop.openCrate" else "shop.buy"),
		variant = "Gold",
		disabled = blocked ~= nil,
		reason = if blocked then Models.failure(loc, "shop", blocked) else nil,
	}
	if card.subtitle == "" and product.reward then
		card.subtitle = table.concat(Models.rewardLines(loc, product.reward, catalog), ", ")
	end
	if product.crate then
		local lines: { string } = {}
		for _, entry in Shop.oddsOf(product.crate) do
			table.insert(
				lines,
				loc:t(
					"shop.oddsLine",
					{ item = itemName(loc, entry.item, catalog), chance = Models.percent(loc, entry.chance) }
				)
			)
		end
		card.odds = lines
	end
	return card
end

-- Ids of 0 are passes/products not created on Roblox yet: never shown.
local function created(def: any): boolean
	return type(def.id) == "number" and def.id > 0
end

--[[
	The Shop screen. `snapshot` is Shop.GetState / State (Shop:snapshot); `balances` (optional)
	greys out what the player can't afford yet. Boosts are developer products (including crates)
	followed by items in category "Boosts" (currency upgrades); Cosmetics are the other items;
	Passes are game passes.
]]
function Models.shop(
	loc: Loc.Loc,
	catalog: Catalog,
	snapshot: any,
	now: number,
	balances: { [string]: number }?
): ShopModel
	local cards: { [string]: { ShopCard } } = { boosts = {}, cosmetics = {}, passes = {} }
	local byRef: { [string]: ShopCard } = {}
	for _, product in sortedDefs(catalog.products) do
		if created(product) then
			local card = Models.productCard(loc, catalog, snapshot, product)
			table.insert(cards.boosts, card)
			byRef["product:" .. product.key] = card
		end
	end
	for _, item in sortedDefs(catalog.items) do
		if item.price or item.levels or (snapshot.owned[item.id] or 0) > 0 then
			local card = Models.itemCard(loc, catalog, snapshot, item, balances)
			-- Upgrades bought with currency (category "Boosts") sit with the boost products.
			table.insert(if string.lower(item.category) == "boosts" then cards.boosts else cards.cosmetics, card)
			byRef["item:" .. item.id] = card
		end
	end
	for _, pass in sortedDefs(catalog.passes) do
		if created(pass) then
			local card = Models.passCard(loc, snapshot, pass)
			table.insert(cards.passes, card)
			byRef["pass:" .. pass.key] = card
		end
	end
	local featured: { ShopCard } = {}
	for _, ref in snapshot.featured or {} do
		local card = byRef[ref]
		if card then
			table.insert(featured, card)
		end
	end
	local tabs = {}
	for _, id in Models.SHOP_TABS do
		table.insert(tabs, { id = id, label = loc:t("shop.tab." .. id) })
	end
	local endsAt = snapshot.featuredEndsAt
	return {
		title = loc:t("shop.title"),
		tabs = tabs,
		featuredTitle = loc:t("shop.featured"),
		featured = featured,
		featuredEnds = if type(endsAt) == "number" and #featured > 0
			then loc:t("shop.featuredEnds", { time = Models.duration(loc, endsAt - now) })
			else nil,
		cards = cards,
		empty = loc:t("shop.empty"),
		randomItemsAllowed = snapshot.randomItemsAllowed == true,
	}
end

--[[ Rebirth ]]

export type RebirthModel = {
	title: string,
	count: string,
	lose: { string },
	keep: { string },
	bonusesTitle: string,
	bonuses: { { name: string, line: string } },
	milestoneTitle: string?,
	milestone: { string },
	progress: number,
	progressText: string,
	parts: { string },
	canRebirth: boolean,
	confirmLabel: string,
	confirmTitle: string,
	confirmMessage: string,
	failure: string?,
}

function Models.rebirth(loc: Loc.Loc, preview: any, catalog: Catalog?): RebirthModel
	local lose: { string } = {}
	for _, currency in preview.resetsCurrencies or {} do
		table.insert(lose, loc:t("rebirth.loseCurrency", { currency = Models.currency(loc, currency) }))
	end
	local keep: { string } = { loc:t("rebirth.keepDefault") }
	if preview.resetsGates then
		table.insert(lose, loc:t("rebirth.loseGates"))
		if #(preview.keepsGates or {}) > 0 then
			table.insert(keep, loc:t("rebirth.keepGates"))
		end
	end
	local bonuses = {}
	local bonusMap: { [string]: any } = preview.bonuses or {}
	for _, name in sortedKeys(bonusMap) do
		local bonus = bonusMap[name]
		table.insert(bonuses, {
			name = name,
			line = loc:t("rebirth.bonusLine", {
				bonus = Models.label(loc, { "bonus." .. name }, name),
				before = Models.multiplier(loc, bonus.before),
				after = Models.multiplier(loc, bonus.after),
			}),
		})
	end
	local parts: { string } = {}
	for _, part in preview.parts or {} do
		if part.have < part.need then
			table.insert(
				parts,
				loc:t("rebirth.part." .. part.kind, {
					have = loc:grouped(math.min(part.have, part.need)),
					need = loc:grouped(part.need),
					currency = if part.currency then Models.currency(loc, part.currency) else "",
				})
			)
		end
	end
	local milestone = Models.rewardLines(loc, preview.milestone, catalog)
	local progress = math.clamp(preview.progress or 0, 0, 1)
	return {
		title = loc:t("rebirth.title"),
		count = loc:t("rebirth.count", { count = preview.count or 0 }),
		lose = lose,
		keep = keep,
		bonusesTitle = loc:t("rebirth.bonuses"),
		bonuses = bonuses,
		milestoneTitle = if #milestone > 0 then loc:t("rebirth.milestone") else nil,
		milestone = milestone,
		progress = progress,
		progressText = if preview.canRebirth
			then loc:t("rebirth.ready")
			else loc:t("rebirth.progress", { percent = math.floor(progress * 100) }),
		parts = parts,
		canRebirth = preview.canRebirth == true,
		confirmLabel = loc:t("rebirth.confirm"),
		confirmTitle = loc:t("rebirth.confirmTitle"),
		confirmMessage = loc:t("rebirth.confirmMessage"),
		failure = if preview.canRebirth then nil else Models.failure(loc, "rebirth", preview.failure),
	}
end

--[[ Codes ]]

-- The redeem result -> (TextInput variant, helper line, reward lines).
function Models.codeResult(loc: Loc.Loc, result: any, catalog: Catalog?): ("Success" | "Danger", string, { string })
	local ok, value = Models.answer(loc, "codes", result)
	if not ok then
		return "Danger", value :: string, {}
	end
	local lines = Models.rewardLines(loc, value and value.applied, catalog)
	local message = loc:t("codes.success")
	if #lines > 0 then
		message ..= " " .. table.concat(lines, ", ")
	end
	return "Success", message, lines
end

--[[ Leaderboards ]]

export type BoardRow = {
	rank: number?,
	title: string,
	subtitle: string?,
	value: string,
	variant: "Default" | "Pinned" | "Gold" | "Silver" | "Bronze",
	isYou: boolean,
}

export type BoardModel = {
	id: string,
	title: string,
	rows: { BoardRow },
	you: BoardRow,
	resetsIn: string?,
	empty: string?,
}

function Models.boardValue(loc: Loc.Loc, def: any, value: number): string
	local format = def and def.format
	if format == "time" then
		return loc:t("leaderboards.time", { seconds = Models.decimal(loc, value, 2) })
	elseif format == "compact" then
		return loc:compact(value)
	end
	return Models.decimal(loc, value, 2)
end

local MEDALS: { [number]: "Gold" | "Silver" | "Bronze" } = { "Gold", "Silver", "Bronze" }

function Models.leaderboard(loc: Loc.Loc, def: any, answer: any, now: number, localUserId: number): BoardModel
	local id = def.id
	local board = answer and answer.board
	local rows: { BoardRow } = {}
	for _, entry in (board and board.entries) or {} do
		local isYou = entry.userId == localUserId
		table.insert(rows, {
			rank = entry.rank,
			title = entry.displayName or entry.name or tostring(entry.userId),
			subtitle = if entry.name then "@" .. entry.name else nil,
			value = Models.boardValue(loc, def, entry.value),
			variant = if isYou then "Pinned" else (MEDALS[entry.rank] or "Default"),
			isYou = isYou,
		})
	end
	local you = answer and answer.you or {}
	local endsAt = board and board.endsAt
	return {
		id = id,
		title = Models.label(loc, { def.nameKey, "board." .. id }, id),
		rows = rows,
		you = {
			rank = you.rank,
			title = loc:t("leaderboards.you"),
			subtitle = if you.rank == nil then loc:t("leaderboards.unranked") else nil,
			value = if type(you.value) == "number" then Models.boardValue(loc, def, you.value) else "-",
			variant = "Pinned",
			isYou = true,
		},
		resetsIn = if type(endsAt) == "number"
			then loc:t("leaderboards.resetsIn", { time = Models.duration(loc, endsAt - now) })
			else nil,
		empty = if #rows == 0 then loc:t("leaderboards.empty") else nil,
	}
end

--[[ Daily rewards ]]

export type DailyDay = {
	label: string,
	lines: { string },
	icon: string?,
	state: "claimed" | "today" | "upcoming",
}

export type DailyModel = {
	title: string,
	streak: string,
	days: { DailyDay },
	canClaim: boolean,
	buttonLabel: string,
	nextIn: string?,
	broken: string?,
}

function Models.daily(loc: Loc.Loc, status: any, now: number, catalog: Catalog?): DailyModel
	local days: { DailyDay } = {}
	local current = status.day
	for index, reward in status.days or {} do
		local state: "claimed" | "today" | "upcoming"
		if index < current or (index == current and not status.canClaim) then
			state = "claimed"
		elseif index == current then
			state = "today"
		else
			state = "upcoming"
		end
		local currency = Models.rewardCurrency(reward)
		table.insert(days, {
			label = if state == "today" then loc:t("daily.today") else loc:t("daily.day", { day = index }),
			lines = Models.rewardLines(loc, reward, catalog),
			icon = if currency and catalog and catalog.currencyIcons then catalog.currencyIcons[currency] else nil,
			state = state,
		})
	end
	return {
		title = loc:t("daily.title"),
		streak = loc:plural("daily.streak", status.streak or 0),
		days = days,
		canClaim = status.canClaim == true,
		buttonLabel = loc:t(if status.canClaim then "daily.claim" else "daily.claimed"),
		nextIn = if not status.canClaim and type(status.nextAt) == "number"
			then loc:t("daily.nextIn", { time = Models.duration(loc, status.nextAt - now) })
			else nil,
		broken = if status.broken and status.canClaim then loc:t("daily.broken") else nil,
	}
end

--[[ Events ]]

export type EventModel = {
	title: string,
	eventName: string?,
	phase: string,
	status: string,
	-- The countdown alone as a clock ("0:42", see Models.clock), when the phase has an end
	-- time: the chip's last resort.
	timeLeft: string?,
	players: string?,
	needs: string?,
	joined: boolean,
	joinedText: string?,
	action: "join" | "leave" | "none",
	actionLabel: string?,
	placements: { string }?,
}

local function eventName(loc: Loc.Loc, defs: { [string]: any }?, id: string?): string?
	if id == nil then
		return nil
	end
	local def = defs and defs[id]
	return Models.label(loc, { def and def.nameKey, "event." .. id }, id)
end

--[[
	The Event lobby / HUD chip. `state` is Events.State plus `joined`; `defs` maps event id ->
	EventDef (for names); `names` maps userId -> display name for the results lines.
]]
function Models.event(
	loc: Loc.Loc,
	state: any,
	now: number,
	defs: { [string]: any }?,
	names: { [number]: string }?
): EventModel
	local phase = state.phase or "idle"
	local name = eventName(loc, defs, state.eventId)
	local left = if type(state.endsAt) == "number" then Models.duration(loc, state.endsAt - now) else nil
	local clock = if type(state.endsAt) == "number" then Models.clock(loc, state.endsAt - now) else nil
	local status: string
	if phase == "idle" then
		local nextName = eventName(loc, defs, state.nextEventId)
		status = if nextName and left
			then loc:t("events.next", { event = nextName, time = left })
			else loc:t("events.nextUnknown")
	elseif phase == "lobby" then
		status = loc:t("events.startsIn", { time = left or "" })
	elseif phase == "warning" then
		status = loc:t("events.warning", { event = name or "", time = left or "" })
	elseif phase == "running" then
		status = if left then loc:t("events.endsIn", { time = left }) else loc:t("events.running")
	else
		status = loc:t("events.results")
	end
	local count = state.participants or 0
	local players = if phase == "idle"
		then nil
		elseif state.maxPlayers then loc:t("events.playersMax", { count = count, max = state.maxPlayers })
		else loc:plural("events.players", count)
	local joined = state.joined == true and phase ~= "idle"
	local action: "join" | "leave" | "none" = "none"
	if phase == "lobby" then
		action = if joined then "leave" else "join"
	end
	local placements: { string }? = nil
	if phase == "results" and type(state.placements) == "table" then
		local lines: { string } = {}
		for place, userId in state.placements do
			local who = (names and names[userId]) or tostring(userId)
			table.insert(lines, loc:t("events.place", { place = place }) .. " " .. who)
		end
		placements = lines
	end
	return {
		title = loc:t("events.lobby"),
		eventName = name,
		phase = phase,
		status = status,
		timeLeft = clock,
		players = players,
		needs = if phase == "lobby" and count < (state.minPlayers or 1)
			then loc:t("events.needs", { min = state.minPlayers or 1 })
			else nil,
		joined = joined,
		joinedText = if joined then loc:t("events.joined") else nil,
		action = action,
		actionLabel = if action == "join"
			then loc:t("events.join")
			elseif action == "leave" then loc:t("events.leave")
			else nil,
		placements = placements,
	}
end

--[[ Badges ]]

-- The Earned / Announced payload -> the toast's title, text and icon.
function Models.badgeToast(
	loc: Loc.Loc,
	defs: { [string]: any }?,
	payload: any,
	localUserId: number?
): { title: string, text: string, icon: string? }
	local key = payload.key
	local def = defs and defs[key]
	local badge = Models.label(loc, { def and def.nameKey, "badge." .. key }, key)
	if payload.userId and payload.userId ~= localUserId then
		return {
			title = badge,
			text = loc:t("badges.announce", { name = payload.name or "", badge = badge }),
			icon = def and def.icon,
		}
	end
	local description = Models.label(loc, { def and def.descriptionKey, "badge." .. key .. ".description" }, "")
	return {
		title = loc:t("badges.earned"),
		text = if description ~= "" then badge .. ": " .. description else badge,
		icon = def and def.icon,
	}
end

--[[ Purchases ]]

-- Shop.Confirmed payload -> the success toast line.
function Models.purchaseConfirmed(loc: Loc.Loc, catalog: Catalog, payload: any): string
	if payload.kind == "pass" then
		local pass = Models.find(catalog.passes, "key", payload.key)
		local name = Models.label(loc, { pass and pass.nameKey, "pass." .. payload.key }, payload.key)
		return loc:t("shop.passOwned", { pass = name })
	end
	local details = payload.details or {}
	if type(details.item) == "string" then
		return loc:t("shop.bought", { item = itemName(loc, details.item, catalog) })
	end
	return loc:t("shop.thanks")
end

--[[ Tutorial ]]

export type TutorialStep = {
	id: string,
	-- Loc key of the coachmark text.
	textKey: string,
}

function Models.tutorialStep(
	loc: Loc.Loc,
	steps: { TutorialStep },
	index: number
): { text: string, counter: string, next: string, skip: string, last: boolean }
	local step = steps[index]
	local last = index >= #steps
	return {
		text = loc:t(step.textKey),
		counter = loc:t("tutorial.step", { step = index, total = #steps }),
		next = loc:t(if last then "tutorial.done" else "tutorial.next"),
		skip = loc:t("tutorial.skip"),
		last = last,
	}
end

-- Reward lines and type re-exports the builders use.
export type Reward = Types.Reward

return Models
