--!strict
--[[
	RobloxTransport: endpoints backed by RemoteEvent, UnreliableRemoteEvent and RemoteFunction.

	Layout (created by the server when a namespace is bound):
	  ReplicatedStorage
	    RBLXSharedNet (Folder)
	      <Namespace> (Folder)
	        <Remote> (RemoteEvent | UnreliableRemoteEvent | RemoteFunction)

	The kill switch is mirrored to clients as a "Disabled" attribute on the remote, so the client
	can skip sending (and the UI can show the feature as unavailable) without a round trip.
]]

local Roblox = require("../Util/Roblox")
local Transport = require("./Transport")

export type ServerOptions = {
	-- Default ReplicatedStorage.
	parent: Instance?,
	-- Default "RBLXSharedNet".
	folderName: string?,
	players: Players?,
}

export type ClientOptions = {
	parent: Instance?,
	folderName: string?,
	-- Seconds to wait for a remote to replicate before erroring. Default 30.
	timeout: number?,
}

local DEFAULT_FOLDER = "RBLXSharedNet"
local DISABLED_ATTRIBUTE = "Disabled"

local CLASS_FOR_KIND: { [Transport.EndpointKind]: string } = {
	event = "RemoteEvent",
	unreliable = "UnreliableRemoteEvent",
	["function"] = "RemoteFunction",
}

local RobloxTransport = {}

local function unsupported(message: string): any
	return function()
		error("Net: " .. message, 2)
	end
end

RobloxTransport.FOLDER_NAME = DEFAULT_FOLDER
RobloxTransport.DISABLED_ATTRIBUTE = DISABLED_ATTRIBUTE

function RobloxTransport.server(options: ServerOptions?): Transport.ServerTransport
	local opts: ServerOptions = options or {}
	local parent: Instance = opts.parent or Roblox.service("ReplicatedStorage")
	local folderName = opts.folderName or DEFAULT_FOLDER
	local players: Players = opts.players or Roblox.service("Players")

	local root: Instance? = nil
	local namespaces: { [string]: Instance } = {}

	local function getRoot(): Instance
		local existing = root
		if existing then
			return existing
		end
		local found = parent:FindFirstChild(folderName)
		if found == nil then
			local folder = Instance.new("Folder")
			folder.Name = folderName
			folder.Parent = parent
			found = folder
		end
		root = found
		return found :: Instance
	end

	local function getNamespace(namespace: string): Instance
		local existing = namespaces[namespace]
		if existing then
			return existing
		end
		local container = getRoot()
		local found = container:FindFirstChild(namespace)
		if found == nil then
			local folder = Instance.new("Folder")
			folder.Name = namespace
			folder.Parent = container
			found = folder
		end
		namespaces[namespace] = found :: Instance
		return found :: Instance
	end

	local transport = { side = "server" } :: Transport.ServerTransport

	function transport.createEndpoint(
		_self: Transport.ServerTransport,
		namespace: string,
		name: string,
		kind: Transport.EndpointKind
	): Transport.ServerEndpoint
		local folder = getNamespace(namespace)
		assert(folder:FindFirstChild(name) == nil, "Net: remote " .. namespace .. "." .. name .. " already exists")
		local endpoint = {} :: Transport.ServerEndpoint
		local instance: Instance

		if kind == "function" then
			local remote = Instance.new("RemoteFunction")
			instance = remote
			function endpoint.onInvoke(_e: Transport.ServerEndpoint, handler: (player: Player, ...any) -> ...any)
				remote.OnServerInvoke = handler
			end
			function endpoint.onEvent(_e: Transport.ServerEndpoint, _handler: (player: Player, ...any) -> ())
				error("Net: functions have no event channel")
			end
			-- No server-to-client invoke: a client that never answers would stall the server.
			endpoint.fire = unsupported("server-to-client invoke is not supported")
			endpoint.fireAll = unsupported("server-to-client invoke is not supported")
		else
			-- RemoteEvent and UnreliableRemoteEvent share this surface.
			local remote: any = Instance.new(CLASS_FOR_KIND[kind] :: any)
			instance = remote
			function endpoint.onEvent(_e: Transport.ServerEndpoint, handler: (player: Player, ...any) -> ())
				remote.OnServerEvent:Connect(handler)
			end
			function endpoint.onInvoke(_e: Transport.ServerEndpoint, _handler: (player: Player, ...any) -> ...any)
				error("Net: events cannot be invoked")
			end
			function endpoint.fire(_e: Transport.ServerEndpoint, player: Player, ...: any)
				remote:FireClient(player, ...)
			end
			function endpoint.fireAll(_e: Transport.ServerEndpoint, ...: any)
				remote:FireAllClients(...)
			end
		end

		function endpoint.setEnabled(_e: Transport.ServerEndpoint, enabled: boolean)
			instance:SetAttribute(DISABLED_ATTRIBUTE, if enabled then nil else true)
		end

		instance.Name = name
		instance.Parent = folder
		return endpoint
	end

	function transport.getPlayers(_self: Transport.ServerTransport): { Player }
		return players:GetPlayers()
	end

	function transport.onPlayerRemoving(_self: Transport.ServerTransport, handler: (player: Player) -> ())
		players.PlayerRemoving:Connect(handler)
	end

	return transport
