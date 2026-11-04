--!strict
--[[
	Net.Context: one side of the wire (server or client) and the state Net keeps for it:
	bound remotes, kill switch, metrics, strike reporting and per-player cleanup.

	Games normally never construct one: Net.getDefaultContext() builds the Roblox context on
	first use. Tests and sims build contexts over a LoopbackTransport.
]]

local AntiExploit = require("../AntiExploit")
local Log = require("../Util/Log")
local RateLimiter = require("./RateLimiter")
local Transport = require("./Transport")

export type Side = "server" | "client"

-- The subset of Roblox's task library Net uses (Test.Clock's clock.task matches it).
export type TaskLib = {
	spawn: (fnOrThread: any, ...any) -> thread,
	delay: (seconds: number?, fnOrThread: any, ...any) -> thread,
	cancel: (thread: thread) -> (),
}

export type DropCounts = {
	-- Wrong type, range, enum, extra arguments: a strike for the sender.
	malformed: number,
	-- Over the remote's rate limit. Sustained floods add a strike.
	rateLimited: number,
	-- Kill switch on.
	disabled: number,
	-- The remote's guard rejected the sender (for example, data not loaded yet).
	unauthorized: number,
	-- Valid, but no handler was connected.
	noHandler: number,
	-- A client fired a server-to-client remote: a strike.
	wrongDirection: number,
}

export type RemoteKind = "ClientEvent" | "ServerEvent" | "ClientFunction"

export type RemoteMetrics = {
	name: string,
	kind: RemoteKind,
	received: number,
	accepted: number,
	-- Server-to-client sends (calls to fire/fireAll/...).
	sent: number,
	dropped: DropCounts,
	handlerErrors: number,
	-- Wall time spent in handlers, including yields.
	handlerSeconds: number,
	maxHandlerSeconds: number,
}

export type KillEntry = { reason: string, at: number }

-- Kill-switch state shared across servers (see Net.KillSwitch).
export type KillState = {
	version: number,
	disabled: { [string]: KillEntry },
}

export type FloodOptions = {
	-- Sliding window in seconds. Default 10.
	window: number,
	-- Strike once per window when drops on one remote exceed factor x burst. Default 10.
	factor: number,
}

export type ContextOptions = {
	side: Side,
	transport: Transport.ServerTransport | Transport.ClientTransport,
	-- Monotonic seconds. Default os.clock.
	clock: (() -> number)?,
	-- Unix seconds, for kill-switch stamps. Default os.time.
	now: (() -> number)?,
	-- Needed for client invoke timeouts and async handler threads. Default: the Roblox task
	-- library inside Roblox; under lune pass Test.Clock's clock.task.
	task: TaskLib?,
	-- Where malformed traffic is reported (server). Default AntiExploit.default() in Roblox.
	strikes: AntiExploit.Registry?,
	-- Validate server-to-client payloads and function responses against their schemas.
	-- Default true in Studio and under lune, false in live servers.
	validateOutgoing: boolean?,
	-- Applied to client-to-server remotes that do not declare their own. Default 10/s, burst 20.
	defaultRateLimit: RateLimiter.RateLimit?,
	flood: FloodOptions?,
	-- Client invoke timeout in seconds. Default 15.
	invokeTimeout: number?,
}

-- What Remote registers with its context (internal).
export type Registration = {
	name: string,
	namespace: string,
	kind: RemoteKind,
	inbound: boolean,
	endpoint: Transport.ServerEndpoint?,
	limiter: RateLimiter.RateLimiter?,
	metrics: RemoteMetrics,
}

