--!strict
--[[
	Rewards: one shape (Types.Reward) for everything a player can be handed, applied the same way
	by Codes, Daily, Events, Badges milestones and Rebirth milestones.

	  local reward = { currencies = { Wins = 50 }, items = { "skin_neon" }, ifOwned = { Wins = 25 } }
	  local problems = Rewards.validate(reward, { economy = economy, shop = shop })
	  local result = Rewards.apply({ economy = economy, shop = shop }, player, reward, "code")
	  -- result.currencies.Wins == 50 (or 75 if the skin was already owned)

	Currencies go through economy:earn with the caller's reason, so the reason's kind decides
	whether multipliers apply ("earn") or the amount is exact ("grant"). Items go through the
	shop's grantItem. Boosts go through economy:addBoost. Pure apart from those calls; never
	yields.
]]

local Types = require("./Types")

export type Reward = Types.Reward
export type BoostReward = Types.BoostReward

-- What Rewards.apply needs from a shop (Shop implements it).
export type ItemGranter = {
	hasItem: (self: any, who: any, itemId: string) -> boolean,
	grantItem: (self: any, who: any, itemId: string, reason: string) -> (boolean, string?),
	item: (self: any, itemId: string) -> any,
}

export type Target = {
	economy: any?,
	shop: ItemGranter?,
}

export type Applied = {
	ok: boolean,
	-- Why nothing was applied ("notLoaded", "noEconomy", "noShop", "unknownReason") when ok is
	-- false.
	failure: string?,
	-- Currency id -> amount that reached the balance (after multipliers for earn reasons).
	currencies: { [string]: number },
	items: { string },
	-- Items skipped because the player already owned them.
	duplicates: { string },
	boosts: { string },
}

-- One line of a reward for UI ("+50 Wins", "Neon Stilts", "2x Wins for 30 min").
export type Entry = {
	kind: "currency" | "item" | "boost",
	id: string,
	amount: number?,
	factor: number?,
	seconds: number?,
}

local Rewards = {}

-- Reason kinds that pay currency through economy:earn.
local PAYING: { [string]: boolean } = { earn = true, grant = true }

--[[
	Errors at startup unless `reason` is declared in `economy` with one of `kinds` (default
	"earn" or "grant"). An undeclared reason would make every earn pay 0, and the claim, code or
	event would still be recorded as paid. `owner` names the caller in the message
	("Daily.new"). Does nothing without an economy.
]]
function Rewards.requireReason(economy: any?, reason: string, owner: string, kinds: { string }?)
	if economy == nil then
		return
	end
	local allowed: { string } = kinds or { "earn", "grant" }
	local kind = (economy :: any):reasonKind(reason)
	if kind == nil or table.find(allowed, kind) == nil then
		error(
			string.format(
				"%s: Economy reason %q must be declared as %s (it is %s)",
				owner,
				reason,
				table.concat(allowed, " or "),
				if kind then '"' .. kind .. '"' else "not declared"
			),
			2
		)
	end
end

