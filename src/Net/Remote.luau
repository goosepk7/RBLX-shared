--!strict
--[[
	Net.Remote: typed remote definitions and the dispatch pipeline.

	A definition is created unbound (Net.clientEvent / Net.serverEvent / Net.clientFunction) and
	becomes usable once placed in a namespace (Net.namespace), which names it and binds it to a
	context. The same definitions module is required on both sides; each side only gets the
	methods that make sense for it and calling the other side's methods errors.

	Server pipeline for every client-to-server message, in order:
	  kill switch -> rate limit -> argument count -> schema -> guard -> handlers
	The rate limit comes before every check that can strike, so a flood costs at most `burst`
	strikes plus one flood strike per window. Malformed payloads (wrong arity, type, range, enum)
	and wrong-direction traffic (also rate limited) are dropped, counted, and reported as
	strikes. Rate-limited and guarded messages are dropped and counted.
]]

local Context = require("./Context")
local Log = require("../Util/Log")
local RateLimiter = require("./RateLimiter")
local Schema = require("./Schema")
local Signal = require("../Signal")
local Transport = require("./Transport")

type Context = Context.Context
type Schema<T> = Schema.Schema<T>
export type Connection = Signal.Connection

export type InvokeError = "disabled" | "invalid" | "rate_limited" | "unauthorized" | "unavailable" | "error" | "timeout"

export type InvokeResult<T> = { ok: true, value: T } | { ok: false, error: InvokeError }

export type ClientEventOptions = {
	-- Per-player limit on the server (and a matching self-limit on the client). `false` turns
	-- limiting off; do that only for remotes that are harmless at any rate.
	rateLimit: (RateLimiter.RateLimit | false)?,
	-- Use an UnreliableRemoteEvent (dropped or reordered under load; payload <= ~900 bytes).
	unreliable: boolean?,
	-- Server-side precondition, e.g. "profile loaded". Failing it drops the message without a
	-- strike. Must not yield.
	guard: ((player: Player) -> boolean)?,
	-- Accept a payload schema that contains Schema.any(). Off by default: §3.3 wants every
	-- inbound payload validated.
	allowAny: boolean?,
}

export type ServerEventOptions = {
	unreliable: boolean?,
}

export type ClientFunctionOptions = {
	rateLimit: (RateLimiter.RateLimit | false)?,
	guard: ((player: Player) -> boolean)?,
	-- Accept a request schema that contains Schema.any(). Off by default.
	allowAny: boolean?,
	-- Client-side timeout in seconds. Default: the context's invokeTimeout (15).
	timeout: number?,
}

-- Client to server, fire-and-forget.
export type ClientEvent<T> = {
	kind: "ClientEvent",
	-- "Namespace.Remote" once bound.
	name: string,
	-- Server: called with the sender and a validated payload. Each call runs on its own thread.
	connect: (self: ClientEvent<T>, handler: (player: Player, payload: T) -> ()) -> Connection,
	-- Client: validate and send. Returns false if nothing was sent (kill switch on, payload
	-- invalid, or over the rate limit). May yield on first use while the remote replicates.
	fire: (self: ClientEvent<T>, payload: T) -> boolean,
}

-- Server to client, fire-and-forget.
export type ServerEvent<T> = {
	kind: "ServerEvent",
	name: string,
	fire: (self: ServerEvent<T>, player: Player, payload: T) -> (),
	fireAll: (self: ServerEvent<T>, payload: T) -> (),
	fireExcept: (self: ServerEvent<T>, except: Player, payload: T) -> (),
	fireList: (self: ServerEvent<T>, players: { Player }, payload: T) -> (),
	-- Client: called with each payload.
	connect: (self: ServerEvent<T>, handler: (payload: T) -> ()) -> Connection,
}

-- Client to server request with a response.
export type ClientFunction<Req, Res> = {
	kind: "ClientFunction",
	name: string,
	-- Server: one handler. Its return value is the response. Errors become { ok = false,
	-- error = "error" } for the client and are reported on the server.
	handle: (self: ClientFunction<Req, Res>, handler: (player: Player, request: Req) -> Res) -> (),
	-- Client: yields until the server answers or the timeout passes.
	invokeAsync: (self: ClientFunction<Req, Res>, request: Req, timeout: number?) -> InvokeResult<Res>,
}

