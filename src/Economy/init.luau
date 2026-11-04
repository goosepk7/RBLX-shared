--!strict
--[[
	Economy: currencies, earning and spending with reasons, stacked multipliers, timed boosts,
	overflow-safe balances and a ledger for analytics (brief §4). Server only; nothing here yields.

	  local economy = Shared.Economy.new({
	  	currencies = { { id = "Wins", displayName = "Wins", leaderstat = true, icon = "icon_wins" } },
	  	reasons = { challenge = "earn", shop = "spend" },
	  })
	  economy:bindStore(Profiles)                        -- wallets live in profile.data.wallet
	  economy:setMultiplier(player, "pass.2xWins", { group = "pass", factor = 2 })
	  local granted = economy:earn(player, "Wins", 4, "challenge")   -- 8 with the pass
	  local ok, err = economy:spend(player, "Wins", 50, "shop")      -- false, "insufficient"

	Reasons are declared up front with a kind:
	  earn    multiplied, counts toward lifetime (challenge rewards, events)
	  grant   exact and whole, never multiplied, doesn't count toward lifetime unless
	          { kind = "grant", lifetime = true } (Robux purchases, codes, refunds: nothing sold
	          for Robux may raise a lifetime gate such as Stilts height)
	  spend   takes from the balance, never below zero
	  adjust  sets a balance outright (admin tools, rebirth resets)

	Multipliers combine by group: bonuses in a group add, groups multiply (rebirth x pass x event x
	boost). Per-player sources (passes, rebirth) are set each session by the module that owns them,
	before or after the wallet loads. Boosts are stored in the wallet and count down only while the
	player is in a server.

	Clients read balances from player attributes (Economy.attributeName) or Economy.observe.
]]

local Log = require("./Util/Log")
local Multipliers = require("@self/Multipliers")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Types = require("./Types")
local Wallet = require("@self/Wallet")

export type Currency = Types.Currency
export type CurrencyId = Types.CurrencyId
export type MultiplierSpec = Types.MultiplierSpec
export type LedgerEntry = Types.LedgerEntry
export type WalletState = Types.Wallet

export type ReasonKind = "earn" | "grant" | "spend" | "adjust"
export type ReasonSpec = { kind: ReasonKind, lifetime: boolean? }

-- Why a transaction did nothing. "insufficient" is normal play; the others are logged as warnings.
export type Failure =
	"notLoaded" -- no wallet attached for that player
	| "unknownCurrency"
	| "unknownReason"
	| "wrongReasonKind" -- e.g. spend with an "earn" reason
	| "invalidAmount" -- NaN, infinite, negative, or fractional where a whole number is needed
	| "insufficient"

export type Options = {
	currencies: { Currency },
	-- Reason name -> a ReasonKind ("earn", "grant", "spend", "adjust") or a ReasonSpec
	-- ({ kind = "grant", lifetime = true }). Merged over the defaults: purchase, code and refund
	-- (grant); admin and rebirth (adjust). Checked when the economy is created.
	reasons: { [string]: any }?,
	-- Groups whose sources multiply each other instead of adding. Default none.
	multiplyWithin: { string }?,
	-- Highest total multiplier. Default 100.
	maxMultiplier: number?,
	-- Field of the profile data that holds the wallet. Default "wallet".
	walletField: string?,
	-- Ledger entries kept per player. Default 50.
	ledgerSize: number?,
	-- Seconds between boost countdown updates. Default 5.
	tickInterval: number?,

	-- Dependencies. Each defaults to the Roblox service or global.
	task: any?,
	-- Unix seconds. Default os.time.
	now: (() -> number)?,
	-- Monotonic seconds. Default os.clock.
	clock: (() -> number)?,
	players: any?,
	-- Makes the player-list value for a currency (its `.Value` is kept in sync). Default: an
	-- IntValue (NumberValue for fractional currencies) in player.leaderstats, inside Roblox only.
	createLeaderstat: ((player: any, currency: Currency) -> any)?,
}

export type Boost = { id: string, factor: number, remaining: number, currencies: { CurrencyId }? }

export type CurrencyTotals = {
	-- Reason -> amount added to balances by earns and grants.
	earned: { [string]: number },
	-- Reason -> amount spent.
	spent: { [string]: number },
	-- Reason -> net change from adjustments.
	adjusted: { [string]: number },
	-- Earned but lost to the cap.
	clamped: number,
}

export type Totals = { [CurrencyId]: CurrencyTotals }

export type PlayerDiagnostics = {
	userId: number,
	balances: { [CurrencyId]: number },
	lifetimes: { [CurrencyId]: number },
	multipliers: { [string]: MultiplierSpec },
	boosts: { Boost },
}

