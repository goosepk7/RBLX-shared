--!strict
--[[
	Net: every remote in both games goes through here (§3.3).

	Declare remotes once, in a module both sides require:

	  -- ReplicatedStorage/Stilts/Remotes.luau
	  local Net = require(Packages.RBLXShared).Net
	  local S = Net.Schema

	  return Net.namespace("Stilts", {
	  	Lunge = Net.clientEvent(S.number({ min = 0, max = 1 }), { rateLimit = { rate = 4, burst = 6 } }),
	  	BuyItem = Net.clientFunction(S.string({ maxLength = 32 }), S.boolean()),
	  	Banner = Net.serverEvent(S.string({ maxLength = 120 })),
	  })

	Server:
	  Remotes.Lunge:connect(function(player, charge) ... end)    -- charge: number, validated
	  Remotes.BuyItem:handle(function(player, itemId) return Shop.buy(player, itemId) end)
	  Remotes.Banner:fireAll("Flash flood incoming!")

	Client:
	  Remotes.Lunge:fire(0.8)
	  local result = Remotes.BuyItem:invokeAsync("skin_neon")
	  if result.ok then ... else warn(result.error) end
	  Remotes.Banner:connect(function(text) ... end)

	Every client-to-server message is checked in order: kill switch, rate limit (per player, per
	remote; default 10/s burst 20), argument count, schema, guard. Malformed traffic is dropped,
	counted in metrics, and reported to AntiExploit as a strike; three strikes flags the player.
]]

local AntiExploit = require("./AntiExploit")
local Context = require("@self/Context")
local KillSwitch = require("@self/KillSwitch")
local LoopbackTransport = require("@self/LoopbackTransport")
local RateLimiter = require("@self/RateLimiter")
local Remote = require("@self/Remote")
local RobloxTransport = require("@self/RobloxTransport")
local Roblox = require("./Util/Roblox")
local Schema = require("@self/Schema")
local Transport = require("@self/Transport")

export type Schema<T> = Schema.Schema<T>
export type RateLimit = RateLimiter.RateLimit
export type Context = Context.Context
export type ContextOptions = Context.ContextOptions
export type RemoteMetrics = Context.RemoteMetrics
export type KillState = Context.KillState
export type KillEntry = Context.KillEntry
export type ClientEvent<T> = Remote.ClientEvent<T>
export type ServerEvent<T> = Remote.ServerEvent<T>
export type ClientFunction<Req, Res> = Remote.ClientFunction<Req, Res>
export type ClientEventOptions = Remote.ClientEventOptions
export type ServerEventOptions = Remote.ServerEventOptions
export type ClientFunctionOptions = Remote.ClientFunctionOptions
export type InvokeResult<T> = Remote.InvokeResult<T>
export type InvokeError = Remote.InvokeError
export type Connection = Remote.Connection
export type ServerTransport = Transport.ServerTransport
export type ClientTransport = Transport.ClientTransport
export type Loopback = LoopbackTransport.Loopback
export type KillSwitch = KillSwitch.KillSwitch

-- Net.KillSwitch.new options. Every field is optional; see Net/KillSwitch.luau for defaults.
export type KillSwitchOptions = {
	-- Default Net.getDefaultContext().
	context: Context?,
	dataStoreService: any?,
	-- Pass false to rely on polling only.
	messagingService: any?,
	storeName: string?,
	key: string?,
	topic: string?,
	pollInterval: number?,
	now: (() -> number)?,
}

export type NamespaceOptions = {
	-- Default Net.getDefaultContext().
	context: Context?,
	-- Guard for every inbound remote in the namespace that does not set its own.
	guard: ((player: Player) -> boolean)?,
}

local Net = {}

Net.Schema = Schema
Net.RateLimiter = RateLimiter
Net.Loopback = LoopbackTransport
Net.RobloxTransport = RobloxTransport

Net.clientEvent = Remote.clientEvent
Net.serverEvent = Remote.serverEvent
Net.clientFunction = Remote.clientFunction
Net.isRemote = Remote.isRemote

local defaultContext: Context? = nil

function Net.newContext(options: ContextOptions): Context
	return Context.new(options)
end

-- The Roblox context for this side, built on first use.
function Net.getDefaultContext(): Context
	local existing = defaultContext
	if existing then
		return existing
	end
	local side = Roblox.side()
	if side == nil then
		error(
			"Net: there is no default context outside Roblox. Build one with Net.newContext({ side = ..., "
				.. "transport = Net.Loopback.new()... }) and pass it to Net.namespace, or call Net.setDefaultContext.",
			2
		)
	end
	local created: Context
	if side == "server" then
		created = Context.new({
			side = "server",
			transport = RobloxTransport.server(),
			task = Roblox.task(),
			strikes = AntiExploit.default(),
			validateOutgoing = Roblox.isStudio(),
		})
	else
		created = Context.new({
			side = "client",
			transport = RobloxTransport.client(),
			task = Roblox.task(),
			validateOutgoing = Roblox.isStudio(),
		})
	end
	defaultContext = created
	return created
end

-- Replaces the default context (tests, sims). nil resets it.
function Net.setDefaultContext(ctx: Context?)
	defaultContext = ctx
end

--[[
	Names and binds a table of remote definitions. Returns the same table, so its precise
	types flow to callers. On the server this creates the remote instances immediately: bind
	every namespace during server startup so clients find them.
]]
function Net.namespace<T>(name: string, remotes: T, options: NamespaceOptions?): T
	assert(
		type(name) == "string" and string.match(name, Remote.NAME_PATTERN),
		"Net.namespace: name must be an identifier"
	)
	assert(type(remotes) == "table", "Net.namespace: expected a table of remotes")
	local opts: NamespaceOptions = options or {}
	local ctx = opts.context or Net.getDefaultContext()
	ctx:_claimNamespace(name)
	local keys: { string } = {}
	for key in remotes :: any do
		assert(type(key) == "string", "Net.namespace: remote keys must be strings")
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		Remote.bind((remotes :: any)[key], ctx, name, key, opts.guard)
	end
	return remotes
end

--[[ Server conveniences on the default context ]]

-- Local kill switch for this server. For every server use Net.KillSwitch.
function Net.setEnabled(name: string, enabled: boolean, reason: string?)
	Net.getDefaultContext():setEnabled(name, enabled, reason)
end

function Net.setAllEnabled(enabled: boolean, reason: string?)
	Net.getDefaultContext():setAllEnabled(enabled, reason)
end

function Net.isEnabled(name: string): boolean
	return Net.getDefaultContext():isEnabled(name)
end

function Net.getMetrics(): { [string]: RemoteMetrics }
	return Net.getDefaultContext():getMetrics()
end

--[[
	Cross-server kill switch bound to a context (default: the default server context).

	  local switch = Net.KillSwitch.new()
	  switch:startAsync()
]]
Net.KillSwitch = {
	new = function(options: KillSwitchOptions?): KillSwitch
		local opts: KillSwitchOptions = options or {}
		return KillSwitch.new({
			context = opts.context or Net.getDefaultContext(),
			dataStoreService = opts.dataStoreService,
			messagingService = opts.messagingService,
			storeName = opts.storeName,
			key = opts.key,
			topic = opts.topic,
			pollInterval = opts.pollInterval,
			now = opts.now,
		})
	end,
}

return Net
