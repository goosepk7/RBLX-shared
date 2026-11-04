--!strict
--[[
	Analytics (brief §4): funnel events batched to Roblox Analytics, plus a ring buffer the
	Admin panel reads.

	  local analytics = Shared.Analytics.new()
	  analytics:bindStore(Profiles)       -- join, session length, purchases (from ReceiptGranted)
	  analytics:bindEconomy(economy)      -- currency sources and sinks
	  analytics:onboarding(player, 1, "MovedFirstTime")
	  analytics:progression(player, "World1", "fail", 3, "Gap Walk Hard")
	  analytics:first(player, "win")      -- "first_win" once per player, value = seconds played

	Server only. Calls never yield: events go into a queue that a background loop sends every
	`flushInterval` seconds within Roblox's request budget (120 + 20 x players per minute). A
	full queue drops the oldest event and counts it. Send errors are counted and reported, never
	swallowed silently.

	Per-player state lives in `profile.data.analytics` (field name configurable): first join,
	session count, seconds played, the highest onboarding step and the "first" milestones, so
	one-time events stay one-time across servers.
]]

local Log = require("./Util/Log")
local Roblox = require("./Util/Roblox")
local RobloxSink = require("@self/RobloxSink")
local Signal = require("./Signal")
local Types = require("./Types")

export type Event = RobloxSink.Event
export type Sink = RobloxSink.Sink
export type Fields = { [string]: any } -- string, number or boolean values