export type Context = {
	side: Side,
	transport: any,
	clock: () -> number,
	now: () -> number,
	task: TaskLib?,
	strikes: AntiExploit.Registry?,
	validateOutgoing: boolean,
	defaultRateLimit: RateLimiter.RateLimit,
	invokeTimeout: number,

	-- Kill switch. Names are "Namespace.Remote", "Namespace.*" or "*" (every inbound remote).
	setEnabled: (self: Context, name: string, enabled: boolean, reason: string?) -> (),
	setAllEnabled: (self: Context, enabled: boolean, reason: string?) -> (),
	isEnabled: (self: Context, name: string) -> boolean,
	-- Everything currently switched off, local and global, with reasons.
	getDisabled: (self: Context) -> { [string]: KillEntry },
	-- Replaces the cross-server layer (Net.KillSwitch calls this).
	applyGlobalState: (self: Context, state: KillState) -> (),

	getMetrics: (self: Context) -> { [string]: RemoteMetrics },
	resetMetrics: (self: Context) -> (),

	-- Internal, used by Net.Remote.
	_claimNamespace: (self: Context, namespace: string) -> (),
	_register: (self: Context, registration: Registration) -> (),
	_newMetrics: (self: Context, name: string, kind: RemoteKind) -> RemoteMetrics,
	_strike: (self: Context, player: Player, category: string, detail: string) -> (),
	_noteRateLimited: (self: Context, player: Player, name: string, burst: number) -> (),
	_spawn: (self: Context, fn: (...any) -> (), ...any) -> (),
}

local DEFAULT_RATE_LIMIT: RateLimiter.RateLimit = table.freeze({ rate = 10, burst = 20 })

local Context = {}

local function newDropCounts(): DropCounts
	return {
		malformed = 0,
		rateLimited = 0,
		disabled = 0,
		unauthorized = 0,
		noHandler = 0,
		wrongDirection = 0,
	}
end

local function namespaceOf(name: string): string
	local dot = string.find(name, ".", 1, true)
	return if dot then string.sub(name, 1, dot - 1) else name
end

