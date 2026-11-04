--!strict
--[[
	LoopbackTransport: an in-memory wire for running client and server Net code in one VM
	(lune unit tests, headless sims, game-level tests of remote handlers).

	  local loop = Net.Loopback.new()
	  local server = Net.newContext({ side = "server", transport = loop.server, task = clock.task })
	  local client = Net.newContext({ side = "client", transport = loop:connect(player) })

	Delivery is synchronous. Arguments are copied the way Roblox serializes them (tables are
	deep-copied without metatables; functions and threads arrive as nil), so handlers never
	share references with the sender.
]]

local Transport = require("./Transport")

type EndpointState = {
	kind: Transport.EndpointKind,
	label: string,
	enabled: boolean,
	onEvent: ((player: Player, ...any) -> ())?,
	onInvoke: ((player: Player, ...any) -> ...any)?,
	clientHandlers: { [Player]: { (...any) -> () } },
}

export type Loopback = {
	server: Transport.ServerTransport,
	-- Joins a player and returns that player's client transport.
	connect: (self: Loopback, player: Player) -> Transport.ClientTransport,
	-- Removes a player (server sees PlayerRemoving).
	disconnect: (self: Loopback, player: Player) -> (),
	-- Raw client-to-server send that skips client-side validation, to simulate a modified
	-- client in tests. `name` is "Namespace.Remote".
	injectFromClient: (self: Loopback, player: Player, name: string, ...any) -> (),
	-- Raw client-to-server invoke that skips client-side validation.
	injectInvoke: (self: Loopback, player: Player, name: string, ...any) -> ...any,
	isEnabled: (self: Loopback, name: string) -> boolean,
}

local LoopbackTransport = {}

local function copyValue(value: any, seen: { [any]: any }): any
	local kind = type(value)
	if kind == "function" or kind == "thread" then
		return nil
	end
	if kind ~= "table" then
		return value
	end
	if seen[value] then
		error("Net.Loopback: cannot send a table that contains itself", 0)
	end
	seen[value] = true
	local result = {}
	for key, child in value do
		local copiedKey = copyValue(key, seen)
		if copiedKey ~= nil then
			result[copiedKey] = copyValue(child, seen)
		end
	end
	seen[value] = nil
	return result
end

local function copyArgs(...: any): ...any
	local count = select("#", ...)
	local args = { ... }
	for index = 1, count do
		args[index] = copyValue(args[index], {})
	end
	return table.unpack(args, 1, count)
end

