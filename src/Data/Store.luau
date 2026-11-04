--!strict
--[[
	Data.Store: session-locked player profiles (brief §3.2).

	  local Profiles = Data.Store.new({
	  	name = "Stilts_Profiles",
	  	version = 1,
	  	template = { wins = 0, lifetimeWins = 0, settings = { music = true } },
	  	migrations = {},
	  })
	  Profiles:bindPlayers()            -- load on join, release on leave, flush on shutdown
	  local profile = Profiles:get(player)
	  if profile then profile.data.wins += 1 end

	Guarantees:
	  * A player is only brand new when a successful read finds no value. A failed read is a
	    failed load: the player is kicked with a friendly message and nothing is written.
	  * One server owns a profile at a time (session lock). Every save checks ownership inside
	    its UpdateAsync transform, so a server that lost the lock can never overwrite newer data.
	  * Saves every 60 s, on leave, and on shutdown (BindToClose), retrying with backoff.
	  * Stored data at an older schema version is migrated on load; data written by a newer
	    version, unreadable data and failed migrations are refused and left untouched.
	  * Purchases are granted at most once per PurchaseId, and only confirmed to Roblox after
	    the grant has been saved.
	  * Data that a DataStore can't hold faithfully (NaN, Vector3, mixed tables, > 4 MB) is never
	    written; the error names the exact path.

	Profile.data is the game's to change freely while the profile is active. Changes made after
	the profile is released are not saved.
]]

local Deep = require("../Util/Deep")
local Document = require("./Document")
local Log = require("../Util/Log")
local Retry = require("./Retry")
local Roblox = require("../Util/Roblox")
local Serialize = require("./Serialize")
local Signal = require("../Signal")
local Types = require("../Types")

export type LoadError =
	"dataStore" -- the DataStore kept failing; nothing was written
	| "locked" -- another server kept the lock past every timeout
	| "corrupt" -- the stored value isn't a profile; left untouched
	| "migration" -- a migration failed; left untouched
	| "newerVersion" -- saved by a newer schema version (this server is out of date)
	| "closing" -- the server is shutting down
	| "left" -- the player left while loading

export type ReleaseReason =
	"left" -- released normally (player left, or releaseAsync)
	| "shutdown" -- released by closeAsync
	| "forceReleased" -- another server asked for the profile (the player joined it)
	| "lockLost" -- another server took the lock; recent changes were not saved
	| "removed" -- removeAsync deleted the profile

export type Profile<T> = {
	userId: number,
	-- DataStore key.
	key: string,
	-- The game's data. Change it freely while the profile is active.
	data: T,
	-- Framework bookkeeping. Read-only for game code.
	meta: Types.ProfileMeta,
	-- Fires once when this server stops owning the profile.
	Released: Signal.Signal<ReleaseReason>,
	isActive: (self: Profile<T>) -> boolean,
	-- Saves now. Autosave and release already cover normal play; call this after something
	-- valuable changes hands. Yields.
	saveAsync: (self: Profile<T>) -> (boolean, string?),
	hasReceipt: (self: Profile<T>, purchaseId: string) -> boolean,
}

export type Decisions = { PurchaseGranted: any, NotProcessedYet: any }

export type StoreOptions<T> = {
	-- DataStore name (at most 50 characters), e.g. "Stilts_Profiles".
	name: string,
	scope: string?,
	-- Data for a brand-new player. Deep-copied per player; must be storable.
	template: T,
	-- Current schema version, an integer >= 1. Default 1.
	version: number?,
	-- migrations[v] turns version v - 1 data into version v. Pure; must not yield.
	migrations: { [number]: (data: any) -> any }?,
	-- Add template keys missing from loaded data. Default true.
	reconcile: boolean?,
	-- DataStore key for a user. Default "Player_<userId>".
	key: ((userId: number) -> string)?,
	-- Seconds between saves of each loaded profile. Default 60.
	autosaveInterval: number?,
	-- A lock whose heartbeat is older than this many seconds belongs to a dead server. Default 600.
	lockTimeout: number?,
	-- Seconds a live owner gets to answer a release request before the lock is taken. Default 40.
	forceReleaseTimeout: number?,
	-- Seconds between attempts while waiting for a lock. Default 5.
	lockRetryInterval: number?,
	-- Seconds processReceipt waits for a profile that is still loading. Default 15.
	receiptWait: number?,
	kickMessages: KickMessages?,

	-- Dependencies. Each defaults to the Roblox service or global.
	dataStoreService: any?,
	-- Used to ask an owner to release at once. false: rely on the owner's next save.
	messagingService: any?,
	players: any?,
	task: any?,
	-- Unix seconds. Default os.time.
	now: (() -> number)?,
	-- Monotonic seconds. Default os.clock.
	clock: (() -> number)?,
	sessionId: string?,
	jobId: string?,
	placeId: number?,
	-- Default Enum.ProductPurchaseDecision.
	decisions: Decisions?,
	-- Default game:BindToClose.
	bindToClose: ((callback: () -> ()) -> ())?,
}