export type Diagnostics = {
	currencies: { CurrencyId },
	attached: number,
	globalMultipliers: { [string]: MultiplierSpec },
	totals: Totals,
	players: { PlayerDiagnostics },
}

export type Economy = {
	-- (player or nil, userId, currency, balance, delta, reason) after every balance change.
	Changed: Signal.Signal<any, number, CurrencyId, number, number, string>,
	-- A copy of every ledger entry, for Analytics. It fires as the change happens, before the
	-- profile saves, so count purchases from the store's ReceiptGranted, which fires once the grant
	-- is saved (a server that stops before saving loses the grant, and the next server grants and
	-- fires Transaction again).
	Transaction: Signal.Signal<LedgerEntry>,
	-- (player or nil, userId) when a boost starts, gains time, ends or is removed.
	BoostsChanged: Signal.Signal<any, number>,

	-- `data` is the profile data table, or a function returning it. The wallet lives at
	-- data[walletField] and is created or repaired as needed.
	attach: (self: Economy, who: any, data: any) -> (),
	detach: (self: Economy, who: any) -> (),
	-- Attaches each profile as Data loads it, detaches it on release, and forgets a player's
	-- multipliers when they leave.
	bindStore: (self: Economy, store: any) -> (),
	isAttached: (self: Economy, who: any) -> boolean,
	currency: (self: Economy, id: CurrencyId) -> Currency?,
	-- The kind a reason was declared with, or nil if it isn't declared. Modules that pay with a
	-- configured reason check it at startup.
	reasonKind: (self: Economy, reason: string) -> ReasonKind?,

	balance: (self: Economy, who: any, currency: CurrencyId) -> number,
	lifetime: (self: Economy, who: any, currency: CurrencyId) -> number,
	allTime: (self: Economy, who: any, currency: CurrencyId) -> number,
	canAfford: (self: Economy, who: any, currency: CurrencyId, amount: number) -> boolean,
	-- Returns what was added to the balance (after multipliers, carry and the cap).
	earn: (self: Economy, who: any, currency: CurrencyId, amount: number, reason: string) -> (number, Failure?),
	spend: (self: Economy, who: any, currency: CurrencyId, amount: number, reason: string) -> (boolean, Failure?),
	-- All or nothing across currencies.
	spendMany: (self: Economy, who: any, costs: { [CurrencyId]: number }, reason: string) -> (boolean, Failure?),
	set: (
		self: Economy,
		who: any,
		currency: CurrencyId,
		value: number,
		reason: string,
		options: { lifetime: number? }?
	) -> (boolean, Failure?),

	multiplier: (self: Economy, who: any, currency: CurrencyId, reason: string) -> number,
	-- The total and each group's factor, for "2.25x from passes" style UI and the Admin panel.
	multiplierBreakdown: (
		self: Economy,
		who: any,
		currency: CurrencyId,
		reason: string
	) -> (number, { [string]: number }),
	-- Sets or (with nil) removes one of a player's multiplier sources. Works before the wallet is
	-- attached.
	setMultiplier: (self: Economy, who: any, id: string, spec: MultiplierSpec?) -> (),
	clearMultipliers: (self: Economy, who: any) -> (),
	setGlobalMultiplier: (self: Economy, id: string, spec: MultiplierSpec?) -> (),

	-- Adds a play-time boost, or adds time to the boost with this id (the new factor applies).
	-- Returns the seconds left. Use one id per boost product.
	addBoost: (
		self: Economy,
		who: any,
		id: string,
		factor: number,
		seconds: number,
		currencies: { CurrencyId }?
	) -> number,
	removeBoost: (self: Economy, who: any, id: string) -> (),
	getBoosts: (self: Economy, who: any) -> { Boost },

	-- Newest last.
	getLedger: (self: Economy, who: any, limit: number?) -> { LedgerEntry },
	-- Server-wide sums per currency and reason since the server started.
	getTotals: (self: Economy) -> Totals,
	getDiagnostics: (self: Economy) -> Diagnostics,
}

type Record = {
	userId: number,
	player: any?,
	getData: () -> any,
	ledger: { LedgerEntry },
	lastTick: number,
	leaderstats: { [CurrencyId]: any },
}

-- A change waiting to be shown and announced once every balance it touches is updated.
type Change = { record: Record, currency: Currency, entry: LedgerEntry }

local DEFAULT_REASONS: { [string]: ReasonKind } = {
	purchase = "grant",
	code = "grant",
	refund = "grant",
	admin = "adjust",
	rebirth = "adjust",
}

local KINDS: { [string]: boolean } = { earn = true, grant = true, spend = true, adjust = true }
local EARN_KINDS: { [string]: boolean } = { earn = true, grant = true }
local SPEND_KINDS: { [string]: boolean } = { spend = true }
local ADJUST_KINDS: { [string]: boolean } = { adjust = true }

