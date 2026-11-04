--!strict
--[[
	In-memory DataStoreService with the semantics Data relies on, plus failure injection.

	  local dss = T.Fakes.DataStoreService.new()
	  local store = dss:GetDataStore("Profiles")
	  store:SetAsync("u_1", { coins = 5 })
	  dss:failNext("GetAsync", { code = 503, times = 2 })  -- next two GetAsync calls error

	Fidelity notes:
	  * Values are deep-copied on write and on read, and must be DataStore-serializable
	    (no functions/userdata/threads, no NaN/inf, no mixed or sparse arrays, string keys or
	    1..n array keys only, encoded size <= 4,194,303 characters).
	  * Errors are raised as Roblox-style strings starting with the numeric code: "502: ...".
	  * UpdateAsync(key, transform) calls transform(oldValue, keyInfo); returning nil cancels
	    the write and UpdateAsync returns nil. Returns (newValue, keyInfo) on success.
	  * Versions are monotonically increasing strings per key, like Roblox.
	  * One service instance can be shared by several simulated servers to test session locks.
]]

export type KeyInfo = {
	Version: string,
	CreatedTime: number,
	UpdatedTime: number,
	GetMetadata: (self: KeyInfo) -> { [string]: any },
	GetUserIds: (self: KeyInfo) -> { number },
}

export type SetOptions = {
	SetMetadata: (self: SetOptions, metadata: { [string]: any }) -> (),
	GetMetadata: (self: SetOptions) -> { [string]: any },
}

export type FailureSpec = {
	code: number?,
	message: string?,
	times: number?,
	key: string?,
	store: string?,
}

export type CallRecord = { method: string, store: string, key: string?, ok: boolean, error: string? }

export type FakeDataStore = {
	Name: string,
	GetAsync: (self: FakeDataStore, key: string) -> (any, KeyInfo?),
	SetAsync: (self: FakeDataStore, key: string, value: any, userIds: { number }?, options: SetOptions?) -> string,
	UpdateAsync: (self: FakeDataStore, key: string, transform: (any, KeyInfo?) -> ...any) -> (any, KeyInfo?),
	RemoveAsync: (self: FakeDataStore, key: string) -> (any, KeyInfo?),
	IncrementAsync: (self: FakeDataStore, key: string, delta: number?, userIds: { number }?) -> number,
}

export type OrderedEntry = { key: string, value: number }

export type FakePages = {
	IsFinished: boolean,
	GetCurrentPage: (self: FakePages) -> { OrderedEntry },
	AdvanceToNextPageAsync: (self: FakePages) -> (),
}

export type FakeOrderedDataStore = {
	Name: string,
	GetAsync: (self: FakeOrderedDataStore, key: string) -> number?,
	SetAsync: (self: FakeOrderedDataStore, key: string, value: number) -> (),
	UpdateAsync: (self: FakeOrderedDataStore, key: string, transform: (number?) -> number?) -> number?,
	IncrementAsync: (self: FakeOrderedDataStore, key: string, delta: number?) -> number,
	RemoveAsync: (self: FakeOrderedDataStore, key: string) -> number?,
	GetSortedAsync: (
		self: FakeOrderedDataStore,
		ascending: boolean,
		pageSize: number,
		minValue: number?,
		maxValue: number?
	) -> FakePages,
}

export type FakeDataStoreService = {
	GetDataStore: (self: FakeDataStoreService, name: string, scope: string?) -> FakeDataStore,
	GetOrderedDataStore: (self: FakeDataStoreService, name: string, scope: string?) -> FakeOrderedDataStore,
	GetRequestBudgetForRequestType: (self: FakeDataStoreService, requestType: any) -> number,

	-- Test controls
	failNext: (self: FakeDataStoreService, method: string, spec: FailureSpec?) -> (),
	setFailureRate: (self: FakeDataStoreService, probability: number, seed: number?) -> (),
	setBudget: (self: FakeDataStoreService, budget: number) -> (),
	setNow: (self: FakeDataStoreService, now: () -> number) -> (),
	newSetOptions: (self: FakeDataStoreService) -> SetOptions,
	inspect: (self: FakeDataStoreService, store: string, key: string, scope: string?) -> any,
	seed: (self: FakeDataStoreService, store: string, key: string, value: any, scope: string?) -> (),
	versionOf: (self: FakeDataStoreService, store: string, key: string, scope: string?) -> string?,
	calls: (self: FakeDataStoreService, method: string?) -> { CallRecord },
	clearCalls: (self: FakeDataStoreService) -> (),
	reset: (self: FakeDataStoreService) -> (),
}