export type KickMessages = {
	loadFailed: string?,
	newerVersion: string?,
	otherServer: string?,
	removed: string?,
}

export type BindOptions = {
	-- Kick players whose data can't load or is taken by another server. Default true.
	kick: boolean?,
	-- Flush every profile on shutdown via BindToClose. Default true.
	bindToClose: boolean?,
}

export type Counters = {
	loads: number,
	newProfiles: number,
	loadFailures: number,
	lockWaits: number,
	locksTakenFromDead: number,
	locksStolen: number,
	saves: number,
	saveFailures: number,
	retries: number,
	releases: number,
	forceReleases: number,
	locksLost: number,
	unstorable: number,
	receiptsGranted: number,
	receiptsDuplicate: number,
	receiptsDeferred: number,
}

export type ErrorEntry = { at: number, op: string, key: string, message: string }

export type ProfileDiagnostics = {
	userId: number,
	key: string,
	loadedAt: number,
	lastSaveAt: number?,
	saveCount: number,
	failedSaves: number,
	lastError: string?,
	-- Approximate stored size in characters, and its share of the 4 MB key limit.
	size: number,
	sizeShare: number,
	schemaVersion: number,
	loadCount: number,
	receipts: number,
	unsavedReceipts: number,
	releasing: boolean,
}

export type StoreDiagnostics = {
	name: string,
	scope: string,
	sessionId: string,
	version: number,
	autosaveInterval: number,
	closing: boolean,
	loaded: number,
	loading: number,
	counters: Counters,
	loadFailuresByReason: { [string]: number },
	profiles: { ProfileDiagnostics },
	-- Newest last, at most 20.
	recentErrors: { ErrorEntry },
	-- DataStore request budgets, when the service reports them.
	budgets: { [string]: number },
}

export type Store<T> = {
	name: string,
	-- (player, profile) after a successful load.
	Loaded: Signal.Signal<Player, Profile<T>>,
	-- (player or nil, profile, reason) when this server stops owning a profile.
	Released: Signal.Signal<Player?, Profile<T>, ReleaseReason>,
	-- (player or nil, profile, receipt) after a purchase was granted and saved. Confirm it to the
	-- client and log it to analytics from here.
	ReceiptGranted: Signal.Signal<Player?, Profile<T>, Types.PurchaseReceipt>,

	-- Loads and locks a player's profile. Yields until loaded or failed.
	loadAsync: (self: Store<T>, player: Player) -> (Profile<T>?, LoadError?),
	get: (self: Store<T>, player: Player) -> Profile<T>?,
	getByUserId: (self: Store<T>, userId: number) -> Profile<T>?,
	isLoaded: (self: Store<T>, player: Player) -> boolean,
	-- Yields until the player's profile is loaded, or nil after `timeout` (default 30) seconds
	-- or a failed load.
	waitForProfileAsync: (self: Store<T>, player: Player, timeout: number?) -> Profile<T>?,
	-- Saves and hands back the lock. Retries in the background if the DataStore is down.
	releaseAsync: (self: Store<T>, player: Player) -> (boolean, string?),
	bindPlayers: (self: Store<T>, options: BindOptions?) -> (),
	-- Releases every profile and refuses new loads. Waits up to `timeout` (default 25) seconds.
	closeAsync: (self: Store<T>, timeout: number?) -> (),

	-- MarketplaceService.ProcessReceipt body. `grant` changes profile.data; return false to
	-- decline for now. It runs at most once per PurchaseId. Must not yield.
	processReceipt: (
		self: Store<T>,
		receipt: Types.PurchaseReceipt,
		grant: (profile: Profile<T>, receipt: Types.PurchaseReceipt) -> boolean?
	) -> any,

	-- Admin and support tools.
	viewAsync: (self: Store<T>, userId: number) -> (Document.Document?, string?),
	updateOfflineAsync: (
		self: Store<T>,
		userId: number,
		edit: (data: any, meta: Types.ProfileMeta) -> boolean?
	) -> (boolean, string?),
	removeAsync: (self: Store<T>, userId: number) -> (boolean, string?),

	getDiagnostics: (self: Store<T>) -> StoreDiagnostics,
}

type Record = {
	profile: Profile<any>,
	player: Player?,
	active: boolean,
	releasing: boolean,
	releaseReason: ReleaseReason,
	busy: boolean,
	timer: thread?,
	loadedAt: number,
	lastSaveAt: number?,
	saveCount: number,
	failedSaves: number,
	lastError: string?,
	size: number,
	warnedSize: boolean,
	-- PurchaseIds granted in memory but not yet saved.
	unsaved: { [string]: boolean },
}

type Loading = {
	done: boolean,
	leaving: boolean,
	profile: Profile<any>?,
	err: LoadError?,
}

local MAX_RECEIPTS = 100
local MAX_RECENT_ERRORS = 20
local RELEASE_RETRY_INTERVAL = 10