export type State = {
	firstJoinAt: number,
	sessions: number,
	playSeconds: number,
	onboardingStep: number,
	purchases: number,
	robuxSpent: number,
	firsts: { [string]: number },
	-- The last receipt counted, so a purchase granted by the release save (after which the
	-- profile can't change) is counted when the player next loads.
	lastPurchaseId: string?,
}

export type Options = {
	sink: Sink?, -- default RobloxSink over AnalyticsService
	enabled: boolean?, -- false keeps the ring buffer but sends nothing (default true)
	field: string?, -- profile.data key, default "analytics"
	bufferSize: number?, -- ring buffer for the Admin panel, default 200
	queueLimit: number?, -- default 1000
	flushInterval: number?, -- seconds, default 5
	budgetBase: number?, -- requests per minute, default 120
	budgetPerPlayer: number?, -- extra per player per minute, default 20
	-- Economy reason -> Roblox transaction type ("IAP", "Shop", "Gameplay", "ContextualPurchase",
	-- "TimedReward", "Onboarding", or any string). Defaults: purchase = IAP, earn = Gameplay,
	-- spend = Shop, grant = Gameplay. Reasons of kind "adjust" (admin, rebirth) are skipped
	-- unless mapped here.
	transactionTypes: { [string]: string }?,
	players: any?,
	task: any?,
	now: (() -> number)?,
	clock: (() -> number)?,
}

export type Diagnostics = {
	enabled: boolean,
	queued: number,
	sent: number,
	failed: number,
	dropped: number,
	byKind: { [string]: number },
	lastError: string?,
	sessions: number,
	budgetPerMinute: number,
}

export type Analytics = {
	Logged: Signal.Signal<Event>,

	track: (self: Analytics, who: any, name: string, value: number?, fields: Fields?) -> (),
	onboarding: (self: Analytics, who: any, step: number, stepName: string, fields: Fields?) -> boolean,
	funnel: (
		self: Analytics,
		who: any,
		funnel: string,
		step: number,
		stepName: string?,
		sessionId: string?,
		fields: Fields?
	) -> (),
	progression: (
		self: Analytics,
		who: any,
		path: string,
		status: "start" | "complete" | "fail",
		level: number,
		levelName: string?,
		fields: Fields?
	) -> (),
	economy: (
		self: Analytics,
		who: any,
		flow: "source" | "sink",
		currency: string,
		amount: number,
		balance: number,
		transactionType: string,
		sku: string?
	) -> (),
	first: (self: Analytics, who: any, milestone: string, fields: Fields?) -> boolean,
	hasFirst: (self: Analytics, who: any, milestone: string) -> boolean,
	purchase: (self: Analytics, who: any, receipt: Types.PurchaseReceipt) -> (),

	attach: (self: Analytics, player: any, getData: () -> any) -> (),
	detach: (self: Analytics, userId: number, reason: string?) -> (),
	bindStore: (self: Analytics, store: any) -> (),
	bindEconomy: (self: Analytics, economy: any) -> (),

	getState: (self: Analytics, who: any) -> State?,
	playSeconds: (self: Analytics, who: any) -> number?,
	getRecent: (self: Analytics, limit: number?, userId: number?) -> { Event },
	getDiagnostics: (self: Analytics) -> Diagnostics,
	setEnabled: (self: Analytics, enabled: boolean) -> (),
	flush: (self: Analytics) -> number,
	destroy: (self: Analytics) -> (),
}

type Session = {
	userId: number,
	player: any,
	getData: () -> any,
	startedAt: number, -- clock()
	baseSeconds: number, -- playSeconds when the session started
}

type Queued = { player: any, event: Event }

local Analytics = {}

Analytics.RobloxSink = RobloxSink

Analytics.DEFAULT_TRANSACTION_TYPES = table.freeze({
	purchase = "IAP",
	earn = "Gameplay",
	spend = "Shop",
	grant = "Gameplay",
})

local NAME_PATTERN = "^[%w_%.%-]+$"
local MAX_NAME = 50

local function userIdOf(who: any): number?
	if type(who) == "number" then
		return who
	end
	if type(who) == "table" or typeof(who) == "Instance" then
		local id = who.UserId
		if type(id) == "number" then
			return id
		end
	end
	return nil
end

-- Which events a full queue sheds first: economy, then custom, then the funnels.
local DROP_RANK: { [string]: number } = { economy = 0, custom = 1 }

function Analytics.newState(at: number): State
	return {
		firstJoinAt = at,
		sessions = 0,
		playSeconds = 0,
		onboardingStep = 0,
		purchases = 0,
		robuxSpent = 0,
		firsts = {},
	}
end

-- Fills fields missing from saved state (older saves, hand edits), so reads never see nil.
local function normalize(state: any, at: number): State
	local fresh = Analytics.newState(at)
	for key, value in fresh :: any do
		if type(state[key]) ~= type(value) then
			state[key] = value
		end
	end
	return state :: State
end

local function stringFields(fields: Fields?): { [string]: string }?
	if fields == nil then
		return nil
	end
	local out: { [string]: string } = {}
	local count = 0
	for key, value in fields do
		count += 1
		out[key] = string.sub(tostring(value), 1, 100)
	end
	if count > RobloxSink.MAX_FIELDS then
		Log.warn("Analytics", `{count} custom fields given; Roblox keeps the first 3 in sorted key order`)
	end
	return out
end

local function checkName(what: string, name: string)
	if type(name) ~= "string" or #name == 0 or #name > MAX_NAME or not string.find(name, NAME_PATTERN) then
		error(`Analytics: {what} must be 1-{MAX_NAME} letters, digits, "_", "." or "-" (got {tostring(name)})`, 3)
	end
end

function Analytics.new(options: Options?): Analytics
	local opts: Options = options or {}
	local sink: Sink = opts.sink or RobloxSink.new()
	local enabled = opts.enabled ~= false
	local field = opts.field or "analytics"
	local bufferSize = opts.bufferSize or 200
	local queueLimit = opts.queueLimit or 1000
	local flushInterval = opts.flushInterval or 5
	local budgetBase = opts.budgetBase or 120
	local budgetPerPlayer = opts.budgetPerPlayer or 20
	local transactionTypes: { [string]: string } = table.clone(Analytics.DEFAULT_TRANSACTION_TYPES :: any)
	for key, value in opts.transactionTypes or {} :: { [string]: string } do
		transactionTypes[key] = value
	end
	local taskLib: any = opts.task
	local now: () -> number = opts.now or os.time
	local clock: () -> number = opts.clock or os.clock
	local playersService: any = opts.players

	local sessions: { [number]: Session } = {}
	local sessionCount = 0
	local queue: { Queued } = {}
	local ring: { Event } = {}
	local ringStart = 1
	local sent, failed, dropped = 0, 0, 0
	local byKind: { [string]: number } = {}
	local lastError: string? = nil
	local reportedErrors = 0
	-- Token bucket over the per-minute budget, refilled each flush.
	local tokens = budgetBase
	local lastRefill = clock()
	local loop: thread? = nil
	local destroyed = false

	local analytics = { Logged = Signal.new() } :: Analytics

	local function budgetPerMinute(): number
		return budgetBase + budgetPerPlayer * sessionCount
	end

	local function remember(event: Event)
		if #ring < bufferSize then
			table.insert(ring, event)
		else
			ring[ringStart] = event
			ringStart = ringStart % bufferSize + 1
		end
	end

	local function stateOf(userId: number): State?
		local session = sessions[userId]
		if session == nil then
			return nil
		end
		local data = session.getData()
		if type(data) ~= "table" then
			return nil
		end
		local state = data[field]
		if type(state) ~= "table" then
			state = Analytics.newState(now())
			data[field] = state
		end
		return normalize(state, now())
	end

	local function currentSeconds(session: Session): number
		return session.baseSeconds + math.max(0, clock() - session.startedAt)
	end

	-- Writes the running session time into the profile, so a save at any moment has it.
	local function commitTime(session: Session)
		local state = stateOf(session.userId)
		if state then
			state.playSeconds = math.floor(currentSeconds(session))
		end
	end

	local function startLoop()
		if loop ~= nil or destroyed then
			return
		end
		taskLib = taskLib or Roblox.task()
		loop = taskLib.spawn(function()
			while not destroyed do
				taskLib.wait(flushInterval)
				if destroyed then
					break
				end
				for _, session in sessions do
					commitTime(session)
				end
				analytics:flush()
			end
		end)
	end

	local function playerFor(userId: number): any
		local session = sessions[userId]
		if session and session.player ~= nil then
			return session.player
		end
		if playersService then
			local ok, player = pcall(function()
				return playersService:GetPlayerByUserId(userId)
			end)
			if ok then
				return player
			end
		end
		return nil
	end

	local function emit(who: any, event: Event)
		byKind[event.kind] = (byKind[event.kind] or 0) + 1
		remember(event)
		analytics.Logged:Fire(event)
		if not enabled then
			return
		end
		local player = if type(who) == "number" then playerFor(who) else who
		if player == nil then
			-- Roblox Analytics needs a Player; an offline user can't be logged.
			dropped += 1
			return
		end
		table.insert(queue, { player = player, event = event })
		if #queue > queueLimit then
			-- Shed the oldest event of the least important kind, so a stream of economy ticks
			-- can't push onboarding, funnel or first-milestone events out of the queue.
			local drop, rank = 1, math.huge
			for i, item in queue do
				local r = DROP_RANK[item.event.kind] or 2
				if r < rank then
					drop, rank = i, r
					if r == 0 then
						break
					end
				end
			end
			table.remove(queue, drop)
			dropped += 1
		end
		startLoop()
	end

	local function base(who: any, kind: any, name: string): Event?
		local userId = userIdOf(who)
		if userId == nil then
			Log.warn("Analytics", `{kind} "{name}": expected a Player or a UserId`)
			return nil
		end
		return { kind = kind, at = now(), userId = userId, name = name }
	end

	function analytics.flush(_self: Analytics): number
		local t = clock()
		local perMinute = budgetPerMinute()
		tokens = math.min(perMinute, tokens + (t - lastRefill) * perMinute / 60)
		lastRefill = t
		local count = 0
		while #queue > 0 and tokens >= 1 do
			local item = table.remove(queue, 1) :: Queued
			tokens -= 1
			local ok, err = pcall(sink :: any, item.player, item.event)
			if ok then
				sent += 1
				count += 1
			else
				failed += 1
				lastError = tostring(err)
				reportedErrors += 1
				-- Report the first few, then every 100th, so a broken sink is loud but not a flood.
				if reportedErrors <= 3 or reportedErrors % 100 == 0 then
					Log.error(
						"Analytics",
						`sending {item.event.kind} "{item.event.name}" failed ({failed} so far): {lastError}`
					)
				end
			end
		end
		return count
	end

	function analytics.track(_self: Analytics, who: any, name: string, value: number?, fields: Fields?)
		checkName("event name", name)
		local event = base(who, "custom", name)
		if event then
			event.value = value
			event.fields = stringFields(fields)
			emit(who, event)
		end
	end

	function analytics.onboarding(_self: Analytics, who: any, step: number, stepName: string, fields: Fields?): boolean
		assert(
			type(step) == "number" and step >= 1 and step == math.floor(step),
			"Analytics: step must be an integer >= 1"
		)
		local event = base(who, "onboarding", "onboarding")
		if event == nil then
			return false
		end
		local state = stateOf(event.userId)
		if state then
			-- Roblox's onboarding funnel counts each step once per player, in order.
			if step <= state.onboardingStep then
				return false
			end
			state.onboardingStep = step
		end
		event.step = step
		event.stepName = stepName
		event.fields = stringFields(fields)
		emit(who, event)
		return true
	end

	function analytics.funnel(
		_self: Analytics,
		who: any,
		funnel: string,
		step: number,
		stepName: string?,
		sessionId: string?,
		fields: Fields?
	)
		checkName("funnel name", funnel)
		local event = base(who, "funnel", funnel)
		if event then
			event.step = step
			event.stepName = stepName
			event.funnelSession = sessionId
			event.fields = stringFields(fields)
			emit(who, event)
		end
	end

	function analytics.progression(
		_self: Analytics,
		who: any,
		path: string,
		status: "start" | "complete" | "fail",
		level: number,
		levelName: string?,
		fields: Fields?
	)
		checkName("progression path", path)
		assert(status == "start" or status == "complete" or status == "fail", "Analytics: bad progression status")
		local event = base(who, "progression", path)
		if event then
			event.status = status
			event.level = level
			event.levelName = levelName
			event.fields = stringFields(fields)
			emit(who, event)
		end
	end

	function analytics.economy(
		_self: Analytics,
		who: any,
		flow: "source" | "sink",
		currency: string,
		amount: number,
		balance: number,
		transactionType: string,
		sku: string?
	)
		local event = base(who, "economy", currency)
		if event then
			event.flow = flow
			event.currency = currency
			event.amount = math.abs(amount)
			event.balance = balance
			event.transactionType = transactionType
			event.sku = sku
			emit(who, event)
		end
	end

	function analytics.hasFirst(_self: Analytics, who: any, milestone: string): boolean
		local userId = userIdOf(who)
		local state = if userId then stateOf(userId) else nil
		return state ~= nil and state.firsts[milestone] ~= nil
	end

	function analytics.first(self: Analytics, who: any, milestone: string, fields: Fields?): boolean
		checkName("milestone", milestone)
		local userId = userIdOf(who)
		if userId == nil then
			return false
		end
		local state = stateOf(userId)
		if state == nil then
			Log.warn("Analytics", `first "{milestone}" for {userId} before their profile loaded; not logged`)
			return false
		end
		if state.firsts[milestone] ~= nil then
			return false
		end
		state.firsts[milestone] = now()
		local seconds = math.floor(currentSeconds(sessions[userId]))
		self:track(who, "first_" .. milestone, seconds, fields)
		return true
	end

	function analytics.purchase(self: Analytics, who: any, receipt: Types.PurchaseReceipt)
		local userId = userIdOf(who) or receipt.PlayerId
		local state = stateOf(userId)
		local robux = if type(receipt.CurrencySpent) == "number" then receipt.CurrencySpent else 0
		if state then
			state.purchases += 1
			state.robuxSpent += robux
			if type(receipt.PurchaseId) == "string" then
				state.lastPurchaseId = receipt.PurchaseId
			end
		end
		self:track(userId, "purchase", robux, { product = tostring(receipt.ProductId) })
		if state then
			self:first(userId, "purchase", { product = tostring(receipt.ProductId) })
		end
	end

	-- Counts receipts stored after the last one analytics saw: a purchase granted by the release
	-- save was logged then, but its counters landed after the final write. The event is not
	-- logged again; robux for those is unknown (receipt records don't keep it).
	local function catchUpPurchases(userId: number?, receipts: { any })
		local state = if userId then stateOf(userId) else nil
		if state == nil or #receipts == 0 then
			return
		end
		local start: number
		if state.lastPurchaseId == nil then
			if state.purchases > 0 then
				return -- counted before receipts were tracked; don't guess
			end
			start = 1
		else
			local found = nil
			for i, r in receipts do
				if r.purchaseId == state.lastPurchaseId then
					found = i
				end
			end
			if found == nil then
				return -- trimmed out of the receipt history; don't guess
			end
			start = found + 1
		end
		for i = start, #receipts do
			local r = receipts[i]
			state.purchases += 1
			state.lastPurchaseId = r.purchaseId
			if state.firsts.purchase == nil then
				state.firsts.purchase = if type(r.grantedAt) == "number" then r.grantedAt else now()
			end
		end
	end

	function analytics.attach(self: Analytics, player: any, getData: () -> any)
		local userId = userIdOf(player)
		assert(userId, "Analytics:attach expects a Player or a UserId")
		local previous = sessions[userId]
		if previous then
			commitTime(previous)
		end
		local session: Session = {
			userId = userId,
			player = if type(player) == "number" then nil else player,
			getData = getData,
			startedAt = clock(),
			baseSeconds = 0,
		}
		if previous == nil then
			sessionCount += 1
		end
		sessions[userId] = session
		local state = stateOf(userId)
		if state == nil then
			return
		end
		session.baseSeconds = state.playSeconds
		if previous == nil then
			state.sessions += 1
			local isNew = state.sessions == 1
			self:track(player, "join", state.sessions, { new = isNew })
		end
		startLoop()
	end

	function analytics.detach(self: Analytics, userId: number, reason: string?)
		local session = sessions[userId]
		if session == nil then
			return
		end
		commitTime(session)
		local seconds = math.floor(currentSeconds(session) - session.baseSeconds)
		self:track(session.player or userId, "session_length", seconds, { reason = reason or "left" })
		-- Send now: on shutdown the loop may never run again.
		self:flush()
		sessions[userId] = nil
		sessionCount -= 1
	end

	function analytics.bindStore(self: Analytics, store: any)
		store.Loaded:Connect(function(player: any, profile: any)
			self:attach(player, function()
				return profile.data
			end)
			local meta = profile.meta
			if type(meta) == "table" and type(meta.receipts) == "table" then
				catchUpPurchases(profile.userId or userIdOf(player), meta.receipts)
			end
		end)
		store.Released:Connect(function(_player: any, profile: any, reason: string)
			local session = sessions[profile.userId]
			if session then
				-- Only this profile's session: a newer profile for the same player stays.
				local ok, data = pcall(session.getData)
				if ok and data == profile.data then
					self:detach(profile.userId, reason)
				end
			end
		end)
		store.ReceiptGranted:Connect(function(player: any, profile: any, receipt: Types.PurchaseReceipt)
			self:purchase(player or profile.userId, receipt)
		end)
		-- Count play time up to the moment of leaving, before the release save.
		local players: any = playersService
		if players == nil and Roblox.isRoblox() then
			players = Roblox.service("Players")
			playersService = players
		end
		if players then
			players.PlayerRemoving:Connect(function(player: any)
				local session = sessions[player.UserId]
				if session then
					commitTime(session)
				end
			end)
			for _, player in players:GetPlayers() do
				local profile = store:get(player)
				if profile and sessions[player.UserId] == nil then
					self:attach(player, function()
						return profile.data
					end)
				end
			end
		end
	end

	function analytics.bindEconomy(self: Analytics, economy: any)
		economy.Transaction:Connect(function(entry: Types.LedgerEntry)
			if entry.delta == 0 then
				return
			end
			local transactionType = transactionTypes[entry.reason] or transactionTypes[entry.kind]
			if transactionType == nil then
				return -- "adjust" (admin, rebirth) unless the game mapped it
			end
			self:economy(
				entry.userId,
				if entry.delta > 0 then "source" else "sink",
				entry.currency,
				entry.delta,
				entry.balance,
				transactionType,
				entry.reason
			)
		end)
	end

	function analytics.getState(_self: Analytics, who: any): State?
		local userId = userIdOf(who)
		return if userId then stateOf(userId) else nil
	end

	function analytics.playSeconds(_self: Analytics, who: any): number?
		local userId = userIdOf(who)
		local session = if userId then sessions[userId] else nil
		return if session then math.floor(currentSeconds(session)) else nil
	end

	function analytics.getRecent(_self: Analytics, limit: number?, userId: number?): { Event }
		local ordered: { Event } = {}
		local n = #ring
		for i = 0, n - 1 do
			table.insert(ordered, ring[(ringStart - 1 + i) % n + 1])
		end
		local out: { Event } = {}
		local max = limit or n
		for i = #ordered, 1, -1 do
			local event = ordered[i]
			if userId == nil or event.userId == userId then
				table.insert(out, table.clone(event))
				if #out >= max then
					break
				end
			end
		end
		return out -- newest first
	end

	function analytics.getDiagnostics(_self: Analytics): Diagnostics
		return {
			enabled = enabled,
			queued = #queue,
			sent = sent,
			failed = failed,
			dropped = dropped,
			byKind = table.clone(byKind),
			lastError = lastError,
			sessions = sessionCount,
			budgetPerMinute = budgetPerMinute(),
		}
	end

	function analytics.setEnabled(_self: Analytics, value: boolean)
		enabled = value
		if not value then
			table.clear(queue)
		end
	end

	function analytics.destroy(_self: Analytics)
		destroyed = true
		analytics.Logged:DisconnectAll()
	end

	return analytics
end

return Analytics