local function isPositiveNumber(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

function Rewards.isEmpty(reward: Reward?): boolean
	if reward == nil then
		return true
	end
	return next(reward.currencies or {}) == nil and #(reward.items or {}) == 0 and #(reward.boosts or {}) == 0
end

--[[
	Every problem with a reward definition, as readable strings ("currencies.Gems: unknown
	currency"). Empty when it can be applied. `target` is optional; with it, currency and item
	ids are checked against the economy and shop.
]]
function Rewards.validate(reward: any, target: Target?): { string }
	local problems: { string } = {}
	if type(reward) ~= "table" then
		return { "reward must be a table" }
	end
	local t: Target = target or {}
	local function checkCurrencies(field: string, map: any)
		if map == nil then
			return
		end
		if type(map) ~= "table" then
			table.insert(problems, field .. " must be a table")
			return
		end
		for id, amount in map do
			if type(id) ~= "string" then
				table.insert(problems, field .. ": keys must be currency ids")
			elseif not isPositiveNumber(amount) then
				table.insert(problems, field .. "." .. id .. ": amount must be a positive number")
			elseif t.economy and t.economy:currency(id) == nil then
				table.insert(problems, field .. "." .. id .. ": unknown currency")
			end
		end
	end
	for key in reward do
		if key ~= "currencies" and key ~= "items" and key ~= "boosts" and key ~= "ifOwned" then
			table.insert(problems, tostring(key) .. ": unknown field")
		end
	end
	checkCurrencies("currencies", reward.currencies)
	checkCurrencies("ifOwned", reward.ifOwned)
	if reward.items ~= nil then
		if type(reward.items) ~= "table" then
			table.insert(problems, "items must be a list")
		else
			for i, itemId in reward.items do
				if type(itemId) ~= "string" then
					table.insert(problems, "items[" .. tostring(i) .. "] must be an item id")
				elseif t.shop and t.shop:item(itemId) == nil then
					table.insert(problems, "items[" .. tostring(i) .. "]: unknown item " .. itemId)
				end
			end
		end
	end
	if reward.boosts ~= nil then
		if type(reward.boosts) ~= "table" then
			table.insert(problems, "boosts must be a list")
		else
			for i, boost in reward.boosts do
				local at = "boosts[" .. tostring(i) .. "]"
				if type(boost) ~= "table" then
					table.insert(problems, at .. " must be a table")
				else
					if type(boost.id) ~= "string" or #boost.id == 0 then
						table.insert(problems, at .. ".id must be a non-empty string")
					end
					if not isPositiveNumber(boost.factor) then
						table.insert(problems, at .. ".factor must be a positive number")
					end
					if not isPositiveNumber(boost.seconds) then
						table.insert(problems, at .. ".seconds must be a positive number")
					end
				end
			end
		end
	end
	if (reward.items ~= nil or reward.ifOwned ~= nil) and target ~= nil and t.shop == nil then
		table.insert(problems, "items: no shop to grant items")
	end
	if (reward.currencies ~= nil or reward.boosts ~= nil) and target ~= nil and t.economy == nil then
		table.insert(problems, "currencies: no economy to pay them")
	end
	return problems
end

--[[
	Applies a reward. Checks first that the player is loaded in every system the reward touches,
	so a reward is applied whole or not at all. Returns what actually landed.
]]
function Rewards.apply(target: Target, who: any, reward: Reward, reason: string): Applied
	local applied: Applied = { ok = true, currencies = {}, items = {}, duplicates = {}, boosts = {} }
	local economy = target.economy
	local shop = target.shop
	local currencies: { [string]: number } = reward.currencies or {}
	local items: { string } = reward.items or {}
	local boosts: { BoostReward } = reward.boosts or {}
	local eco: any = economy
	local needsEconomy = next(currencies) ~= nil or #boosts > 0 or (reward.ifOwned ~= nil and #items > 0)
	if needsEconomy then
		if economy == nil then
			applied.ok = false
			applied.failure = "noEconomy"
			return applied
		end
		if not economy:isAttached(who) then
			applied.ok = false
			applied.failure = "notLoaded"
			return applied
		end
	end
	if #items > 0 and shop == nil then
		applied.ok = false
		applied.failure = "noShop"
		return applied
	end
	if needsEconomy and not PAYING[eco:reasonKind(reason) or ""] then
		-- earn would pay 0; refuse before anything changes so the caller doesn't record it as paid.
		applied.ok = false
		applied.failure = "unknownReason"
		return applied
	end

	local paid: { [string]: number } = {}
	local function pay(map: { [string]: number })
		for id, amount in map do
			local granted = eco:earn(who, id, amount, reason)
			paid[id] = (paid[id] or 0) + granted
		end
	end

	pay(currencies)
	if shop then
		local ifOwned: { [string]: number } = reward.ifOwned or {}
		for _, itemId in items do
			if shop:hasItem(who, itemId) then
				table.insert(applied.duplicates, itemId)
				pay(ifOwned)
			else
				local ok, failure = shop:grantItem(who, itemId, reason)
				if ok then
					table.insert(applied.items, itemId)
				elseif failure == "owned" then
					table.insert(applied.duplicates, itemId)
					pay(ifOwned)
				end
			end
		end
	end
	for _, boost in boosts do
		eco:addBoost(who, boost.id, boost.factor, boost.seconds, boost.currencies)
		table.insert(applied.boosts, boost.id)
	end
	applied.currencies = paid
	return applied
end

-- The reward as display lines, in a stable order: currencies (by id), items, boosts.
function Rewards.entries(reward: Reward?): { Entry }
	local out: { Entry } = {}
	if reward == nil then
		return out
	end
	local currencies: { [string]: number } = reward.currencies or {}
	local items: { string } = reward.items or {}
	local boosts: { BoostReward } = reward.boosts or {}
	local ids: { string } = {}
	for id in currencies do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		table.insert(out, { kind = "currency", id = id, amount = currencies[id] })
	end
	for _, itemId in items do
		table.insert(out, { kind = "item", id = itemId })
	end
	for _, boost in boosts do
		table.insert(out, { kind = "boost", id = boost.id, factor = boost.factor, seconds = boost.seconds })
	end
	return out
end

-- Adds b's parts to a copy of a (for "what you get from all of today's claims" style summaries).
function Rewards.merge(a: Reward?, b: Reward?): Reward
	local out: Reward = { currencies = {}, items = {}, boosts = {} }
	local currencies = out.currencies :: { [string]: number }
	local items = out.items :: { string }
	local boosts = out.boosts :: { BoostReward }
	for _, reward in { a, b } :: { Reward? } do
		if reward then
			local rc: { [string]: number } = reward.currencies or {}
			local ri: { string } = reward.items or {}
			local rb: { BoostReward } = reward.boosts or {}
			for id, amount in rc do
				currencies[id] = (currencies[id] or 0) + amount
			end
			for _, itemId in ri do
				table.insert(items, itemId)
			end
			for _, boost in rb do
				table.insert(boosts, table.clone(boost))
			end
		end
	end
	return out
end

return Rewards
