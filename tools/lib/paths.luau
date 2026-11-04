--!strict
--[[
	Where the asset manifest and generated ids module live. Defaults suit RBLXShared; a game
	repo sets its own in assets/config.json:

		{ "idsModule": "src/ReplicatedStorage/Stilts/AssetIds.luau" }

	All paths are relative to the current directory (run tools from the repo root).
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

export type Paths = { manifest: string, idsModule: string }

local Paths = {}

function Paths.resolve(manifestOverride: string?, idsOverride: string?): Paths
	local manifest = manifestOverride or "assets/manifest.json"
	local ids = "src/Assets/AssetIds.luau"
	local configPath = "assets/config.json"
	if fs.isFile(configPath) then
		local config = serde.decode("json", fs.readFile(configPath))
		if type(config) == "table" and type(config.idsModule) == "string" then
			ids = config.idsModule
		end
	end
	return { manifest = manifest, idsModule = idsOverride or ids }
end

return Paths
