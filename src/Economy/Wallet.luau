--!strict
--[[
	Economy.Wallet: pure balance math on a Types.Wallet table. No players, signals or clocks, so
	sims and tests can drive it directly.

	Balances never go negative, never pass the currency's cap, and stay whole numbers on integer
	currencies: fractional earnings (2 Wins at 1.25x = 2.5) keep the remainder in `carry` and pay
	it out on a later earn, so long-run totals match the multiplier exactly. The cap limits what a
	player can hold, not what they earned: `lifetime` and `allTime` count every earning in full.
]]

local Types = require("../Types")

export type Currency = Types.Currency
export type Wallet = Types.Wallet
export type CurrencyState = Types.CurrencyState

-- Highest balance any currency may hold. Below 2^53, so integer math stays exact.
local MAX_BALANCE = 1e15
-- Tolerance when flooring, so 0.1 + 0.2 + 0.7 pays out 1, not 0.
local EPSILON = 1e-9

local Wallet = {}

Wallet.MAX_BALANCE = MAX_BALANCE

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

Wallet.isFiniteNumber = isFiniteNumber

-- Highest balance the currency allows: its `max`, at most MAX_BALANCE.
function Wallet.cap(currency: Currency): number
	local max = currency.max
	if max == nil or not isFiniteNumber(max) or max > MAX_BALANCE then
		return MAX_BALANCE
	end
	return math.max(0, max)
end

function Wallet.isInteger(currency: Currency): boolean
	return currency.integer ~= false
end

function Wallet.new(): Wallet
	return { currencies = {}, boosts = {} }
end

local function sanitize(value: any, cap: number, integer: boolean): (number, boolean)
	if not isFiniteNumber(value) then
		return 0, value ~= nil
	end
	local fixed = math.clamp(value, 0, cap)
	if integer then
		fixed = math.floor(fixed)
	end
	return fixed, fixed ~= value
end

--[[
	Makes `wallet` usable with `currencies`: adds missing currencies at their starting balance and
	repairs values a bad write could have left (NaN, negative, over MAX_BALANCE, fractional). A
	balance over the currency's own `max` is kept, since the game may have lowered the max; earns
	add nothing to it until spending brings it under. Unknown currencies are kept as they are;
	unreadable boosts are removed. Returns the problems it fixed, for logging.
]]
function Wallet.normalize(wallet: any, currencies: { Currency }): { string }
	local problems: { string } = {}
	if type(wallet.currencies) ~= "table" then
		if wallet.currencies ~= nil then
			table.insert(problems, "currencies was " .. typeof(wallet.currencies) .. ", reset")
		end
		wallet.currencies = {}
	end
	if type(wallet.boosts) ~= "table" then
		if wallet.boosts ~= nil then
			table.insert(problems, "boosts was " .. typeof(wallet.boosts) .. ", reset")
		end
		wallet.boosts = {}
	end
	for _, currency in currencies do
		local cap = Wallet.cap(currency)
		local integer = Wallet.isInteger(currency)
		local state = wallet.currencies[currency.id]
		if type(state) ~= "table" then
			if state ~= nil then
				table.insert(problems, currency.id .. " was " .. typeof(state) .. ", reset")
			end
			local starting = sanitize(currency.starting or 0, cap, integer)
			wallet.currencies[currency.id] = { balance = starting, lifetime = 0, allTime = 0, carry = 0 }
		else
			for _, field in { "balance", "lifetime", "allTime" } do
				local fixed, changed = sanitize(state[field], MAX_BALANCE, integer)
				if changed then
					table.insert(
						problems,
						string.format(
							"%s.%s was %s, set to %s",
							currency.id,
							field,
							tostring(state[field]),
							tostring(fixed)
						)
					)
				end
				state[field] = fixed
			end
			local carry = state.carry
			state.carry = if isFiniteNumber(carry) and carry >= 0 and carry < 1 then carry else 0
		end
	end
	for id, boost in wallet.boosts do
		if
			type(boost) ~= "table"
			or not isFiniteNumber(boost.factor)
			or boost.factor <= 0
			or not isFiniteNumber(boost.remaining)
			or (boost.currencies ~= nil and type(boost.currencies) ~= "table")
		then
			wallet.boosts[id] = nil
			table.insert(problems, "boost " .. tostring(id) .. " was unreadable and was removed")
		end
	end
	return problems
end

export type EarnResult = {
	-- The earning after the multiplier and any carried fraction (whole on integer currencies).
	earned: number,
	-- Added to the balance: `earned` minus what didn't fit under the cap.
	granted: number,
	-- Lost to the cap.
	clamped: number,
	balance: number,
}

--[[
	Adds `amount * factor` (plus any carried fraction on integer currencies). The balance takes what
	fits under the cap (nothing, when it is already over a lowered cap); `allTime`, and `lifetime`
	when `countsLifetime`, take the whole earning. Callers validate amount >= 0 and factor > 0.
]]
function Wallet.earn(
	wallet: Wallet,
	currency: Currency,
	amount: number,
	factor: number,
	countsLifetime: boolean
): EarnResult
	local state = wallet.currencies[currency.id]
	local cap = Wallet.cap(currency)
	local earned = math.min(math.min(amount, MAX_BALANCE) * factor, MAX_BALANCE)
	if Wallet.isInteger(currency) then
		local raw = earned + state.carry
		earned = math.floor(raw + EPSILON)
		state.carry = math.clamp(raw - earned, 0, 1 - EPSILON)
	end
	local granted = earned
	local clamped = 0
	local room = math.max(0, cap - state.balance)
	if granted > room then
		clamped = granted - room
		granted = room
		state.carry = 0
	end
	state.balance += granted
	if countsLifetime then
		state.lifetime = math.min(MAX_BALANCE, state.lifetime + earned)
	end
	state.allTime = math.min(MAX_BALANCE, state.allTime + earned)
	return { earned = earned, granted = granted, clamped = clamped, balance = state.balance }
end

-- Whether `amount` is a valid price or exact amount for the currency: finite, at least 0, and
-- whole on integer currencies.
function Wallet.validAmount(currency: Currency, amount: any): boolean
	if not isFiniteNumber(amount) or amount < 0 then
		return false
	end
	return not Wallet.isInteger(currency) or amount == math.floor(amount)
end

function Wallet.canAfford(wallet: Wallet, currency: Currency, amount: number): boolean
	local state = wallet.currencies[currency.id]
	return state ~= nil and state.balance >= amount
end

-- Removes `amount`, which the caller checked with validAmount and canAfford. Returns the balance.
function Wallet.spend(wallet: Wallet, currency: Currency, amount: number): number
	local state = wallet.currencies[currency.id]
	state.balance -= amount
	return state.balance
end

-- Sets the balance (and optionally lifetime) outright, clamped to [0, cap] and floored on integer
-- currencies. Clears the carried fraction. Returns the balance.
function Wallet.set(wallet: Wallet, currency: Currency, value: number, lifetime: number?): number
	local state = wallet.currencies[currency.id]
	local integer = Wallet.isInteger(currency)
	state.balance = (sanitize(value, Wallet.cap(currency), integer))
	if lifetime ~= nil then
		state.lifetime = (sanitize(lifetime, MAX_BALANCE, integer))
	end
	state.carry = 0
	return state.balance
end

return Wallet