local Economy = {}

Economy.MAX_BALANCE = Wallet.MAX_BALANCE
Economy.Wallet = Wallet
Economy.Multipliers = Multipliers

local function safeName(text: string): string
	return (string.gsub(text, "[^%w_]", "_"))
end

-- Player attribute holding a currency's balance, for client UI.
function Economy.attributeName(currency: CurrencyId): string
	return "Currency_" .. safeName(currency)
end

-- Player attribute holding a currency's lifetime total (gates, Stilts height).
function Economy.lifetimeAttributeName(currency: CurrencyId): string
	return "CurrencyLifetime_" .. safeName(currency)
end

-- Player attribute holding the unix time a running boost ends (compare with
-- workspace:GetServerTimeNow()). Removed when the boost ends.
function Economy.boostAttributeName(boostId: string): string
	return "Boost_" .. safeName(boostId)
end

-- A fresh wallet for a Data template: `template = { wallet = Economy.newWallet(), ... }`.
function Economy.newWallet(): WalletState
	return Wallet.new()
end

--[[
	Client side: calls `callback(balance)` now and whenever the balance changes. Returns the
	attribute connection; disconnect it when the UI goes away.
]]
function Economy.observe(player: any, currency: CurrencyId, callback: (balance: number) -> ()): any
	local name = Economy.attributeName(currency)
	local function push()
		local value = player:GetAttribute(name)
		callback(if type(value) == "number" then value else 0)
	end
	local connection = player:GetAttributeChangedSignal(name):Connect(push)
	push()
	return connection
end

local function userIdOf(who: any): number?
	if type(who) == "number" then
		return who
	end
	if type(who) == "table" or typeof(who) == "Instance" then
		local id = (who :: any).UserId
		if type(id) == "number" then
			return id
		end
	end
	return nil
end

local function describe(who: any): string
	return tostring(userIdOf(who) or who)
end

local function normalizeReasons(reasons: { [string]: any }?): { [string]: ReasonSpec }
	local merged: { [string]: ReasonSpec } = {}
	local function add(name: string, value: any)
		local kind: any
		local lifetime: any
		if type(value) == "string" then
			kind = value
		elseif type(value) == "table" then
			kind = value.kind
			lifetime = value.lifetime
		else
			error("Economy.new: reason " .. name .. " must be a kind or { kind = ... }")
		end
		assert(KINDS[kind], "Economy.new: reason " .. name .. " has unknown kind " .. tostring(kind))
		if lifetime == nil then
			lifetime = kind == "earn"
		end
		merged[name] = { kind = kind, lifetime = lifetime == true }
	end
	for name, kind in DEFAULT_REASONS do
		add(name, kind)
	end
	local extra: { [string]: any } = reasons or {}
	for name, value in extra do
		add(name, value)
	end
	return merged
end

local function defaultLeaderstat(player: any, currency: Currency): any
	local folder = player:FindFirstChild("leaderstats")
	if folder == nil then
		folder = (Instance :: any).new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
	end
	local value = folder:FindFirstChild(currency.displayName)
	if value == nil then
		value = (Instance :: any).new(if Wallet.isInteger(currency) then "IntValue" else "NumberValue")
		value.Name = currency.displayName
		value.Parent = folder
	end
	return value
end

