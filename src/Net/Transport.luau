--!strict
--[[
	Transport: the seam between Net's logic and the wire.

	Net's validation, rate limiting, kill switch and metrics never touch Roblox instances
	directly; they talk to a transport. RobloxTransport maps endpoints to RemoteEvent,
	UnreliableRemoteEvent and RemoteFunction instances. LoopbackTransport delivers in memory so
	the whole client/server flow runs under lune.
]]

export type EndpointKind = "event" | "unreliable" | "function"

export type ServerEndpoint = {
	-- Client-to-server traffic for events. The handler gets the sender and raw arguments.
	onEvent: (self: ServerEndpoint, handler: (player: Player, ...any) -> ()) -> (),
	-- Client-to-server invocation for functions. Whatever the handler returns goes back.
	onInvoke: (self: ServerEndpoint, handler: (player: Player, ...any) -> ...any) -> (),
	fire: (self: ServerEndpoint, player: Player, ...any) -> (),
	fireAll: (self: ServerEndpoint, ...any) -> (),
	-- Mirrors the kill switch to clients (RobloxTransport: a "Disabled" attribute).
	setEnabled: (self: ServerEndpoint, enabled: boolean) -> (),
}

export type ClientEndpoint = {
	fire: (self: ClientEndpoint, ...any) -> (),
	-- Yields until the server answers.
	invoke: (self: ClientEndpoint, ...any) -> ...any,
	-- Returns a function that disconnects the handler.
	onEvent: (self: ClientEndpoint, handler: (...any) -> ()) -> () -> (),
	isEnabled: (self: ClientEndpoint) -> boolean,
}

export type ServerTransport = {
	side: "server",
	createEndpoint: (self: ServerTransport, namespace: string, name: string, kind: EndpointKind) -> ServerEndpoint,
	getPlayers: (self: ServerTransport) -> { Player },
	-- Called with each player as they leave so per-player state can be dropped.
	onPlayerRemoving: (self: ServerTransport, handler: (player: Player) -> ()) -> (),
}

export type ClientTransport = {
	side: "client",
	-- Returns the endpoint if it already exists, without yielding.
	findEndpoint: (self: ClientTransport, namespace: string, name: string, kind: EndpointKind) -> ClientEndpoint?,
	-- Yields until the endpoint exists; errors after the transport's timeout.
	waitForEndpoint: (self: ClientTransport, namespace: string, name: string, kind: EndpointKind) -> ClientEndpoint,
}

return {}