type Slot = { handler: (player: Player, payload: any) -> (), connection: Connection }

type Definition = {
	kind: Context.RemoteKind,
	schema: Schema<any>,
	responseSchema: Schema<any>?,
	rateLimit: (RateLimiter.RateLimit | false)?,
	unreliable: boolean,
	guard: ((player: Player) -> boolean)?,
	timeout: number?,
	public: any,

	bound: boolean,
	namespace: string,
	key: string,
	name: string,
	context: Context?,

	-- server
	endpoint: Transport.ServerEndpoint?,
	slots: { Slot },
	invokeHandler: ((player: Player, request: any) -> any)?,
	limiter: RateLimiter.RateLimiter?,
	metrics: Context.RemoteMetrics?,

	-- client
	clientEndpoint: Transport.ClientEndpoint?,
	clientLimiter: RateLimiter.RateLimiter?,
}

local Remote = {}

-- public remote object -> its definition
local definitions: { [any]: Definition } = setmetatable({}, { __mode = "k" }) :: any

local NAME_PATTERN = "^[%a_][%w_]*$"

local function newDefinition(kind: Context.RemoteKind, schema: Schema<any>): Definition
	assert(Schema.isSchema(schema), "Net: expected a Net.Schema for the payload")
	return {
		kind = kind,
		schema = schema,
		responseSchema = nil,
		rateLimit = nil,
		unreliable = false,
		guard = nil,
		timeout = nil,
		public = nil,
		bound = false,
		namespace = "",
		key = "",
		name = "<unbound>",
		context = nil,
		endpoint = nil,
		slots = {},
		invokeHandler = nil,
		limiter = nil,
		metrics = nil,
		clientEndpoint = nil,
		clientLimiter = nil,
	}
end

local function boundContext(def: Definition, method: string, side: Context.Side): Context
	local ctx = def.context
	if ctx == nil then
		error("Net: cannot call " .. method .. " on an unbound remote; put it in Net.namespace(...) first", 3)
	end
	if ctx.side ~= side then
		error("Net: " .. def.name .. ":" .. method .. " is " .. side .. "-only (this is the " .. ctx.side .. ")", 3)
	end
	return ctx
end

local function newConnection(slots: { Slot }, slot: Slot): Connection
	local connection = { Connected = true } :: Connection
	function connection.Disconnect(self: Connection)
		if not self.Connected then
			return
		end
		self.Connected = false
		local index = table.find(slots, slot)
		if index then
			table.remove(slots, index)
		end
	end
	return connection
end

local function reject(def: Definition, ctx: Context, player: Player, reason: string)
	local metrics = def.metrics :: Context.RemoteMetrics
	metrics.dropped.malformed += 1
	ctx:_strike(player, "net.malformed", def.name .. ": " .. reason)
end

-- Spends one token from the sender's bucket. Over the limit: counted, and reported to the
-- context's flood detector, which strikes at most once per window.
local function admitRate(def: Definition, ctx: Context, player: Player): boolean
	local limiter = def.limiter
	if limiter == nil or limiter:allow(player) then
		return true
	end
	local metrics = def.metrics :: Context.RemoteMetrics
	metrics.dropped.rateLimited += 1
	ctx:_noteRateLimited(player, def.name, limiter.limit.burst)
	return false
end