function Economy.new(options: Options): Economy
	local currencyList = options.currencies
	assert(type(currencyList) == "table" and #currencyList > 0, "Economy.new: currencies must be a non-empty list")
	local currencies: { [CurrencyId]: Currency } = {}
	local currencyIds: { CurrencyId } = {}
	-- leaderstats values are found by displayName, so two would share one value.
	local leaderstatNames: { [string]: CurrencyId } = {}
	for _, currency in currencyList do
		assert(
			type(currency.id) == "string" and string.match(currency.id, "^[%w_]+$") ~= nil,
			"Economy.new: currency ids are letters, digits and underscores"
		)
		assert(currencies[currency.id] == nil, "Economy.new: duplicate currency " .. currency.id)
		assert(
			type(currency.displayName) == "string",
			"Economy.new: currency " .. currency.id .. " needs a displayName"
		)
		if currency.leaderstat then
			local taken = leaderstatNames[currency.displayName]
			assert(
				taken == nil,
				string.format(
					"Economy.new: leaderstat currencies %s and %s share the displayName %q",
					tostring(taken),
					currency.id,
					currency.displayName
				)
			)
			leaderstatNames[currency.displayName] = currency.id
		end
		assert(
			currency.max == nil or (Wallet.isFiniteNumber(currency.max) and currency.max <= Wallet.MAX_BALANCE),
			"Economy.new: " .. currency.id .. ".max must be at most Economy.MAX_BALANCE"
		)
		currencies[currency.id] = currency
		table.insert(currencyIds, currency.id)
	end
	local reasons = normalizeReasons(options.reasons)
	local multiplyWithin: { [string]: boolean } = {}
	local multiplyList: { string } = options.multiplyWithin or {}
	for _, group in multiplyList do
		multiplyWithin[group] = true
	end
	local maxMultiplier = options.maxMultiplier or 100
	assert(Wallet.isFiniteNumber(maxMultiplier) and maxMultiplier >= 1, "Economy.new: maxMultiplier must be at least 1")
	local walletField = options.walletField or "wallet"
	local ledgerSize = options.ledgerSize or 50
	assert(ledgerSize >= 0 and ledgerSize == math.floor(ledgerSize), "Economy.new: ledgerSize must be a whole number")
	local tickInterval = options.tickInterval or 5
	assert(tickInterval > 0, "Economy.new: tickInterval must be greater than 0")
	local taskLib: any = options.task or Roblox.task()
	local now: () -> number = options.now or os.time
	local clock: () -> number = options.clock or os.clock
	local createLeaderstat = options.createLeaderstat
	if createLeaderstat == nil and Roblox.isRoblox() then
		createLeaderstat = defaultLeaderstat
	end

	local records: { [number]: Record } = {}
	-- Per-player sources, kept apart from the wallet so they can be set before it loads.
	local playerMultipliers: { [number]: { [string]: MultiplierSpec } } = {}
	local globals: { [string]: MultiplierSpec } = {}
	local totals: Totals = {}
	for _, id in currencyIds do
		totals[id] = { earned = {}, spent = {}, adjusted = {}, clamped = 0 }
	end
	local ticking = false

	local economy = {
		Changed = Signal.new(),
		Transaction = Signal.new(),
		BoostsChanged = Signal.new(),
	} :: Economy

	local function report(failure: Failure, detail: string): Failure
		if failure ~= "insufficient" then
			Log.warn("Economy", failure .. ": " .. detail)
		end
		return failure
	end

	-- The wallet in the record's data, created or repaired if game code replaced it.
	local function walletOf(record: Record): WalletState
		local data = record.getData()
		local wallet = data[walletField]
		if type(wallet) ~= "table" then
			wallet = Wallet.new()
			data[walletField] = wallet
		end
		local complete = type(wallet.currencies) == "table" and type(wallet.boosts) == "table"
		if complete then
			for _, id in currencyIds do
				if type(wallet.currencies[id]) ~= "table" then
					complete = false
					break
				end
			end
		end
		if not complete then
			for _, problem in Wallet.normalize(wallet, currencyList) do
				Log.error("Economy", "wallet of " .. record.userId .. ": " .. problem)
			end
		end
		return wallet
	end

	local function setAttribute(record: Record, name: string, value: any)
		local player: any = record.player
		-- Sims may pass stand-in players without attributes.
		if player ~= nil and type(player.SetAttribute) == "function" then
			player:SetAttribute(name, value)
		end
	end

	local function show(record: Record, currency: Currency, state: Types.CurrencyState)
		setAttribute(record, Economy.attributeName(currency.id), state.balance)
		setAttribute(record, Economy.lifetimeAttributeName(currency.id), state.lifetime)
		local stat = record.leaderstats[currency.id]
		if stat ~= nil then
			stat.Value = state.balance
		end
	end

	local function showBoosts(record: Record, wallet: WalletState, removed: { string }?)
		local t = now()
		for id, boost in wallet.boosts do
			setAttribute(record, Economy.boostAttributeName(id), t + boost.remaining)
		end
		local gone: { string } = removed or {}
		for _, id in gone do
			setAttribute(record, Economy.boostAttributeName(id), nil)
		end
	end

	-- Counts boosts down by the play time since the last refresh and drops finished ones.
	local function refresh(record: Record)
		local t = clock()
		local elapsed = t - record.lastTick
		record.lastTick = t
		if elapsed <= 0 then
			return
		end
		local wallet = walletOf(record)
		local ended: { string } = {}
		for id, boost in wallet.boosts do
			boost.remaining -= elapsed
			if boost.remaining <= 0 then
				wallet.boosts[id] = nil
				table.insert(ended, id)
			end
		end
		if #ended > 0 then
			table.sort(ended)
			showBoosts(record, wallet, ended)
			economy.BoostsChanged:Fire(record.player, record.userId)
		end
	end

	local function tick()
		if next(records) == nil then
			ticking = false
			return
		end
		for _, record in records do
			refresh(record)
		end
		taskLib.delay(tickInterval, tick)
	end

	local function ensureTicking()
		if not ticking then
			ticking = true
			taskLib.delay(tickInterval, tick)
		end
	end

	local function recordFor(who: any): Record?
		local userId = userIdOf(who)
		return if userId then records[userId] else nil
	end

	-- Resolves and checks the parts of a transaction. On failure only the failure is returned.
	local function prepare(
		who: any,
		currencyId: CurrencyId,
		reason: string,
		allowed: { [string]: boolean }
	): (Record?, Currency?, ReasonSpec?, Failure?)
		local record = recordFor(who)
		if record == nil then
			return nil, nil, nil, report("notLoaded", "no wallet attached for " .. describe(who))
		end
		local currency = currencies[currencyId]
		if currency == nil then
			return nil, nil, nil, report("unknownCurrency", tostring(currencyId))
		end
		local spec = reasons[reason]
		if spec == nil then
			return nil, nil, nil, report("unknownReason", tostring(reason) .. " (declare it in Economy.new reasons)")
		end
		if not allowed[spec.kind] then
			return nil, nil, nil, report("wrongReasonKind", reason .. " is a " .. spec.kind .. " reason")
		end
		return record, currency, spec, nil
	end

	-- Adds an entry to the player's ledger and the server totals. Signals come later, in announce.
	local function append(record: Record, entry: LedgerEntry)
		table.insert(record.ledger, entry)
		while #record.ledger > ledgerSize do
			table.remove(record.ledger, 1)
		end
		local sums = totals[entry.currency]
		if entry.kind == "earn" or entry.kind == "grant" then
			sums.earned[entry.reason] = (sums.earned[entry.reason] or 0) + entry.delta
		elseif entry.kind == "spend" then
			sums.spent[entry.reason] = (sums.spent[entry.reason] or 0) - entry.delta
		else
			sums.adjusted[entry.reason] = (sums.adjusted[entry.reason] or 0) + entry.delta
		end
		if entry.clamped ~= nil then
			sums.clamped += entry.clamped
		end
	end

	-- Shows and announces changes whose balances are all updated already, so a handler that reacts
	-- to one of them sees the whole transaction.
	local function announce(changes: { Change })
		for _, change in changes do
			local record = change.record
			show(record, change.currency, walletOf(record).currencies[change.currency.id])
		end
		for _, change in changes do
			local entry = change.entry
			if entry.delta ~= 0 then
				economy.Changed:Fire(
					change.record.player,
					entry.userId,
					entry.currency,
					entry.balance,
					entry.delta,
					entry.reason
				)
			end
			economy.Transaction:Fire(table.clone(entry))
		end
	end

	local function sourcesFor(record: Record, wallet: WalletState): { { MultiplierSpec } }
		local perPlayer: { MultiplierSpec } = {}
		for _, spec in playerMultipliers[record.userId] or {} :: { [string]: MultiplierSpec } do
			table.insert(perPlayer, spec)
		end
		local global: { MultiplierSpec } = {}
		for _, spec in globals do
			table.insert(global, spec)
		end
		local boosts: { MultiplierSpec } = {}
		for _, boost in wallet.boosts do
			table.insert(boosts, { group = "boost", factor = boost.factor, currencies = boost.currencies })
		end
		return { perPlayer, global, boosts }
	end

	local function breakdown(record: Record, currencyId: CurrencyId, reason: string): (number, { [string]: number })
		refresh(record)
		local wallet = walletOf(record)
		return Multipliers.combine(sourcesFor(record, wallet), currencyId, reason, now(), multiplyWithin, maxMultiplier)
	end

	function economy.attach(_self: Economy, who: any, data: any)
		local userId = userIdOf(who)
		assert(userId, "Economy:attach expects a Player or a UserId")
		local getData: () -> any
		if type(data) == "function" then
			getData = data
		else
			assert(type(data) == "table", "Economy:attach expects the profile data table")
			getData = function()
				return data
			end
		end
		assert(type(getData()) == "table", "Economy:attach: the profile data must be a table")
		local previous = records[userId]
		local record: Record = {
			userId = userId,
			player = if type(who) == "number" then (if previous then previous.player else nil) else who,
			getData = getData,
			-- The session's ledger carries over when the same player's wallet is attached again.
			ledger = if previous then previous.ledger else {},
			lastTick = clock(),
			leaderstats = {},
		}
		records[userId] = record
		local wallet = getData()[walletField]
		if type(wallet) ~= "table" then
			wallet = Wallet.new()
			getData()[walletField] = wallet
		end
		for _, problem in Wallet.normalize(wallet, currencyList) do
			Log.error("Economy", "wallet of " .. userId .. ": " .. problem)
		end
		if record.player ~= nil and createLeaderstat ~= nil then
			for _, currency in currencyList do
				if currency.leaderstat then
					local ok, stat = pcall(createLeaderstat, record.player, currency)
					if ok then
						record.leaderstats[currency.id] = stat
					else
						Log.error(
							"Economy",
							"couldn't create the leaderstat for " .. currency.id .. ": " .. tostring(stat)
						)
					end
				end
			end
		end
		for _, currency in currencyList do
			show(record, currency, wallet.currencies[currency.id])
		end
		showBoosts(record, wallet)
		ensureTicking()
	end

	function economy.detach(_self: Economy, who: any)
		local record = recordFor(who)
		if record then
			refresh(record)
			records[record.userId] = nil
		end
	end

	function economy.bindStore(self: Economy, store: any)
		store.Loaded:Connect(function(player: any, profile: any)
			self:attach(player, function()
				return profile.data
			end)
		end)
		store.Released:Connect(function(_player: any, profile: any)
			local record = records[profile.userId]
			-- Only this profile's wallet: a newer profile for the same player stays attached.
			if record and record.getData() == profile.data then
				self:detach(profile.userId)
			end
		end)
		local players: any = options.players or Roblox.service("Players")
		players.PlayerRemoving:Connect(function(player: any)
			-- Count boost time up to the moment the player leaves, before the final save.
			local record = recordFor(player)
			if record then
				refresh(record)
			end
			playerMultipliers[player.UserId] = nil
		end)
		for _, player in players:GetPlayers() do
			local profile = store:get(player)
			if profile and not self:isAttached(player) then
				self:attach(player, function()
					return profile.data
				end)
			end
		end
	end

	function economy.isAttached(_self: Economy, who: any): boolean
		return recordFor(who) ~= nil
	end

	function economy.currency(_self: Economy, id: CurrencyId): Currency?
		return currencies[id]
	end

	function economy.reasonKind(_self: Economy, reason: string): ReasonKind?
		local spec = reasons[reason]
		return if spec then spec.kind else nil
	end

	local function stateOf(who: any, currencyId: CurrencyId): Types.CurrencyState?
		local record = recordFor(who)
		if record == nil or currencies[currencyId] == nil then
			return nil
		end
		return walletOf(record).currencies[currencyId]
	end

	function economy.balance(_self: Economy, who: any, currencyId: CurrencyId): number
		local state = stateOf(who, currencyId)
		return if state then state.balance else 0
	end

	function economy.lifetime(_self: Economy, who: any, currencyId: CurrencyId): number
		local state = stateOf(who, currencyId)
		return if state then state.lifetime else 0
	end

	function economy.allTime(_self: Economy, who: any, currencyId: CurrencyId): number
		local state = stateOf(who, currencyId)
		return if state then state.allTime else 0
	end

	function economy.canAfford(_self: Economy, who: any, currencyId: CurrencyId, amount: number): boolean
		local record = recordFor(who)
		local currency = currencies[currencyId]
		if record == nil or currency == nil or not Wallet.validAmount(currency, amount) then
			return false
		end
		return Wallet.canAfford(walletOf(record), currency, amount)
	end

	function economy.earn(
		_self: Economy,
		who: any,
		currencyId: CurrencyId,
		amount: number,
		reason: string
	): (number, Failure?)
		local record: Record?, currency: Currency?, spec: ReasonSpec?, failure: Failure? =
			prepare(who, currencyId, reason, EARN_KINDS)
		if record == nil or currency == nil or spec == nil then
			return 0, failure
		end
		local valid = if spec.kind == "grant"
			then Wallet.validAmount(currency, amount)
			else Wallet.isFiniteNumber(amount) and amount >= 0
		if not valid then
			return 0, report("invalidAmount", tostring(amount) .. " " .. currencyId .. " for " .. reason)
		end
		if amount == 0 then
			return 0, nil
		end
		local factor = if spec.kind == "earn" then (breakdown(record, currencyId, reason)) else 1
		local result = Wallet.earn(walletOf(record), currency, amount, factor, spec.lifetime == true)
		if result.earned == 0 then
			-- Only a fraction, carried to the next earn.
			return 0, nil
		end
		if result.clamped > 0 then
			Log.warn(
				"Economy",
				string.format(
					"%d's %s is at its cap; %s not added",
					record.userId,
					currencyId,
					tostring(result.clamped)
				)
			)
		end
		local entry: LedgerEntry = {
			at = now(),
			userId = record.userId,
			currency = currencyId,
			kind = spec.kind,
			reason = reason,
			delta = result.granted,
			balance = result.balance,
			base = amount,
			multiplier = factor,
			clamped = if result.clamped > 0 then result.clamped else nil,
		}
		append(record, entry)
		announce({ { record = record, currency = currency, entry = entry } })
		return result.granted, nil
	end

	-- Checks one spend without changing anything.
	local function checkSpend(
		who: any,
		currencyId: CurrencyId,
		amount: number,
		reason: string
	): (Record?, Currency?, Failure?)
		local record: Record?, currency: Currency?, _, failure: Failure? = prepare(who, currencyId, reason, SPEND_KINDS)
		if record == nil or currency == nil then
			return nil, nil, failure
		end
		if not Wallet.validAmount(currency, amount) then
			return nil, nil, report("invalidAmount", tostring(amount) .. " " .. currencyId .. " for " .. reason)
		end
		if not Wallet.canAfford(walletOf(record), currency, amount) then
			return nil, nil, "insufficient"
		end
		return record, currency, nil
	end

	local function applySpend(record: Record, currency: Currency, amount: number, reason: string): Change
		local balance = Wallet.spend(walletOf(record), currency, amount)
		local entry: LedgerEntry = {
			at = now(),
			userId = record.userId,
			currency = currency.id,
			kind = "spend",
			reason = reason,
			delta = -amount,
			balance = balance,
		}
		append(record, entry)
		return { record = record, currency = currency, entry = entry }
	end

	function economy.spend(
		_self: Economy,
		who: any,
		currencyId: CurrencyId,
		amount: number,
		reason: string
	): (boolean, Failure?)
		local record: Record?, currency: Currency?, failure: Failure? = checkSpend(who, currencyId, amount, reason)
		if record == nil or currency == nil then
			return false, failure
		end
		if amount > 0 then
			announce({ applySpend(record, currency, amount, reason) })
		end
		return true, nil
	end

	function economy.spendMany(
		_self: Economy,
		who: any,
		costs: { [CurrencyId]: number },
		reason: string
	): (boolean, Failure?)
		assert(type(costs) == "table", "Economy:spendMany expects { [currency] = amount }")
		local order: { CurrencyId } = {}
		for currencyId in costs do
			table.insert(order, currencyId)
		end
		table.sort(order)
		local checked: { { record: Record, currency: Currency, amount: number } } = {}
		for _, currencyId in order do
			local amount = costs[currencyId]
			local record: Record?, currency: Currency?, failure: Failure? = checkSpend(who, currencyId, amount, reason)
			if record == nil or currency == nil then
				return false, failure
			end
			if amount > 0 then
				table.insert(checked, { record = record, currency = currency, amount = amount })
			end
		end
		local changes: { Change } = {}
		for _, item in checked do
			table.insert(changes, applySpend(item.record, item.currency, item.amount, reason))
		end
		announce(changes)
		return true, nil
	end

	function economy.set(
		_self: Economy,
		who: any,
		currencyId: CurrencyId,
		value: number,
		reason: string,
		setOptions: { lifetime: number? }?
	): (boolean, Failure?)
		local record: Record?, currency: Currency?, _, failure: Failure? =
			prepare(who, currencyId, reason, ADJUST_KINDS)
		if record == nil or currency == nil then
			return false, failure
		end
		local opts: { lifetime: number? } = setOptions or {}
		local lifetime = opts.lifetime
		if
			not Wallet.validAmount(currency, value) or (lifetime ~= nil and not Wallet.validAmount(currency, lifetime))
		then
			return false, report("invalidAmount", tostring(value) .. " " .. currencyId .. " for " .. reason)
		end
		local wallet = walletOf(record)
		local before = wallet.currencies[currencyId].balance
		local balance = Wallet.set(wallet, currency, value, lifetime)
		local entry: LedgerEntry = {
			at = now(),
			userId = record.userId,
			currency = currencyId,
			kind = "adjust",
			reason = reason,
			delta = balance - before,
			balance = balance,
		}
		append(record, entry)
		announce({ { record = record, currency = currency, entry = entry } })
		return true, nil
	end

	function economy.multiplier(_self: Economy, who: any, currencyId: CurrencyId, reason: string): number
		local record = recordFor(who)
		if record == nil then
			return 1
		end
		return (breakdown(record, currencyId, reason))
	end

	function economy.multiplierBreakdown(
		_self: Economy,
		who: any,
		currencyId: CurrencyId,
		reason: string
	): (number, { [string]: number })
		local record = recordFor(who)
		if record == nil then
			return 1, {}
		end
		return breakdown(record, currencyId, reason)
	end

	local function checked(spec: MultiplierSpec): MultiplierSpec
		local ok, problem = Multipliers.validate(spec)
		assert(ok, "Economy: " .. tostring(problem))
		local copy = table.clone(spec)
		copy.currencies = if spec.currencies then table.clone(spec.currencies) else nil
		copy.reasons = if spec.reasons then table.clone(spec.reasons) else nil
		return copy
	end

	function economy.setMultiplier(_self: Economy, who: any, id: string, spec: MultiplierSpec?)
		local userId = userIdOf(who)
		assert(userId, "Economy:setMultiplier expects a Player or a UserId")
		local sources = playerMultipliers[userId]
		if spec == nil then
			if sources then
				sources[id] = nil
			end
			return
		end
		if sources == nil then
			sources = {}
			playerMultipliers[userId] = sources
		end
		sources[id] = checked(spec)
	end

	function economy.clearMultipliers(_self: Economy, who: any)
		local userId = userIdOf(who)
		if userId then
			playerMultipliers[userId] = nil
		end
	end

	function economy.setGlobalMultiplier(_self: Economy, id: string, spec: MultiplierSpec?)
		if spec then
			globals[id] = checked(spec)
		else
			globals[id] = nil
		end
	end

	function economy.addBoost(
		_self: Economy,
		who: any,
		id: string,
		factor: number,
		seconds: number,
		boostCurrencies: { CurrencyId }?
	): number
		assert(Wallet.isFiniteNumber(factor) and factor > 0, "Economy:addBoost: factor must be greater than 0")
		assert(Wallet.isFiniteNumber(seconds) and seconds > 0, "Economy:addBoost: seconds must be greater than 0")
		local record = recordFor(who)
		if record == nil then
			report("notLoaded", "addBoost " .. id .. " for " .. describe(who))
			return 0
		end
		refresh(record)
		local wallet = walletOf(record)
		local existing = wallet.boosts[id]
		local remaining = seconds + (if existing then existing.remaining else 0)
		wallet.boosts[id] = {
			factor = factor,
			remaining = remaining,
			currencies = if boostCurrencies then table.clone(boostCurrencies) else nil,
		}
		showBoosts(record, wallet)
		economy.BoostsChanged:Fire(record.player, record.userId)
		return remaining
	end

	function economy.removeBoost(_self: Economy, who: any, id: string)
		local record = recordFor(who)
		if record == nil then
			return
		end
		local wallet = walletOf(record)
		if wallet.boosts[id] ~= nil then
			wallet.boosts[id] = nil
			showBoosts(record, wallet, { id })
			economy.BoostsChanged:Fire(record.player, record.userId)
		end
	end

	function economy.getBoosts(_self: Economy, who: any): { Boost }
		local record = recordFor(who)
		if record == nil then
			return {}
		end
		refresh(record)
		local list: { Boost } = {}
		for id, boost in walletOf(record).boosts do
			table.insert(list, {
				id = id,
				factor = boost.factor,
				remaining = boost.remaining,
				currencies = if boost.currencies then table.clone(boost.currencies) else nil,
			})
		end
		table.sort(list, function(a, b)
			return a.id < b.id
		end)
		return list
	end

	function economy.getLedger(_self: Economy, who: any, limit: number?): { LedgerEntry }
		local record = recordFor(who)
		if record == nil then
			return {}
		end
		local ledger = record.ledger
		local first = math.max(1, #ledger - (limit or #ledger) + 1)
		local list: { LedgerEntry } = {}
		for index = first, #ledger do
			table.insert(list, table.clone(ledger[index]))
		end
		return list
	end

	local function copyTotals(): Totals
		local copy: Totals = {}
		for id, sums in totals do
			copy[id] = {
				earned = table.clone(sums.earned),
				spent = table.clone(sums.spent),
				adjusted = table.clone(sums.adjusted),
				clamped = sums.clamped,
			}
		end
		return copy
	end

	function economy.getTotals(_self: Economy): Totals
		return copyTotals()
	end

	function economy.getDiagnostics(self: Economy): Diagnostics
		local players: { PlayerDiagnostics } = {}
		local attached = 0
		for userId in records do
			attached += 1
			local balances: { [CurrencyId]: number } = {}
			local lifetimes: { [CurrencyId]: number } = {}
			for _, id in currencyIds do
				balances[id] = self:balance(userId, id)
				lifetimes[id] = self:lifetime(userId, id)
			end
			local multipliers: { [string]: MultiplierSpec } = {}
			for id, spec in playerMultipliers[userId] or {} :: { [string]: MultiplierSpec } do
				multipliers[id] = table.clone(spec)
			end
			table.insert(players, {
				userId = userId,
				balances = balances,
				lifetimes = lifetimes,
				multipliers = multipliers,
				boosts = self:getBoosts(userId),
			})
		end
		table.sort(players, function(a, b)
			return a.userId < b.userId
		end)
		local global: { [string]: MultiplierSpec } = {}
		for id, spec in globals do
			global[id] = table.clone(spec)
		end
		return {
			currencies = table.clone(currencyIds),
			attached = attached,
			globalMultipliers = global,
			totals = copyTotals(),
			players = players,
		}
	end

	return economy
end

return Economy