local DEFAULT_KICK: { loadFailed: string, newerVersion: string, otherServer: string, removed: string } = {
	loadFailed = "We couldn't load your save, so we stopped here to keep it safe. Nothing was lost. Please rejoin in a minute.",
	newerVersion = "This server is running an older version of the game. Please rejoin to get an updated server.",
	otherServer = "Your save was opened in another server. Please rejoin.",
	removed = "Your save was removed. Please rejoin to start fresh.",
}

local Store = {}

Store.MAX_RECEIPTS = MAX_RECEIPTS

local registry: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function newCounters(): Counters
	return {
		loads = 0,
		newProfiles = 0,
		loadFailures = 0,
		lockWaits = 0,
		locksTakenFromDead = 0,
		locksStolen = 0,
		saves = 0,
		saveFailures = 0,
		retries = 0,
		releases = 0,
		forceReleases = 0,
		locksLost = 0,
		unstorable = 0,
		receiptsGranted = 0,
		receiptsDuplicate = 0,
		receiptsDeferred = 0,
	}
end

local function defaultKey(userId: number): string
	return "Player_" .. tostring(userId)
end

local function findReceipt(receipts: { Types.ReceiptRecord }, purchaseId: string): Types.ReceiptRecord?
	for _, record in receipts do
		if record.purchaseId == purchaseId then
			return record
		end
	end
	return nil
end