-- Shared server checks. Returns the payload when the message should be handled, otherwise
-- nil and the error code a function remote answers with.
local function admit(def: Definition, ctx: Context, player: Player, ...: any): (boolean, any, InvokeError?)
	local metrics = def.metrics :: Context.RemoteMetrics
	metrics.received += 1
	if not ctx:isEnabled(def.name) then
		metrics.dropped.disabled += 1
		return false, nil, "disabled"
	end
	-- The limiter runs before anything that can strike, so one client can't turn a flood into
	-- a strike (and a Struck signal) per message; sustained floods earn one flood strike.
	if not admitRate(def, ctx, player) then
		return false, nil, "rate_limited"
	end
	local argCount = select("#", ...)
	if argCount > 1 then
		reject(def, ctx, player, "expected one payload argument, got " .. tostring(argCount))
		return false, nil, "invalid"
	end
	local payload = (...)
	local ok, reason = def.schema.check(payload)
	if not ok then
		reject(def, ctx, player, reason or "invalid payload")
		return false, nil, "invalid"
	end
	local guard = def.guard
	if guard then
		local guardOk, allowed = pcall(guard, player)
		if not guardOk then
			Log.error("Net", def.name .. " guard errored: " .. tostring(allowed))
			metrics.dropped.unauthorized += 1
			return false, nil, "unauthorized"
		end
		if not allowed then
			metrics.dropped.unauthorized += 1
			return false, nil, "unauthorized"
		end
	end
	return true, payload, nil
end

local function recordHandlerTime(metrics: Context.RemoteMetrics, elapsed: number)
	metrics.handlerSeconds += elapsed
	if elapsed > metrics.maxHandlerSeconds then
		metrics.maxHandlerSeconds = elapsed
	end
end

local function runEventHandler(
	def: Definition,
	ctx: Context,
	handler: (Player, any) -> (),
	player: Player,
	payload: any
)
	local metrics = def.metrics :: Context.RemoteMetrics
	local started = ctx.clock()
	local ok, err = xpcall(handler :: any, debug.traceback, player, payload)
	recordHandlerTime(metrics, ctx.clock() - started)
	if not ok then
		metrics.handlerErrors += 1
		Log.error("Net", def.name .. " handler errored: " .. tostring(err))
	end
end

local function onServerEvent(def: Definition, ctx: Context, player: Player, ...: any)
	local admitted, payload = admit(def, ctx, player, ...)
	if not admitted then
		return
	end
	local metrics = def.metrics :: Context.RemoteMetrics
	if #def.slots == 0 then
		metrics.dropped.noHandler += 1
		return
	end
	metrics.accepted += 1
	for _, slot in table.clone(def.slots) do
		if slot.connection.Connected then
			ctx:_spawn(runEventHandler, def, ctx, slot.handler, player, payload)
		end
	end
end

local function onServerInvoke(def: Definition, ctx: Context, player: Player, ...: any): (boolean, any)
	local admitted, payload, code = admit(def, ctx, player, ...)
	if not admitted then
		return false, code
	end
	local metrics = def.metrics :: Context.RemoteMetrics
	local handler = def.invokeHandler
	if handler == nil then
		metrics.dropped.noHandler += 1
		return false, "unavailable"
	end
	metrics.accepted += 1
	local started = ctx.clock()
	local ok, result = xpcall(handler, debug.traceback, player, payload)
	recordHandlerTime(metrics, ctx.clock() - started)
	if not ok then
		metrics.handlerErrors += 1
		Log.error("Net", def.name .. " handler errored: " .. tostring(result))
		return false, "error"
	end
	local responseSchema = def.responseSchema
	if ctx.validateOutgoing and responseSchema then
		local valid, reason = responseSchema.check(result)
		if not valid then
			metrics.handlerErrors += 1
			Log.error("Net", def.name .. " handler returned an invalid response: " .. tostring(reason))
			return false, "error"
		end
	end
	return true, result
end

local function onWrongDirection(def: Definition, ctx: Context, player: Player)
	local metrics = def.metrics :: Context.RemoteMetrics
	metrics.received += 1
	if not admitRate(def, ctx, player) then
		return
	end
	metrics.dropped.wrongDirection += 1
	ctx:_strike(player, "net.wrongDirection", def.name .. ": client fired a server-to-client remote")
end

local function checkOutgoing(def: Definition, ctx: Context, payload: any)
	if ctx.validateOutgoing then
		local ok, reason = def.schema.check(payload)
		if not ok then
			error("Net: refusing to send an invalid " .. def.name .. " payload: " .. tostring(reason), 3)
		end
	end
end