end

local function wrapClient(remote: Instance, kind: Transport.EndpointKind, label: string): Transport.ClientEndpoint
	local expectedClass = CLASS_FOR_KIND[kind]
	if remote.ClassName ~= expectedClass then
		error("Net: " .. label .. " is a " .. remote.ClassName .. ", expected " .. expectedClass)
	end
	local endpoint = {} :: Transport.ClientEndpoint
	local any: any = remote

	function endpoint.fire(_e: Transport.ClientEndpoint, ...: any)
		any:FireServer(...)
	end

	function endpoint.invoke(_e: Transport.ClientEndpoint, ...: any): ...any
		return any:InvokeServer(...)
	end

	function endpoint.onEvent(_e: Transport.ClientEndpoint, handler: (...any) -> ()): () -> ()
		local connection = any.OnClientEvent:Connect(handler)
		return function()
			connection:Disconnect()
		end
	end

	function endpoint.isEnabled(_e: Transport.ClientEndpoint): boolean
		return remote:GetAttribute(DISABLED_ATTRIBUTE) ~= true
	end

	return endpoint
end

function RobloxTransport.client(options: ClientOptions?): Transport.ClientTransport
	local opts: ClientOptions = options or {}
	local parent: Instance = opts.parent or Roblox.service("ReplicatedStorage")
	local folderName = opts.folderName or DEFAULT_FOLDER
	local timeout = opts.timeout or 30

	local transport = { side = "client" } :: Transport.ClientTransport

	function transport.findEndpoint(
		_self: Transport.ClientTransport,
		namespace: string,
		name: string,
		kind: Transport.EndpointKind
	): Transport.ClientEndpoint?
		local root = parent:FindFirstChild(folderName)
		local folder = root and root:FindFirstChild(namespace)
		local remote = folder and folder:FindFirstChild(name)
		if remote == nil then
			return nil
		end
		return wrapClient(remote, kind, namespace .. "." .. name)
	end

	function transport.waitForEndpoint(
		_self: Transport.ClientTransport,
		namespace: string,
		name: string,
		kind: Transport.EndpointKind
	): Transport.ClientEndpoint
		local label = namespace .. "." .. name
		local root = parent:WaitForChild(folderName, timeout)
		local folder = root and root:WaitForChild(namespace, timeout)
		local remote = folder and folder:WaitForChild(name, timeout)
		if remote == nil then
			error(
				"Net: remote "
					.. label
					.. " did not replicate within "
					.. tostring(timeout)
					.. " s. Is its namespace bound on the server at startup?"
			)
		end
		return wrapClient(remote, kind, label)
	end

	return transport
end

return RobloxTransport