function Store.new<T>(options: StoreOptions<T>): Store<T>
	local name = options.name
	assert(type(name) == "string" and #name > 0 and #name <= 50, "Data.Store: name must be 1-50 characters")
	local scope = options.scope
	local version = options.version or 1
	assert(version >= 1 and version == math.floor(version), "Data.Store: version must be an integer >= 1")
	local migrations: { [number]: (data: any) -> any } = options.migrations or {}
	for target in migrations do
		assert(
			type(target) == "number" and target >= 2 and target <= version,
			"Data.Store: migration keys are target versions from 2 to the current version"
		)
	end
	for target = 2, version do
		assert(migrations[target] ~= nil, "Data.Store: missing migration to version " .. tostring(target))
	end
	local template: any = options.template
	assert(type(template) == "table", "Data.Store: template must be a table")
	local storable, badPath, why = Serialize.check(template, "template")
	assert(storable, "Data.Store: template can't be stored: " .. tostring(badPath) .. ": " .. tostring(why))
	local reconcile = options.reconcile ~= false
	local keyFor = options.key or defaultKey
	local autosaveInterval = options.autosaveInterval or 60
	assert(autosaveInterval >= 1, "Data.Store: autosaveInterval must be at least 1 second")
	local lockTimeout = options.lockTimeout or 600
	local forceReleaseTimeout = options.forceReleaseTimeout or 40
	local lockRetryInterval = options.lockRetryInterval or 5
	local receiptWait = options.receiptWait or 15
	local kickOptions: KickMessages = options.kickMessages or {}
	local kickMessages = {
		loadFailed = kickOptions.loadFailed or DEFAULT_KICK.loadFailed,
		newerVersion = kickOptions.newerVersion or DEFAULT_KICK.newerVersion,
		otherServer = kickOptions.otherServer or DEFAULT_KICK.otherServer,
		removed = kickOptions.removed or DEFAULT_KICK.removed,
	}

	local dataStoreService: any = options.dataStoreService or Roblox.service("DataStoreService")
	local dataStore: any = dataStoreService:GetDataStore(name, scope)
	local messagingService: any = nil
	if options.messagingService ~= nil then
		messagingService = if options.messagingService == false then nil else options.messagingService
	elseif Roblox.isRoblox() then
		messagingService = Roblox.service("MessagingService")
	end
	local taskLib: any = options.task or Roblox.task()
	local now: () -> number = options.now or os.time
	local clock: () -> number = options.clock or os.clock
	local sessionId = options.sessionId or Roblox.guid()
	local jobId = options.jobId or Roblox.jobId()
	local placeId = options.placeId or Roblox.placeId()
	local topic = string.sub("RBLXShared.Data." .. name, 1, 80)

	local records: { [number]: Record } = {}
	local byKey: { [string]: Record } = {}
	local loading: { [number]: Loading } = {}
	local closing = false
	local subscribed = false
	local counters = newCounters()
	local failuresByReason: { [string]: number } = {}
	local recentErrors: { ErrorEntry } = {}

	local store = {
		name = name,
		Loaded = Signal.new(),
		Released = Signal.new(),
		ReceiptGranted = Signal.new(),
	} :: Store<any>
	registry[store] = true

	local function sleep(seconds: number)
		taskLib.wait(seconds)
	end

	local function noteError(op: string, key: string, message: string)
		table.insert(recentErrors, { at = now(), op = op, key = key, message = message })
		if #recentErrors > MAX_RECENT_ERRORS then
			table.remove(recentErrors, 1)
		end
	end

	local function retryOptions(attempts: number, op: string, key: string): Retry.Options
		return {
			attempts = attempts,
			baseDelay = 1,
			maxDelay = 8,
			wait = sleep,
			onRetry = function(attempt: number, err: string, delay: number)
				counters.retries += 1
				noteError(op, key, err)
				Log.warn(
					"Data",
					string.format("%s %s failed (try %d), retrying in %gs: %s", op, key, attempt, delay, err)
				)
			end,
		}
	end

	local function loadContext(): Document.LoadContext
		return {
			sessionId = sessionId,
			jobId = jobId,
			placeId = placeId,
			now = now(),
			version = version,
			lockTimeout = lockTimeout,
			forceReleaseTimeout = forceReleaseTimeout,
		}
	end

	-- Per-profile mutual exclusion: one DataStore operation per profile at a time.
	local function acquire(record: Record)
		while record.busy do
			sleep(0.1)
		end
		record.busy = true
	end

	local function deactivate(record: Record, reason: ReleaseReason)
		if not record.active then
			return
		end
		record.active = false
		local timer = record.timer
		record.timer = nil
		if timer and timer ~= coroutine.running() then
			taskLib.cancel(timer)
		end
		local profile = record.profile
		if records[profile.userId] == record then
			records[profile.userId] = nil
		end
		if byKey[profile.key] == record then
			byKey[profile.key] = nil
		end
		counters.releases += 1
		profile.Released:Fire(reason)
		store.Released:Fire(record.player, profile, reason)
	end

	-- (true, size) when `data` can be written as is, else (false, "path: reason").
	local function checkStorable(data: any): (boolean, any)
		local storable, path, reason, size = Serialize.check(data, "data")
		if not storable then
			return false, tostring(path) .. ": " .. tostring(reason)
		end
		if (size :: number) > Serialize.MAX_SIZE then
			return false, "data: about " .. tostring(size) .. " characters, over the 4 MB limit"
		end
		return true, size
	end

	--[[
		Writes the profile. With `release`, also hands back the lock. Caller holds the mutex.

		The transform stores a snapshot of profile.data and the receipts taken when it runs, and
		checks that snapshot, so what is checked is exactly what is written even if the game
		changes the data while the request is in flight. Unstorable data is never written: a
		plain save is cancelled, and a release (or a release another server asked for) hands
		the lock back over the last good save.
	]]
	local function saveLocked(record: Record, release: boolean): (boolean, string?)
		if not record.active then
			return false, "the profile is no longer active"
		end
		local profile = record.profile
		local decision: string? = nil
		local detail: string? = nil
		local problem: string? = nil
		local size = 0
		local included: { string } = {}
		local ok, result = Retry.call(function()
			decision, detail, problem = nil, nil, nil
			return dataStore:UpdateAsync(profile.key, function(old: any): ...any
				local verdict, why = Document.decideSave(old, sessionId, release)
				decision, detail, problem = verdict, why, nil
				if verdict == "lockLost" then
					return nil
				end
				local current = old :: Document.Document
				local data = Deep.copy(profile.data)
				local storable, checked = checkStorable(data)
				if not storable then
					problem = checked
					if verdict == "saved" then
						return nil
					end
					current.meta.session = nil
					return current, { profile.userId }
				end
				size = checked
				included = {}
				for purchaseId in record.unsaved do
					table.insert(included, purchaseId)
				end
				local meta = table.clone(profile.meta)
				meta.receipts = Deep.copy(profile.meta.receipts)
				return Document.forSave(current, data, meta, now(), verdict == "saved"), { profile.userId }
			end)
		end, retryOptions(if release then 5 else 3, if release then "release" else "save", profile.key))

		if not ok then
			local message = tostring(result)
			record.failedSaves += 1
			record.lastError = message
			counters.saveFailures += 1
			noteError(if release then "release" else "save", profile.key, message)
			Log.warn("Data", profile.key .. " save failed after retries: " .. message)
			return false, message
		end
		if decision == "lockLost" then
			counters.locksLost += 1
			record.lastError = "lock lost: " .. tostring(detail)
			noteError("save", profile.key, record.lastError :: string)
			Log.warn("Data", profile.key .. ": " .. tostring(detail) .. "; changes since the last save were not kept")
			deactivate(record, "lockLost")
			return false, "lockLost"
		end

		local message: string? = nil
		if problem then
			message = "can't save: " .. problem
			counters.unstorable += 1
			record.failedSaves += 1
			record.lastError = message
			noteError("save", profile.key, message :: string)
			Log.error("Data", profile.key .. " " .. (message :: string) .. " (the last good save is kept)")
		else
			for _, purchaseId in included do
				record.unsaved[purchaseId] = nil
			end
			record.saveCount += 1
			record.lastSaveAt = now()
			record.size = size
			counters.saves += 1
			if not record.warnedSize and size > Serialize.MAX_SIZE / 2 then
				record.warnedSize = true
				Log.warn("Data", profile.key .. " is over half the 4 MB DataStore limit (" .. tostring(size) .. ")")
			end
		end
		if decision == "released" then
			deactivate(record, record.releaseReason)
		elseif decision == "forceReleased" then
			counters.forceReleases += 1
			deactivate(record, "forceReleased")
		end
		if message then
			return false, message
		end
		return true, nil
	end

	local function save(record: Record, release: boolean): (boolean, string?)
		acquire(record)
		local ok, ok2, err = pcall(saveLocked, record, release)
		record.busy = false
		if not ok then
			-- A bug here must not leave the profile locked forever; report it loudly.
			Log.error("Data", record.profile.key .. " save raised: " .. tostring(ok2))
			return false, tostring(ok2)
		end
		return ok2, err
	end

	-- (Re)arms the profile's single timer: autosave, or a release retry while releasing. A timer
	-- is only ever cancelled before it starts, never in the middle of a save.
	local function schedule(record: Record, delay: number)
		local pending = record.timer
		if pending then
			taskLib.cancel(pending)
		end
		record.timer = taskLib.delay(delay, function()
			record.timer = nil
			if not record.active then
				return
			end
			save(record, record.releasing)
			if record.active and record.timer == nil then
				schedule(record, if record.releasing then RELEASE_RETRY_INTERVAL else autosaveInterval)
			end
		end)
	end

	local function releaseRecord(record: Record, reason: ReleaseReason): (boolean, string?)
		if not record.active then
			return true, nil
		end
		if record.releasing then
			-- Another caller is already releasing; wait for it.
			while record.active and record.busy do
				sleep(0.1)
			end
			return not record.active, nil
		end
		record.releasing = true
		record.releaseReason = reason
		local ok, err = save(record, true)
		if not ok and record.active then
			-- Keep the lock until it can be handed back cleanly; the timer retries.
			schedule(record, RELEASE_RETRY_INTERVAL)
		end
		return ok, err
	end

	local function handleReleaseRequest(key: string)
		local record = byKey[key]
		if record and record.active and not record.releasing then
			taskLib.spawn(save, record, false)
		end
	end

	local function ensureSubscribed()
		if subscribed or messagingService == nil then
			return
		end
		subscribed = true
		local ok, err = pcall(function()
			messagingService:SubscribeAsync(topic, function(message: any)
				local payload = if type(message) == "table" then message.Data else nil
				if type(payload) == "table" and type(payload.key) == "string" and payload.from ~= sessionId then
					handleReleaseRequest(payload.key)
				end
			end)
		end)
		if not ok then
			Log.warn("Data", name .. ": release pings unavailable, relying on autosave: " .. tostring(err))
		end
	end

	local function ping(key: string)
		if messagingService == nil then
			return
		end
		taskLib.spawn(function()
			local ok, err = pcall(function()
				messagingService:PublishAsync(topic, { key = key, from = sessionId })
			end)
			if not ok then
				Log.warn(
					"Data",
					key .. ": release ping failed, the owner will see the request on its next save: " .. tostring(err)
				)
			end
		end)
	end

	-- Hands back a lock we just took without changing the stored data.
	local function returnLock(key: string, userId: number)
		local ok, err = Retry.call(function()
			return dataStore:UpdateAsync(key, function(old: any): ...any
				if Document.decideSave(old, sessionId, true) ~= "released" then
					return nil
				end
				old.meta.session = nil
				return old, { userId }
			end)
		end, retryOptions(5, "release", key))
		if not ok then
			Log.warn("Data", key .. ": couldn't hand back an unused lock: " .. tostring(err))
		end
	end

	local function failLoad(key: string, reason: LoadError, message: string?): (nil, LoadError)
		if reason ~= "left" and reason ~= "closing" then
			counters.loadFailures += 1
			failuresByReason[reason] = (failuresByReason[reason] or 0) + 1
			if message then
				noteError("load", key, message)
			end
		end
		return nil, reason
	end

	local function loadLocked(player: Player, state: Loading): (Profile<any>?, LoadError?)
		local userId = player.UserId
		local key = keyFor(userId)
		local started = clock()
		local deadline = started + forceReleaseTimeout + 60
		while true do
			if closing then
				return failLoad(key, "closing")
			end
			if state.leaving then
				return failLoad(key, "left")
			end
			local decision: string? = nil
			local detail: string? = nil
			local ok, result = Retry.call(function()
				decision, detail = nil, nil
				return dataStore:UpdateAsync(key, function(old: any): ...any
					local ctx = loadContext()
					local verdict, why = Document.decideLoad(old, ctx)
					decision, detail = verdict, why
					if verdict == "create" then
						return Document.new(Deep.copy(template), ctx), { userId }
					elseif verdict == "take" or verdict == "steal" then
						local current = old :: Document.Document
						Document.normalize(current, ctx.now)
						local meta = current.meta
						if meta.schemaVersion < version then
							local migrated, value =
								Document.migrate(current.data, meta.schemaVersion, version, migrations)
							if not migrated then
								decision, detail = nil, tostring(value)
								return nil
							end
							current.data = value
							meta.schemaVersion = version
						end
						if reconcile then
							Document.reconcile(current.data, template)
						end
						local storable, problem = checkStorable(current.data)
						if not storable then
							-- Only a migration can make loaded data unstorable; refuse like a failed one.
							decision, detail = nil, "the migrated data can't be stored: " .. tostring(problem)
							return nil
						end
						meta.session = Document.session(ctx)
						meta.forceRelease = nil
						meta.loadCount += 1
						meta.updatedAt = ctx.now
						return current, { userId }
					elseif verdict == "request" then
						local current = old :: Document.Document
						current.meta.forceRelease = { sessionId = sessionId, requestedAt = ctx.now }
						return current, { userId }
					end
					return nil
				end)
			end, retryOptions(5, "load", key))

			if not ok then
				local message = tostring(result)
				Log.error("Data", key .. " failed to load; the player keeps their saved data: " .. message)
				return failLoad(key, "dataStore", message)
			end
			if decision == nil then
				Log.error("Data", key .. " migration failed; the stored data was left as is: " .. tostring(detail))
				return failLoad(key, "migration", detail)
			elseif decision == "corrupt" then
				Log.error("Data", key .. " is not a readable profile; left untouched: " .. tostring(detail))
				return failLoad(key, "corrupt", detail)
			elseif decision == "newer" then
				Log.warn("Data", key .. " was " .. tostring(detail) .. "; this server runs version " .. version)
				return failLoad(key, "newerVersion", detail)
			elseif decision == "request" or decision == "wait" then
				if decision == "request" then
					ping(key)
				end
				counters.lockWaits += 1
				if clock() >= deadline then
					Log.error("Data", key .. ": another server kept the lock; giving up")
					return failLoad(key, "locked", "lock wait timed out")
				end
				sleep(lockRetryInterval)
				continue
			end

			local doc = result :: Document.Document
			if decision == "create" then
				counters.newProfiles += 1
			elseif decision == "steal" then
				counters.locksStolen += 1
				Log.warn("Data", key .. ": the previous server didn't release in time; took the lock")
			elseif detail == "dead" then
				counters.locksTakenFromDead += 1
			end
			if state.leaving or closing then
				returnLock(key, userId)
				return failLoad(key, if closing then "closing" else "left")
			end

			local record: Record
			local profile = {
				userId = userId,
				key = key,
				data = doc.data,
				meta = doc.meta,
				Released = Signal.new(),
			} :: Profile<any>
			function profile.isActive(_self: Profile<any>): boolean
				return record.active
			end
			function profile.saveAsync(_self: Profile<any>): (boolean, string?)
				return save(record, false)
			end
			function profile.hasReceipt(self: Profile<any>, purchaseId: string): boolean
				return findReceipt(self.meta.receipts, purchaseId) ~= nil
			end
			record = {
				profile = profile,
				player = player,
				active = true,
				releasing = false,
				releaseReason = "left",
				busy = false,
				timer = nil,
				loadedAt = now(),
				lastSaveAt = nil,
				saveCount = 0,
				failedSaves = 0,
				lastError = nil,
				size = Serialize.estimateSize(doc.data) or 0,
				warnedSize = false,
				unsaved = {},
			}
			records[userId] = record
			byKey[key] = record
			counters.loads += 1
			schedule(record, autosaveInterval)
			store.Loaded:Fire(player, profile)
			return profile, nil
		end
	end

	function store.loadAsync(_self: Store<any>, player: Player): (Profile<any>?, LoadError?)
		local userId = player.UserId
		if closing then
			return nil, "closing"
		end
		local existing = records[userId]
		if existing and existing.active and not existing.releasing then
			return existing.profile, nil
		end
		-- A quick rejoin to the same server: let the old session finish handing back first, so
		-- there is never more than one record per player.
		local waitUntil = clock() + forceReleaseTimeout
		while existing and existing.active do
			if clock() >= waitUntil then
				return failLoad(keyFor(userId), "locked", "previous session in this server is still releasing")
			end
			sleep(0.1)
			existing = records[userId]
		end
		local pending = loading[userId]
		if pending then
			while not pending.done do
				sleep(0.1)
			end
			return pending.profile, pending.err
		end
		ensureSubscribed()
		local state: Loading = { done = false, leaving = false, profile = nil, err = nil }
		loading[userId] = state
		local ok, profile, err = pcall(loadLocked, player, state)
		loading[userId] = nil
		state.done = true
		if not ok then
			Log.error("Data", "load of " .. tostring(userId) .. " raised: " .. tostring(profile))
			state.err = "dataStore"
			return nil, "dataStore"
		end
		local reason: LoadError? = err :: any
		state.profile = profile
		state.err = reason
		return profile, reason
	end

	function store.get(_self: Store<any>, player: Player): Profile<any>?
		local record = records[player.UserId]
		return if record and record.active then record.profile else nil
	end

	function store.getByUserId(_self: Store<any>, userId: number): Profile<any>?
		local record = records[userId]
		return if record and record.active then record.profile else nil
	end

	function store.isLoaded(self: Store<any>, player: Player): boolean
		return self:get(player) ~= nil
	end

	function store.waitForProfileAsync(self: Store<any>, player: Player, timeout: number?): Profile<any>?
		local deadline = clock() + (timeout or 30)
		while true do
			local profile = self:get(player)
			if profile then
				return profile
			end
			local pending = loading[player.UserId]
			if pending == nil and records[player.UserId] == nil then
				-- Not loading: either never started or failed.
				return nil
			end
			if clock() >= deadline then
				return nil
			end
			sleep(0.1)
		end
	end

	function store.releaseAsync(_self: Store<any>, player: Player): (boolean, string?)
		local userId = player.UserId
		local pending = loading[userId]
		if pending then
			pending.leaving = true
		end
		local record = records[userId]
		if record == nil then
			return true, nil
		end
		return releaseRecord(record, "left")
	end

	function store.bindPlayers(self: Store<any>, bindOptions: BindOptions?)
		local opts: BindOptions = bindOptions or {}
		local kick = opts.kick ~= false
		local players: any = options.players or Roblox.service("Players")

		local function onJoin(player: Player)
			local profile, err = self:loadAsync(player)
			if profile == nil and kick and err ~= "left" and err ~= "closing" and player.Parent ~= nil then
				player:Kick(if err == "newerVersion" then kickMessages.newerVersion else kickMessages.loadFailed)
			end
		end

		players.PlayerAdded:Connect(function(player: Player)
			taskLib.spawn(onJoin, player)
		end)
		players.PlayerRemoving:Connect(function(player: Player)
			taskLib.spawn(function()
				self:releaseAsync(player)
			end)
		end)
		self.Released:Connect(function(player: Player?, _profile: Profile<any>, reason: ReleaseReason)
			if not kick or player == nil or player.Parent == nil then
				return
			end
			if reason == "forceReleased" or reason == "lockLost" then
				player:Kick(kickMessages.otherServer)
			elseif reason == "removed" then
				player:Kick(kickMessages.removed)
			end
		end)
		for _, player in players:GetPlayers() do
			taskLib.spawn(onJoin, player)
		end
		if opts.bindToClose ~= false then
			local bind = options.bindToClose or Roblox.bindToClose
			bind(function()
				self:closeAsync()
			end)
		end
	end

	function store.closeAsync(_self: Store<any>, timeout: number?)
		closing = true
		local deadline = clock() + (timeout or 25)
		for _, record in records do
			if record.active and not record.releasing then
				taskLib.spawn(releaseRecord, record, "shutdown")
			end
		end
		while (next(records) ~= nil or next(loading) ~= nil) and clock() < deadline do
			sleep(0.25)
		end
		local left = 0
		for _ in records do
			left += 1
		end
		if left > 0 then
			Log.error("Data", name .. ": " .. left .. " profile(s) were not saved before shutdown")
		end
	end

	function store.processReceipt(
		_self: Store<any>,
		receipt: Types.PurchaseReceipt,
		grant: (profile: Profile<any>, receipt: Types.PurchaseReceipt) -> boolean?
	): any
		local decisions: Decisions = options.decisions or Roblox.enum().ProductPurchaseDecision
		local userId = receipt.PlayerId
		local purchaseId = receipt.PurchaseId
		local deadline = clock() + receiptWait
		while loading[userId] ~= nil and clock() < deadline do
			sleep(0.1)
		end
		local record = records[userId]
		if record == nil or not record.active or record.releasing then
			counters.receiptsDeferred += 1
			return decisions.NotProcessedYet
		end
		local profile = record.profile
		if findReceipt(profile.meta.receipts, purchaseId) then
			if not record.unsaved[purchaseId] then
				counters.receiptsDuplicate += 1
				return decisions.PurchaseGranted
			end
			-- Granted here earlier, but that save failed: try to persist it again.
			if save(record, false) and not record.unsaved[purchaseId] then
				return decisions.PurchaseGranted
			end
			counters.receiptsDeferred += 1
			return decisions.NotProcessedYet
		end

		local ok, granted = xpcall(grant :: any, debug.traceback, profile, receipt)
		if not ok then
			Log.error("Data", "grant for purchase " .. purchaseId .. " errored: " .. tostring(granted))
			counters.receiptsDeferred += 1
			return decisions.NotProcessedYet
		end
		if granted == false then
			counters.receiptsDeferred += 1
			return decisions.NotProcessedYet
		end
		local receipts = profile.meta.receipts
		table.insert(receipts, {
			purchaseId = purchaseId,
			productId = receipt.ProductId,
			grantedAt = now(),
		})
		while #receipts > MAX_RECEIPTS do
			table.remove(receipts, 1)
		end
		record.unsaved[purchaseId] = true
		local saved = save(record, false)
		if not saved or record.unsaved[purchaseId] then
			-- Kept in memory, so a retry won't grant twice; Roblox asks again later.
			counters.receiptsDeferred += 1
			return decisions.NotProcessedYet
		end
		counters.receiptsGranted += 1
		Log.info("Data", profile.key .. " granted product " .. tostring(receipt.ProductId) .. " (" .. purchaseId .. ")")
		store.ReceiptGranted:Fire(record.player, profile, receipt)
		return decisions.PurchaseGranted
	end

	function store.viewAsync(_self: Store<any>, userId: number): (Document.Document?, string?)
		local key = keyFor(userId)
		local ok, value = Retry.call(function()
			return dataStore:GetAsync(key)
		end, retryOptions(3, "view", key))
		if not ok then
			return nil, tostring(value)
		end
		return value, nil
	end

	function store.updateOfflineAsync(
		_self: Store<any>,
		userId: number,
		edit: (data: any, meta: Types.ProfileMeta) -> boolean?
	): (boolean, string?)
		local record = records[userId]
		if record and record.active then
			local ok, result = pcall(edit, record.profile.data, record.profile.meta)
			if not ok then
				return false, "edit errored: " .. tostring(result)
			end
			if result == false then
				return false, "cancelled"
			end
			return save(record, false)
		end
		local key = keyFor(userId)
		local failure: string? = nil
		local ok, result = Retry.call(function()
			failure = nil
			return dataStore:UpdateAsync(key, function(old: any): ...any
				if old == nil then
					failure = "notFound"
					return nil
				end
				local readable, why = Document.check(old)
				if not readable then
					failure = "corrupt: " .. tostring(why)
					return nil
				end
				local doc = old :: Document.Document
				local t = now()
				Document.normalize(doc, t)
				local session = doc.meta.session
				if session ~= nil and t - (session.heartbeatAt or 0) < lockTimeout then
					failure = "locked: the player is online in another server"
					return nil
				end
				if doc.meta.schemaVersion > version then
					failure = "newerVersion"
					return nil
				end
				if doc.meta.schemaVersion < version then
					local migrated, value = Document.migrate(doc.data, doc.meta.schemaVersion, version, migrations)
					if not migrated then
						failure = "migration: " .. tostring(value)
						return nil
					end
					doc.data = value
					doc.meta.schemaVersion = version
				end
				local edited, outcome = pcall(edit, doc.data, doc.meta)
				if not edited then
					failure = "edit errored: " .. tostring(outcome)
					return nil
				end
				if outcome == false then
					failure = "cancelled"
					return nil
				end
				local storable, problem = checkStorable(doc.data)
				if not storable then
					failure = "can't save: " .. tostring(problem)
					return nil
				end
				doc.meta.updatedAt = t
				return doc, { userId }
			end)
		end, retryOptions(3, "update", key))
		if not ok then
			return false, tostring(result)
		end
		if failure then
			return false, failure
		end
		return true, nil
	end

	function store.removeAsync(_self: Store<any>, userId: number): (boolean, string?)
		local key = keyFor(userId)
		local record = records[userId]
		if record then
			deactivate(record, "removed")
		end
		local ok, err = Retry.call(function()
			return dataStore:RemoveAsync(key)
		end, retryOptions(5, "remove", key))
		if not ok then
			return false, tostring(err)
		end
		Log.info("Data", key .. " removed")
		return true, nil
	end

	function store.getDiagnostics(_self: Store<any>): StoreDiagnostics
		local profiles: { ProfileDiagnostics } = {}
		local loadingCount = 0
		for _ in loading do
			loadingCount += 1
		end
		for _, record in records do
			local profile = record.profile
			local unsaved = 0
			for _ in record.unsaved do
				unsaved += 1
			end
			table.insert(profiles, {
				userId = profile.userId,
				key = profile.key,
				loadedAt = record.loadedAt,
				lastSaveAt = record.lastSaveAt,
				saveCount = record.saveCount,
				failedSaves = record.failedSaves,
				lastError = record.lastError,
				size = record.size,
				sizeShare = record.size / Serialize.MAX_SIZE,
				schemaVersion = profile.meta.schemaVersion,
				loadCount = profile.meta.loadCount,
				receipts = #profile.meta.receipts,
				unsavedReceipts = unsaved,
				releasing = record.releasing,
			})
		end
		table.sort(profiles, function(a, b)
			return a.userId < b.userId
		end)
		local budgets: { [string]: number } = {}
		if type(dataStoreService.GetRequestBudgetForRequestType) == "function" then
			-- UpdateAsync spends from both of these.
			for _, requestType in { "GetAsync", "SetIncrementAsync" } do
				local ok, budget = pcall(function()
					local enumValue: any = requestType
					if Roblox.isRoblox() then
						enumValue = (Roblox.enum().DataStoreRequestType :: any)[requestType]
					end
					return dataStoreService:GetRequestBudgetForRequestType(enumValue)
				end)
				if ok and type(budget) == "number" then
					budgets[requestType] = budget
				end
			end
		end
		return {
			name = name,
			scope = scope or "global",
			sessionId = sessionId,
			version = version,
			autosaveInterval = autosaveInterval,
			closing = closing,
			loaded = #profiles,
			loading = loadingCount,
			counters = table.clone(counters),
			loadFailuresByReason = table.clone(failuresByReason),
			profiles = profiles,
			recentErrors = Deep.copy(recentErrors),
			budgets = budgets,
		}
	end

	return store :: Store<T>
end

-- Every store created in this server (for the DataDiagnostics panel).
function Store.all(): { Store<any> }
	local list: { Store<any> } = {}
	for store in registry do
		table.insert(list, store)
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
	return list
end

return Store