local function resolveClientEndpoint(def: Definition, ctx: Context): Transport.ClientEndpoint
	local existing = def.clientEndpoint
	if existing then
		return existing
	end
	local transport = ctx.transport :: Transport.ClientTransport
	local kind: Transport.EndpointKind = if def.kind == "ClientFunction"
		then "function"
		elseif def.unreliable then "unreliable"
		else "event"
	local endpoint = transport:findEndpoint(def.namespace, def.key, kind)
		or transport:waitForEndpoint(def.namespace, def.key, kind)
	def.clientEndpoint = endpoint
	return endpoint
end

-- Client side: validate and self-limit before anything leaves the client, so a client-side bug
-- produces a loud error in Output instead of strikes against the player.
local function clientPreflight(def: Definition, ctx: Context, payload: any): (Transport.ClientEndpoint?, InvokeError?)
	local endpoint = resolveClientEndpoint(def, ctx)
	if not endpoint:isEnabled() then
		return nil, "disabled"
	end
	local ok, reason = def.schema.check(payload)
	if not ok then
		Log.error("Net", "not sending invalid " .. def.name .. " payload: " .. tostring(reason))
		return nil, "invalid"
	end
	local limiter = def.clientLimiter
	if limiter and not limiter:allow("self") then
		return nil, "rate_limited"
	end
	return endpoint, nil
end

local function invokeWithTimeout(
	ctx: Context,
	endpoint: Transport.ClientEndpoint,
	request: any,
	seconds: number
): { any }?
	local taskLib = ctx.task
	if taskLib == nil then
		-- No scheduler (bare lune): the call cannot be raced against a timer.
		return table.pack(pcall(endpoint.invoke, endpoint, request))
	end
	local caller = coroutine.running()
	local state = { done = false, waiting = false, result = nil :: { any }? }
	local timer: thread? = nil
	taskLib.spawn(function()
		local packed = table.pack(pcall(endpoint.invoke, endpoint, request))
		if state.done then
			return
		end
		state.done = true
		if timer then
			taskLib.cancel(timer)
		end
		if state.waiting then
			taskLib.spawn(caller, packed)
		else
			state.result = packed
		end
	end)
	if state.done then
		return state.result
	end
	timer = taskLib.delay(seconds, function()
		if state.done then
			return
		end
		state.done = true
		taskLib.spawn(caller, nil)
	end)
	state.waiting = true
	return coroutine.yield()
end

-- Client-to-server payloads must be described precisely (§3.3) unless the remote opts out.
local function refuseAny(constructor: string, schema: Schema<any>, allowAny: boolean?)
	if schema.containsAny and allowAny ~= true then
		error(
			"Net."
				.. constructor
				.. ": the payload schema contains Schema.any(), so clients could send anything. Describe it "
				.. "precisely, or pass allowAny = true if this remote really accepts any value",
			3
		)
	end
end

function Remote.clientEvent<T>(schema: Schema<T>, options: ClientEventOptions?): ClientEvent<T>
	local opts: ClientEventOptions = options or {}
	local def = newDefinition("ClientEvent", schema)
	refuseAny("clientEvent", schema, opts.allowAny)
	def.rateLimit = opts.rateLimit
	def.unreliable = opts.unreliable == true
	def.guard = opts.guard
	if type(opts.rateLimit) == "table" then
		RateLimiter.validate(opts.rateLimit)
	end

	local remote = { kind = "ClientEvent", name = def.name } :: any

	function remote.connect(_self: any, handler: (player: Player, payload: any) -> ()): Connection
		boundContext(def, "connect", "server")
		assert(type(handler) == "function", "Net: connect expects a function")
		local slot = { handler = handler } :: Slot
		slot.connection = newConnection(def.slots, slot)
		table.insert(def.slots, slot)
		return slot.connection
	end

	function remote.fire(_self: any, payload: any): boolean
		local ctx = boundContext(def, "fire", "client")
		local endpoint = clientPreflight(def, ctx, payload)
		if endpoint == nil then
			return false
		end
		endpoint:fire(payload)
		return true
	end

	def.public = remote
	definitions[remote] = def
	return remote :: ClientEvent<T>
end