function Context.new(options: ContextOptions): Context
	assert(options.side == "server" or options.side == "client", "Net.Context: side must be 'server' or 'client'")
	assert(options.transport ~= nil, "Net.Context: transport is required")
	assert((options.transport :: any).side == options.side, "Net.Context: transport side does not match context side")
	local defaultLimit = options.defaultRateLimit or DEFAULT_RATE_LIMIT
	RateLimiter.validate(defaultLimit)
	local flood: FloodOptions = options.flood or { window = 10, factor = 10 }

	local localDisabled: { [string]: KillEntry } = {}
	local globalState: KillState = { version = 0, disabled = {} }
	local registrations: { [string]: Registration } = {}
	local namespaces: { [string]: boolean } = {}
	local floods: { [Player]: { [string]: { windowStart: number, drops: number } } } = {}

	local ctx = {
		side = options.side,
		transport = options.transport,
		clock = options.clock or os.clock,
		now = options.now or os.time,
		task = options.task,
		strikes = options.strikes,
		validateOutgoing = if options.validateOutgoing == nil then true else options.validateOutgoing,
		defaultRateLimit = defaultLimit,
		invokeTimeout = options.invokeTimeout or 15,
	} :: Context

	local function disabledEntry(name: string): KillEntry?
		local namespaceWildcard = namespaceOf(name) .. ".*"
		return localDisabled[name]
			or localDisabled[namespaceWildcard]
			or localDisabled["*"]
			or globalState.disabled[name]
			or globalState.disabled[namespaceWildcard]
			or globalState.disabled["*"]
	end

	local function refreshEndpoints()
		for name, registration in registrations do
			local endpoint = registration.endpoint
			if endpoint and registration.inbound then
				endpoint:setEnabled(disabledEntry(name) == nil)
			end
		end
	end

	function ctx.isEnabled(_self: Context, name: string): boolean
		return disabledEntry(name) == nil
	end

	function ctx.setEnabled(self: Context, name: string, enabled: boolean, reason: string?)
		assert(self.side == "server", "Net: the kill switch is server-only")
		assert(type(name) == "string" and name ~= "", "Net.setEnabled: name must be a remote name")
		if enabled then
			localDisabled[name] = nil
		else
			localDisabled[name] = { reason = reason or "disabled", at = self.now() }
			Log.warn("Net", "kill switch: " .. name .. " disabled (" .. (reason or "no reason given") .. ")")
		end
		refreshEndpoints()
	end

	function ctx.setAllEnabled(self: Context, enabled: boolean, reason: string?)
		self:setEnabled("*", enabled, reason)
	end

	function ctx.getDisabled(_self: Context): { [string]: KillEntry }
		local out: { [string]: KillEntry } = {}
		for name, entry in globalState.disabled do
			out[name] = table.clone(entry)
		end
		for name, entry in localDisabled do
			out[name] = table.clone(entry)
		end
		return out
	end

	function ctx.applyGlobalState(_self: Context, state: KillState)
		if state.version < globalState.version then
			return
		end
		local disabled: { [string]: KillEntry } = {}
		for name, entry in state.disabled do
			disabled[name] = { reason = entry.reason, at = entry.at }
		end
		globalState = { version = state.version, disabled = disabled }
		refreshEndpoints()
	end

	function ctx.getMetrics(_self: Context): { [string]: RemoteMetrics }
		local out: { [string]: RemoteMetrics } = {}
		for name, registration in registrations do
			local copy = table.clone(registration.metrics)
			copy.dropped = table.clone(registration.metrics.dropped)
			out[name] = copy
		end
		return out
	end

	function ctx.resetMetrics(_self: Context)
		for _, registration in registrations do
			local metrics = registration.metrics
			metrics.received = 0
			metrics.accepted = 0
			metrics.sent = 0
			metrics.dropped = newDropCounts()
			metrics.handlerErrors = 0
			metrics.handlerSeconds = 0
			metrics.maxHandlerSeconds = 0
		end
	end

	function ctx._claimNamespace(_self: Context, namespace: string)
		assert(not namespaces[namespace], "Net: namespace '" .. namespace .. "' is already bound in this context")
		namespaces[namespace] = true
	end

	function ctx._newMetrics(_self: Context, name: string, kind: RemoteKind): RemoteMetrics
		return {
			name = name,
			kind = kind,
			received = 0,
			accepted = 0,
			sent = 0,
			dropped = newDropCounts(),
			handlerErrors = 0,
			handlerSeconds = 0,
			maxHandlerSeconds = 0,
		}
	end

	function ctx._register(_self: Context, registration: Registration)
		registrations[registration.name] = registration
		local endpoint = registration.endpoint
		if endpoint and registration.inbound then
			endpoint:setEnabled(disabledEntry(registration.name) == nil)
		end
	end

	function ctx._strike(self: Context, player: Player, category: string, detail: string)
		local registry = self.strikes
		if registry then
			registry:strike(player, category, detail)
		end
	end

	function ctx._noteRateLimited(self: Context, player: Player, name: string, burst: number)
		local now = self.clock()
		local perPlayer = floods[player]
		if perPlayer == nil then
			perPlayer = {}
			floods[player] = perPlayer
		end
		local window = perPlayer[name]
		if window == nil or now - window.windowStart > flood.window then
			window = { windowStart = now, drops = 0 }
			perPlayer[name] = window
		end
		window.drops += 1
		-- Exactly once per window, when the drop count crosses the threshold.
		if window.drops == math.max(1, math.floor(flood.factor * burst)) then
			self:_strike(
				player,
				"net.flood",
				name .. ": over " .. tostring(window.drops) .. " dropped in " .. tostring(flood.window) .. " s"
			)
		end
	end

	function ctx._spawn(self: Context, fn: (...any) -> (), ...: any)
		local taskLib = self.task
		if taskLib then
			taskLib.spawn(fn, ...)
			return
		end
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			Log.error("Net", "background thread errored: " .. debug.traceback(thread, tostring(err)))
		end
	end

	if options.side == "server" then
		local transport = options.transport :: Transport.ServerTransport
		transport:onPlayerRemoving(function(player: Player)
			floods[player] = nil
			for _, registration in registrations do
				local limiter = registration.limiter
				if limiter then
					limiter:remove(player)
				end
			end
		end)
	end

	return ctx
end

return Context
