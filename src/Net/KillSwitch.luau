--!strict
--[[
	Net.KillSwitch: turn remotes off on every server at once, and keep them off for servers that
	start later.

	  local switch = Net.KillSwitch.new()        -- server; defaults to the Roblox services
	  switch:startAsync()                        -- load persisted state, subscribe to changes
	  switch:setEnabledAsync("Stilts.BuyItem", false, "duplication exploit under investigation")

	State lives in one DataStore key; MessagingService carries a "version changed" ping and each
	server re-reads the key (uncached, through UpdateAsync) so a lost or reordered ping can never
	leave a server on stale state. A slow poll covers servers that miss pings entirely.

	Names follow Context: "Namespace.Remote", "Namespace.*", or "*" for every inbound remote.
	Local, per-server switches (Context:setEnabled) are separate and unaffected.
]]

local Context = require("./Context")
local Log = require("../Util/Log")
local Roblox = require("../Util/Roblox")

export type Options = {
	context: Context.Context,
	-- Default the Roblox DataStoreService.
	dataStoreService: any?,
	-- Default the Roblox MessagingService. Pass false to rely on polling only.
	messagingService: any?,
	storeName: string?,
	key: string?,
	topic: string?,
	-- Seconds between fallback re-reads (needs the context's task library). Default 300.
	pollInterval: number?,
	now: (() -> number)?,
}

export type KillSwitch = {
	-- Loads the persisted state, subscribes to change pings and starts polling.
	startAsync: (self: KillSwitch) -> (boolean, string?),
	-- Persists the change, applies it here, and pings every other server.
	setEnabledAsync: (self: KillSwitch, name: string, enabled: boolean, reason: string?) -> (boolean, string?),
	-- Re-reads the persisted state now.
	refreshAsync: (self: KillSwitch) -> (boolean, string?),
	getState: (self: KillSwitch) -> Context.KillState,
	stop: (self: KillSwitch) -> (),
}

local DEFAULT_STORE = "RBLXShared"
local DEFAULT_KEY = "Net.KillSwitch"
local DEFAULT_TOPIC = "RBLXShared.Net.KillSwitch"

local KillSwitch = {}

local function normalize(value: any): Context.KillState
	local state: Context.KillState = { version = 0, disabled = {} }
	if type(value) ~= "table" then
		return state
	end
	if type(value.version) == "number" then
		state.version = value.version
	end
	if type(value.disabled) == "table" then
		for name, entry in value.disabled do
			if type(name) == "string" and type(entry) == "table" then
				state.disabled[name] = {
					reason = if type(entry.reason) == "string" then entry.reason else "disabled",
					at = if type(entry.at) == "number" then entry.at else 0,
				}
			end
		end
	end
	return state
end

function KillSwitch.new(options: Options): KillSwitch
	local ctx = options.context
	assert(ctx and ctx.side == "server", "Net.KillSwitch: needs a server context")
	local dataStoreService = options.dataStoreService or Roblox.service("DataStoreService")
	local messagingService: any = options.messagingService
	if messagingService == nil then
		messagingService = Roblox.service("MessagingService")
	end
	local storeName = options.storeName or DEFAULT_STORE
	local key = options.key or DEFAULT_KEY
	local topic = options.topic or DEFAULT_TOPIC
	local pollInterval = options.pollInterval or 300
	local now: () -> number = options.now or ctx.now

	local store = dataStoreService:GetDataStore(storeName)
	local state: Context.KillState = { version = 0, disabled = {} }
	local subscription: any = nil
	local pollThread: thread? = nil
	local stopped = false

	local switch = {} :: KillSwitch

	local function apply(newState: Context.KillState)
		if newState.version < state.version then
			return
		end
		state = newState
		ctx:applyGlobalState(newState)
	end

	-- UpdateAsync with a cancelling transform: always the latest value, never cached, no write.
	local function readFresh(): Context.KillState
		local captured: any = nil
		store:UpdateAsync(key, function(old: any)
			captured = old
			return nil
		end)
		return normalize(captured)
	end

	function switch.refreshAsync(_self: KillSwitch): (boolean, string?)
		local ok, result = pcall(readFresh)
		if not ok then
			Log.warn("Net.KillSwitch", "refresh failed: " .. tostring(result))
			return false, tostring(result)
		end
		apply(result)
		return true, nil
	end

	function switch.startAsync(self: KillSwitch): (boolean, string?)
		local ok, err = self:refreshAsync()
		if messagingService and subscription == nil then
			local subscribed, result = pcall(function()
				return messagingService:SubscribeAsync(topic, function(message: any)
					local data = if type(message) == "table" then message.Data else nil
					if type(data) == "table" and type(data.version) == "number" and data.version > state.version then
						self:refreshAsync()
					end
				end)
			end)
			if subscribed then
				subscription = result
			else
				Log.warn("Net.KillSwitch", "could not subscribe to " .. topic .. ": " .. tostring(result))
			end
		end
		local taskLib = ctx.task
		if taskLib and pollThread == nil and pollInterval > 0 then
			local function poll()
				if stopped then
					return
				end
				self:refreshAsync()
				pollThread = taskLib.delay(pollInterval, poll)
			end
			pollThread = taskLib.delay(pollInterval, poll)
		end
		return ok, err
	end

	function switch.setEnabledAsync(
		_self: KillSwitch,
		name: string,
		enabled: boolean,
		reason: string?
	): (boolean, string?)
		assert(type(name) == "string" and name ~= "", "Net.KillSwitch: name must be a remote name")
		local committed: Context.KillState? = nil
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(old: any)
				local nextState = normalize(old)
				nextState.version += 1
				if enabled then
					nextState.disabled[name] = nil
				else
					nextState.disabled[name] = { reason = reason or "disabled", at = now() }
				end
				committed = nextState
				return nextState
			end)
		end)
		if not ok or committed == nil then
			Log.warn("Net.KillSwitch", "could not persist " .. name .. ": " .. tostring(err))
			return false, tostring(err)
		end
		local newState = committed :: Context.KillState
		apply(newState)
		Log.warn(
			"Net.KillSwitch",
			name
				.. " "
				.. (if enabled then "enabled" else "disabled")
				.. " on all servers (version "
				.. tostring(newState.version)
				.. ")"
		)
		if messagingService then
			local published, publishErr = pcall(function()
				messagingService:PublishAsync(topic, { version = newState.version })
			end)
			if not published then
				-- Other servers still converge through polling.
				Log.warn("Net.KillSwitch", "ping failed, other servers will catch up on poll: " .. tostring(publishErr))
			end
		end
		return true, nil
	end

	function switch.getState(_self: KillSwitch): Context.KillState
		return normalize(state)
	end

	function switch.stop(_self: KillSwitch)
		stopped = true
		if subscription then
			subscription:Disconnect()
			subscription = nil
		end
		local taskLib = ctx.task
		if pollThread and taskLib then
			taskLib.cancel(pollThread)
		end
		pollThread = nil
	end

	return switch
end

return KillSwitch