function Remote.serverEvent<T>(schema: Schema<T>, options: ServerEventOptions?): ServerEvent<T>
	local opts: ServerEventOptions = options or {}
	local def = newDefinition("ServerEvent", schema)
	def.unreliable = opts.unreliable == true
	def.rateLimit = false

	local remote = { kind = "ServerEvent", name = def.name } :: any

	local function serverSide(method: string): (Context, Transport.ServerEndpoint, Context.RemoteMetrics)
		local ctx = boundContext(def, method, "server")
		return ctx, def.endpoint :: Transport.ServerEndpoint, def.metrics :: Context.RemoteMetrics
	end

	function remote.fire(_self: any, player: Player, payload: any)
		local ctx, endpoint, metrics = serverSide("fire")
		checkOutgoing(def, ctx, payload)
		endpoint:fire(player, payload)
		metrics.sent += 1
	end

	function remote.fireAll(_self: any, payload: any)
		local ctx, endpoint, metrics = serverSide("fireAll")
		checkOutgoing(def, ctx, payload)
		endpoint:fireAll(payload)
		metrics.sent += 1
	end

	function remote.fireExcept(_self: any, except: Player, payload: any)
		local ctx, endpoint, metrics = serverSide("fireExcept")
		checkOutgoing(def, ctx, payload)
		local transport = ctx.transport :: Transport.ServerTransport
		for _, player in transport:getPlayers() do
			if player ~= except then
				endpoint:fire(player, payload)
			end
		end
		metrics.sent += 1
	end

	function remote.fireList(_self: any, players: { Player }, payload: any)
		local ctx, endpoint, metrics = serverSide("fireList")
		checkOutgoing(def, ctx, payload)
		for _, player in players do
			endpoint:fire(player, payload)
		end
		metrics.sent += 1
	end

	function remote.connect(_self: any, handler: (payload: any) -> ()): Connection
		local ctx = boundContext(def, "connect", "client")
		assert(type(handler) == "function", "Net: connect expects a function")
		local connection = { Connected = true } :: Connection
		local detach: (() -> ())? = nil

		local function attach(endpoint: Transport.ClientEndpoint)
			if not connection.Connected then
				return
			end
			detach = endpoint:onEvent(function(...: any)
				local payload = (...)
				local ok, err = xpcall(handler :: any, debug.traceback, payload)
				if not ok then
					Log.error("Net", def.name .. " client handler errored: " .. tostring(err))
				end
			end)
		end

		function connection.Disconnect(self: Connection)
			if not self.Connected then
				return
			end
			self.Connected = false
			if detach then
				detach()
				detach = nil
			end
		end

		local transport = ctx.transport :: Transport.ClientTransport
		local kind: Transport.EndpointKind = if def.unreliable then "unreliable" else "event"
		local endpoint = def.clientEndpoint or transport:findEndpoint(def.namespace, def.key, kind)
		if endpoint then
			def.clientEndpoint = endpoint
			attach(endpoint)
		else
			-- Not replicated yet: attach when it arrives. Roblox queues events until then.
			ctx:_spawn(function()
				attach(resolveClientEndpoint(def, ctx))
			end)
		end
		return connection
	end

	def.public = remote
	definitions[remote] = def
	return remote :: ServerEvent<T>
end