function LoopbackTransport.new(): Loopback
	local endpoints: { [string]: EndpointState } = {}
	local order: { Player } = {}
	local leaveHandlers: { (player: Player) -> () } = {}

	local server = { side = "server" } :: Transport.ServerTransport

	function server.createEndpoint(
		_self: Transport.ServerTransport,
		namespace: string,
		name: string,
		kind: Transport.EndpointKind
	): Transport.ServerEndpoint
		local label = namespace .. "." .. name
		assert(endpoints[label] == nil, "Net: remote " .. label .. " already exists")
		local state: EndpointState = {
			kind = kind,
			label = label,
			enabled = true,
			onEvent = nil,
			onInvoke = nil,
			clientHandlers = {},
		}
		endpoints[label] = state

		local endpoint = {} :: Transport.ServerEndpoint

		function endpoint.onEvent(_e: Transport.ServerEndpoint, handler: (player: Player, ...any) -> ())
			assert(kind ~= "function", "Net: functions have no event channel")
			state.onEvent = handler
		end

		function endpoint.onInvoke(_e: Transport.ServerEndpoint, handler: (player: Player, ...any) -> ...any)
			assert(kind == "function", "Net: events cannot be invoked")
			state.onInvoke = handler
		end

		local function deliver(player: Player, ...: any)
			local handlers = state.clientHandlers[player]
			if handlers == nil then
				return
			end
			for _, handler in table.clone(handlers) do
				handler(copyArgs(...))
			end
		end

		function endpoint.fire(_e: Transport.ServerEndpoint, player: Player, ...: any)
			assert(kind ~= "function", "Net: server-to-client invoke is not supported")
			deliver(player, ...)
		end

		function endpoint.fireAll(_e: Transport.ServerEndpoint, ...: any)
			assert(kind ~= "function", "Net: server-to-client invoke is not supported")
			for _, player in table.clone(order) do
				deliver(player, ...)
			end
		end

		function endpoint.setEnabled(_e: Transport.ServerEndpoint, enabled: boolean)
			state.enabled = enabled
		end

		return endpoint
	end

	function server.getPlayers(_self: Transport.ServerTransport): { Player }
		return table.clone(order)
	end

	function server.onPlayerRemoving(_self: Transport.ServerTransport, handler: (player: Player) -> ())
		table.insert(leaveHandlers, handler)
	end

	local loop = { server = server } :: Loopback

	local function clientEndpoint(player: Player, state: EndpointState, kind: Transport.EndpointKind)
		assert(state.kind == kind, "Net: " .. state.label .. " is a " .. state.kind .. " endpoint, not " .. kind)
		local endpoint = {} :: Transport.ClientEndpoint

		function endpoint.fire(_e: Transport.ClientEndpoint, ...: any)
			local handler = state.onEvent
			if handler then
				handler(player, copyArgs(...))
			end
		end

		function endpoint.invoke(_e: Transport.ClientEndpoint, ...: any): ...any
			local handler = state.onInvoke
			if handler == nil then
				error("Net.Loopback: " .. state.label .. " has no server handler")
			end
			return copyArgs(handler(player, copyArgs(...)))
		end

		function endpoint.onEvent(_e: Transport.ClientEndpoint, handler: (...any) -> ()): () -> ()
			local handlers = state.clientHandlers[player]
			if handlers == nil then
				handlers = {}
				state.clientHandlers[player] = handlers
			end
			table.insert(handlers, handler)
			return function()
				local list = state.clientHandlers[player]
				if list then
					local index = table.find(list, handler)
					if index then
						table.remove(list, index)
					end
				end
			end
		end

		function endpoint.isEnabled(_e: Transport.ClientEndpoint): boolean
			return state.enabled
		end

		return endpoint
	end

	function loop.connect(_self: Loopback, player: Player): Transport.ClientTransport
		assert(table.find(order, player) == nil, "Net.Loopback: player is already connected")
		table.insert(order, player)
		local client = { side = "client" } :: Transport.ClientTransport

		function client.findEndpoint(
			_c: Transport.ClientTransport,
			namespace: string,
			name: string,
			kind: Transport.EndpointKind
		): Transport.ClientEndpoint?
			local state = endpoints[namespace .. "." .. name]
			if state == nil then
				return nil
			end
			return clientEndpoint(player, state, kind)
		end

		function client.waitForEndpoint(
			_c: Transport.ClientTransport,
			namespace: string,
			name: string,
			kind: Transport.EndpointKind
		): Transport.ClientEndpoint
			local state = endpoints[namespace .. "." .. name]
			if state == nil then
				error("Net.Loopback: remote " .. namespace .. "." .. name .. " is not bound on the server")
			end
			return clientEndpoint(player, state, kind)
		end

		return client
	end

	function loop.disconnect(_self: Loopback, player: Player)
		local index = table.find(order, player)
		assert(index, "Net.Loopback: player is not connected")
		for _, handler in table.clone(leaveHandlers) do
			handler(player)
		end
		table.remove(order, index)
		for _, state in endpoints do
			state.clientHandlers[player] = nil
		end
	end

	function loop.injectFromClient(_self: Loopback, player: Player, name: string, ...: any)
		local state = endpoints[name]
		assert(state, "Net.Loopback: unknown remote " .. name)
		local handler = state.onEvent
		if handler then
			handler(player, copyArgs(...))
		end
	end

	function loop.injectInvoke(_self: Loopback, player: Player, name: string, ...: any): ...any
		local state = endpoints[name]
		assert(state, "Net.Loopback: unknown remote " .. name)
		local handler = state.onInvoke
		assert(handler, "Net.Loopback: " .. name .. " is not a function remote")
		return copyArgs(handler(player, copyArgs(...)))
	end

	function loop.isEnabled(_self: Loopback, name: string): boolean
		local state = endpoints[name]
		return state ~= nil and state.enabled
	end

	return loop
end

return LoopbackTransport
