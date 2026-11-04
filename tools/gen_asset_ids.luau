--!strict
--[[
	Regenerates the AssetIds.luau module from assets/manifest.json.

	  lune run tools/gen_asset_ids            write it
	  lune run tools/gen_asset_ids --check    exit 1 if it is out of date (CI)

	Options: --manifest <path>, --out <path> (defaults from tools/lib/paths.luau).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Args = require("./lib/args")
local Manifest = require("./lib/manifest")
local Paths = require("./lib/paths")

local args = Args.parse(process.args, { "manifest", "out" })
local paths = Paths.resolve(args:string("manifest"), args:string("out"))

local manifest = Manifest.load(paths.manifest)
local rendered = Manifest.renderIds(manifest, paths.manifest)

if args:has("check") then
	local current = if fs.isFile(paths.idsModule) then fs.readFile(paths.idsModule) else ""
	if current ~= rendered then
		print(string.format("FAIL  %s is out of date with %s", paths.idsModule, paths.manifest))
		print("      run: lune run tools/gen_asset_ids")
		process.exit(1)
	end
	print(string.format("PASS  %s matches %s (%d assets)", paths.idsModule, paths.manifest, #manifest.assets))
else
	fs.writeFile(paths.idsModule, rendered)
	print(string.format("wrote %s (%d assets)", paths.idsModule, #manifest.assets))
end