function Remote.clientFunction<Req, Res>(
	request: Schema<Req>,
	response: Schema<Res>,
	options: ClientFunctionOptions?
): ClientFunction<Req, Res>
	local opts: ClientFunctionOptions = options or {}
	local def = newDefinition("ClientFunction", request)
	refuseAny("clientFunction", request, opts.allowAny)
	assert(Schema.isSchema(response), "Net.clientFunction: expected a Net.Schema for the response")
	def.responseSchema = response
	def.rateLimit = opts.rateLimit
	def.guard = opts.guard
	def.timeout = opts.timeout
	if type(opts.rateLimit) == "table" then
		RateLimiter.validate(opts.rateLimit)
	end

	local remote = { kind = "ClientFunction", name = def.name } :: any

	function remote.handle(_self: any, handler: (player: Player, request: any) -> any)
		boundContext(def, "handle", "server")
		assert(type(handler) == "function", "Net: handle expects a function")
		assert(def.invokeHandler == nil, "Net: " .. def.name .. " already has a handler")
		def.invokeHandler = handler
	end

	function remote.invokeAsync(_self: any, payload: any, timeout: number?): InvokeResult<any>
		local ctx = boundContext(def, "invokeAsync", "client")
		local endpoint, code = clientPreflight(def, ctx, payload)
		if endpoint == nil then
			return { ok = false, error = code :: InvokeError }
		end
		local seconds = timeout or def.timeout or ctx.invokeTimeout
		local packed = invokeWithTimeout(ctx, endpoint, payload, seconds)
		if packed == nil then
			return { ok = false, error = "timeout" }
		end
		local called, accepted, value = packed[1], packed[2], packed[3]
		if not called then
			Log.warn("Net", def.name .. " invoke failed: " .. tostring(accepted))
			return { ok = false, error = "error" }
		end
		if accepted == true then
			return { ok = true, value = value }
		end
		local errorCode: InvokeError = if type(value) == "string" then value :: any else "error"
		return { ok = false, error = errorCode }
	end

	def.public = remote
	definitions[remote] = def
	return remote :: ClientFunction<Req, Res>
end

-- Binds one definition to a context under `namespace.key`.
function Remote.bind(remote: any, ctx: Context, namespace: string, key: string, namespaceGuard: ((Player) -> boolean)?)
	local def = definitions[remote]
	if def == nil then
		error("Net.namespace: " .. namespace .. "." .. tostring(key) .. " is not a Net remote definition", 3)
	end
	assert(type(key) == "string" and string.match(key, NAME_PATTERN), "Net: remote names must be identifiers")
	if def.bound then
		error("Net: " .. namespace .. "." .. key .. " is already bound as " .. def.name, 3)
	end
	def.bound = true
	def.namespace = namespace
	def.key = key
	def.name = namespace .. "." .. key
	def.context = ctx
	def.guard = def.guard or namespaceGuard
	remote.name = def.name

	local inbound = def.kind ~= "ServerEvent"
	local limit: RateLimiter.RateLimit? = nil
	if inbound then
		if def.rateLimit == nil then
			limit = ctx.defaultRateLimit
		elseif def.rateLimit ~= false then
			limit = def.rateLimit :: RateLimiter.RateLimit
		end
	end
	-- Clients never legitimately fire a server-to-client remote, but a modified one can, so the
	-- server still limits that traffic (default limit) before striking it.
	local serverLimit: RateLimiter.RateLimit? = if inbound then limit else ctx.defaultRateLimit

	if ctx.side == "server" then
		local transport = ctx.transport :: Transport.ServerTransport
		local kind: Transport.EndpointKind = if def.kind == "ClientFunction"
			then "function"
			elseif def.unreliable then "unreliable"
			else "event"
		local endpoint = transport:createEndpoint(namespace, key, kind)
		def.endpoint = endpoint
		def.metrics = ctx:_newMetrics(def.name, def.kind)
		if serverLimit then
			def.limiter = RateLimiter.new(serverLimit, ctx.clock)
		end
		if def.kind == "ClientEvent" then
			endpoint:onEvent(function(player: Player, ...: any)
				onServerEvent(def, ctx, player, ...)
			end)
		elseif def.kind == "ClientFunction" then
			endpoint:onInvoke(function(player: Player, ...: any): ...any
				return onServerInvoke(def, ctx, player, ...)
			end)
		else
			endpoint:onEvent(function(player: Player)
				onWrongDirection(def, ctx, player)
			end)
		end
		ctx:_register({
			name = def.name,
			namespace = namespace,
			kind = def.kind,
			inbound = inbound,
			endpoint = endpoint,
			limiter = def.limiter,
			metrics = def.metrics :: Context.RemoteMetrics,
		})
	elseif limit then
		def.clientLimiter = RateLimiter.new(limit, ctx.clock)
	end
end

function Remote.isRemote(value: any): boolean
	return definitions[value] ~= nil
end

Remote.NAME_PATTERN = NAME_PATTERN

return Remote