type Entry = {
	value: any,
	version: number,
	created: number,
	updated: number,
	metadata: { [string]: any },
	userIds: { number },
}

local MAX_VALUE_CHARS = 4_194_303
local MAX_KEY_CHARS = 50

local DataStoreService = {}

local function isArray(t: { [any]: any }): (boolean, number)
	local count = 0
	for _ in t do
		count += 1
	end
	if count == 0 then
		return true, 0
	end
	for i = 1, count do
		if t[i] == nil then
			return false, count
		end
	end
	return true, count
end

-- Validates serializability and returns an approximate JSON size.
local function validate(value: any, path: string, seen: { [any]: boolean }): number
	local kind = type(value)
	if kind == "nil" then
		return 4
	elseif kind == "boolean" then
		return 5
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error(string.format("104: Cannot store NaN or infinite number at %s", path), 0)
		end
		return #tostring(value)
	elseif kind == "string" then
		return #value + 2
	elseif kind == "table" then
		if seen[value] then
			error(string.format("104: Cannot store cyclic table at %s", path), 0)
		end
		seen[value] = true
		local array = isArray(value)
		local size = 2
		for key, child in value do
			if array then
				size += validate(child, path .. "[" .. tostring(key) .. "]", seen) + 1
			else
				if type(key) ~= "string" then
					error(
						string.format(
							"104: Cannot store mixed or non-string-keyed table at %s (key %s)",
							path,
							tostring(key)
						),
						0
					)
				end
				size += #key + 3 + validate(child, path .. "." .. key, seen) + 1
			end
		end
		seen[value] = nil
		return size
	end
	error(string.format("104: Cannot store value of type %s at %s", kind, path), 0)
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value do
		copy[key] = deepCopy(child)
	end
	return copy
end

local function makeKeyInfo(entry: Entry): KeyInfo
	local metadata = deepCopy(entry.metadata)
	local userIds = table.clone(entry.userIds)
	local info = {
		Version = tostring(entry.version),
		CreatedTime = entry.created,
		UpdatedTime = entry.updated,
	} :: any
	function info.GetMetadata(_self: KeyInfo)
		return deepCopy(metadata)
	end
	function info.GetUserIds(_self: KeyInfo)
		return table.clone(userIds)
	end
	return info :: KeyInfo
end

