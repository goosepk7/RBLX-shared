--!strict
--[[
	Lazy access to Roblox globals for dependency defaults.

	Framework modules never touch `game`, `task`, or `Enum` at require time (lune has none of
	them). Constructors take dependencies and fall back to these helpers, which fail with a clear
	message when a dependency was not injected outside Roblox:

	  local players = deps.players or Roblox.service("Players")
]]

local Roblox = {}

local function missing(what: string): never
	error(
		"RBLXShared: "
			.. what
			.. " is not available outside Roblox. Pass it as a dependency (deps) when running under lune.",
		3
	)
end

function Roblox.isRoblox(): boolean
	return (game :: any) ~= nil
end

function Roblox.service(name: string): any
	local dataModel = game :: any
	if dataModel == nil then
		return missing('game:GetService("' .. name .. '")')
	end
	return dataModel:GetService(name)
end

function Roblox.task(): any
	local taskLib = task :: any
	if taskLib == nil then
		return missing("the task library")
	end
	return taskLib
end

function Roblox.enum(): any
	local enums = Enum :: any
	if enums == nil then
		return missing("Enum")
	end
	return enums
end

-- False outside Roblox (lune counts as "not Studio").
function Roblox.isStudio(): boolean
	local dataModel = game :: any
	if dataModel == nil then
		return false
	end
	return dataModel:GetService("RunService"):IsStudio()
end

-- "server" or "client" inside Roblox; nil under lune.
function Roblox.side(): ("server" | "client")?
	local dataModel = game :: any
	if dataModel == nil then
		return nil
	end
	return if dataModel:GetService("RunService"):IsServer() then "server" else "client"
end

function Roblox.jobId(): string
	local dataModel = game :: any
	if dataModel == nil then
		return "lune"
	end
	local jobId = dataModel.JobId
	-- Studio test servers have an empty JobId.
	return if jobId == "" then "studio" else jobId
end

function Roblox.placeId(): number
	local dataModel = game :: any
	if dataModel == nil then
		return 0
	end
	return dataModel.PlaceId
end

return Roblox