function DataStoreService.new(): FakeDataStoreService
	-- storage[scopedStoreName][key] = Entry
	local storage: { [string]: { [string]: Entry } } = {}
	local ordered: { [string]: { [string]: number } } = {}
	local failures: { { method: string, spec: FailureSpec, remaining: number } } = {}
	local failureRate = 0
	local rngState = 1
	local budget = 1_000_000
	local callLog: { CallRecord } = {}
	local now: () -> number = function()
		return os.time() * 1000
	end
	local nextVersion = 0

	local service = {} :: FakeDataStoreService

	local function scoped(name: string, scope: string?): string
		return (scope or "global") .. "/" .. name
	end

	local function nextRandom(): number
		-- xorshift32: deterministic failure-rate injection independent of math.random.
		local x = rngState
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		rngState = x
		return x / 4294967296
	end

	local function guard(method: string, storeName: string, key: string?)
		if key ~= nil then
			if type(key) ~= "string" or #key == 0 then
				error("101: Key name can't be empty.", 0)
			end
			if #key > MAX_KEY_CHARS then
				error("102: Key name exceeds the 50 character limit.", 0)
			end
		end
		for index, failure in failures do
			local spec = failure.spec
			if
				failure.method == method
				and (spec.key == nil or spec.key == key)
				and (spec.store == nil or spec.store == storeName)
			then
				failure.remaining -= 1
				if failure.remaining <= 0 then
					table.remove(failures, index)
				end
				local code = spec.code or 502
				local message = spec.message or "API Services rejected request (injected failure)"
				local text = string.format("%d: %s", code, message)
				table.insert(callLog, { method = method, store = storeName, key = key, ok = false, error = text })
				error(text, 0)
			end
		end
		if failureRate > 0 and nextRandom() < failureRate then
			local text = "502: API Services rejected request (random injected failure)"
			table.insert(callLog, { method = method, store = storeName, key = key, ok = false, error = text })
			error(text, 0)
		end
		table.insert(callLog, { method = method, store = storeName, key = key, ok = true })
	end

	local function bucket(name: string): { [string]: Entry }
		local b = storage[name]
		if not b then
			b = {}
			storage[name] = b
		end
		return b
	end

	local function write(
		name: string,
		key: string,
		value: any,
		userIds: { number }?,
		metadata: { [string]: any }?
	): Entry
		local size = validate(value, "value", {})
		if size > MAX_VALUE_CHARS then
			error(string.format("105: Serialized value exceeds 4MB limit (%d chars).", size), 0)
		end
		local b = bucket(name)
		local existing = b[key]
		nextVersion += 1
		local timestamp = now()
		local entry: Entry = {
			value = deepCopy(value),
			version = nextVersion,
			created = if existing then existing.created else timestamp,
			updated = timestamp,
			metadata = if metadata then deepCopy(metadata) elseif existing then existing.metadata else {},
			userIds = if userIds then table.clone(userIds) elseif existing then existing.userIds else {},
		}
		b[key] = entry
		return entry
	end

	local stores: { [string]: FakeDataStore } = {}

	function service.GetDataStore(_self: FakeDataStoreService, name: string, scope: string?): FakeDataStore
		local id = scoped(name, scope)
		if stores[id] then
			return stores[id]
		end
		local store = { Name = name } :: FakeDataStore

		function store.GetAsync(_s: FakeDataStore, key: string): (any, KeyInfo?)
			guard("GetAsync", name, key)
			local entry = bucket(id)[key]
			if not entry then
				return nil, nil
			end
			return deepCopy(entry.value), makeKeyInfo(entry)
		end

		function store.SetAsync(
			_s: FakeDataStore,
			key: string,
			value: any,
			userIds: { number }?,
			options: SetOptions?
		): string
			guard("SetAsync", name, key)
			local metadata = if options then options:GetMetadata() else nil
			local entry = write(id, key, value, userIds, metadata)
			return tostring(entry.version)
		end

		function store.UpdateAsync(
			_s: FakeDataStore,
			key: string,
			transform: (any, KeyInfo?) -> ...any
		): (any, KeyInfo?)
			guard("UpdateAsync", name, key)
			local existing = bucket(id)[key]
			local old = if existing then deepCopy(existing.value) else nil
			local info = if existing then makeKeyInfo(existing) else nil
			local newValue, userIds, metadata = transform(old, info)
			if newValue == nil then
				return nil, nil
			end
			local entry = write(id, key, newValue, userIds, metadata)
			return deepCopy(entry.value), makeKeyInfo(entry)
		end

		function store.RemoveAsync(_s: FakeDataStore, key: string): (any, KeyInfo?)
			guard("RemoveAsync", name, key)
			local b = bucket(id)
			local entry = b[key]
			b[key] = nil
			if not entry then
				return nil, nil
			end
			return deepCopy(entry.value), makeKeyInfo(entry)
		end

		function store.IncrementAsync(_s: FakeDataStore, key: string, delta: number?, userIds: { number }?): number
			guard("IncrementAsync", name, key)
			local entry = bucket(id)[key]
			local current = if entry then entry.value else 0
			if type(current) ~= "number" then
				error("106: IncrementAsync on a non-numeric value.", 0)
			end
			local value = math.floor(current + (delta or 1))
			write(id, key, value, userIds, nil)
			return value
		end

		stores[id] = store
		return store
	end

	local orderedStores: { [string]: FakeOrderedDataStore } = {}

	function service.GetOrderedDataStore(
		_self: FakeDataStoreService,
		name: string,
		scope: string?
	): FakeOrderedDataStore
		local id = scoped(name, scope)
		if orderedStores[id] then
			return orderedStores[id]
		end
		ordered[id] = ordered[id] or {}
		local values = ordered[id]
		local store = { Name = name } :: FakeOrderedDataStore

		local function checkInteger(value: any)
			if type(value) ~= "number" or value ~= math.floor(value) or value ~= value then
				error("104: OrderedDataStore values must be integers.", 0)
			end
		end

		function store.GetAsync(_s: FakeOrderedDataStore, key: string): number?
			guard("GetAsync", name, key)
			return values[key]
		end

		function store.SetAsync(_s: FakeOrderedDataStore, key: string, value: number)
			guard("SetAsync", name, key)
			checkInteger(value)
			values[key] = value
		end

		function store.UpdateAsync(_s: FakeOrderedDataStore, key: string, transform: (number?) -> number?): number?
			guard("UpdateAsync", name, key)
			local result = transform(values[key])
			if result == nil then
				return nil
			end
			checkInteger(result)
			values[key] = result
			return result
		end

		function store.IncrementAsync(_s: FakeOrderedDataStore, key: string, delta: number?): number
			guard("IncrementAsync", name, key)
			local value = (values[key] or 0) + math.floor(delta or 1)
			values[key] = value
			return value
		end

		function store.RemoveAsync(_s: FakeOrderedDataStore, key: string): number?
			guard("RemoveAsync", name, key)
			local old = values[key]
			values[key] = nil
			return old
		end

		function store.GetSortedAsync(
			_s: FakeOrderedDataStore,
			ascending: boolean,
			pageSize: number,
			minValue: number?,
			maxValue: number?
		): FakePages
			guard("GetSortedAsync", name, nil)
			assert(pageSize >= 1 and pageSize <= 100, "pageSize must be 1..100")
			local entries: { OrderedEntry } = {}
			for key, value in values do
				if (minValue == nil or value >= minValue) and (maxValue == nil or value <= maxValue) then
					table.insert(entries, { key = key, value = value })
				end
			end
			table.sort(entries, function(a, b)
				if a.value == b.value then
					return a.key < b.key
				end
				if ascending then
					return a.value < b.value
				end
				return a.value > b.value
			end)
			local page = 1
			local pages = {} :: FakePages
			local function slice(): { OrderedEntry }
				local out = {}
				for i = (page - 1) * pageSize + 1, math.min(page * pageSize, #entries) do
					table.insert(out, table.clone(entries[i]))
				end
				return out
			end
			pages.IsFinished = page * pageSize >= #entries
			function pages.GetCurrentPage(_p: FakePages)
				return slice()
			end
			function pages.AdvanceToNextPageAsync(p: FakePages)
				guard("AdvanceToNextPageAsync", name, nil)
				page += 1
				p.IsFinished = page * pageSize >= #entries
			end
			return pages
		end

		orderedStores[id] = store
		return store
	end

	function service.GetRequestBudgetForRequestType(_self: FakeDataStoreService, _requestType: any): number
		return budget
	end

	function service.failNext(_self: FakeDataStoreService, method: string, spec: FailureSpec?)
		local s = spec or {}
		table.insert(failures, { method = method, spec = s, remaining = s.times or 1 })
	end

	function service.setFailureRate(_self: FakeDataStoreService, probability: number, seed: number?)
		failureRate = probability
		rngState = if seed and seed ~= 0 then seed else 1
	end

	function service.setBudget(_self: FakeDataStoreService, value: number)
		budget = value
	end

	function service.setNow(_self: FakeDataStoreService, fn: () -> number)
		now = fn
	end

	function service.newSetOptions(_self: FakeDataStoreService): SetOptions
		local metadata: { [string]: any } = {}
		local options = {} :: SetOptions
		function options.SetMetadata(_o: SetOptions, value: { [string]: any })
			metadata = deepCopy(value)
		end
		function options.GetMetadata(_o: SetOptions)
			return deepCopy(metadata)
		end
		return options
	end

	function service.inspect(_self: FakeDataStoreService, store: string, key: string, scope: string?): any
		local b = storage[scoped(store, scope)]
		local entry = b and b[key]
		return if entry then deepCopy(entry.value) else nil
	end

	function service.seed(_self: FakeDataStoreService, store: string, key: string, value: any, scope: string?)
		write(scoped(store, scope), key, value, nil, nil)
	end

	function service.versionOf(_self: FakeDataStoreService, store: string, key: string, scope: string?): string?
		local b = storage[scoped(store, scope)]
		local entry = b and b[key]
		return if entry then tostring(entry.version) else nil
	end

	function service.calls(_self: FakeDataStoreService, method: string?): { CallRecord }
		if method == nil then
			return table.clone(callLog)
		end
		local out = {}
		for _, record in callLog do
			if record.method == method then
				table.insert(out, record)
			end
		end
		return out
	end

	function service.clearCalls(_self: FakeDataStoreService)
		table.clear(callLog)
	end

	function service.reset(_self: FakeDataStoreService)
		table.clear(storage)
		table.clear(ordered)
		table.clear(failures)
		table.clear(callLog)
		table.clear(stores)
		table.clear(orderedStores)
		failureRate = 0
		budget = 1_000_000
	end

	return service
end

return DataStoreService
