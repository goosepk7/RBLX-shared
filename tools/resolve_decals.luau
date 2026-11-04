--!strict
--[[
	Finishes images that upload_assets left "unresolved": uploaded as a Decal, Image id unknown.
	Nothing is re-uploaded; the Decal id in the manifest is enough.

	  lune run tools/resolve_decals                    resolve through Open Cloud (ROBLOX_API_KEY)
	  lune run tools/resolve_decals --studio-script    print a Studio command-bar script that
	                                                   resolves them with InsertService:LoadAsset
	  lune run tools/resolve_decals --apply ids.json   apply that script's output
	                                                   ({ "<name>": <imageId>, ... })

	Each resolved entry becomes "uploaded" with assetId = the Image id, and AssetIds.luau is
	regenerated. Options: --manifest <path>, --out <ids module path>.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Args = require("./lib/args")
local Decal = require("./lib/decal")
local Manifest = require("./lib/manifest")
local OpenCloud = require("./lib/opencloud")
local Paths = require("./lib/paths")

local args = Args.parse(process.args, { "manifest", "out", "apply" })
local paths = Paths.resolve(args:string("manifest"), args:string("out"))
local manifest = Manifest.load(paths.manifest)

local targets: { Manifest.Entry } = {}
for _, entry in manifest.assets do
	if entry.status == "unresolved" and entry.decalId then
		table.insert(targets, entry)
	end
end
table.sort(targets, function(a, b)
	return a.name < b.name
end)

if #targets == 0 then
	print("PASS  nothing unresolved")
	process.exit(0)
end

if args:has("studio-script") then
	local lines = {
		"-- Paste into the Studio command bar (place owned by the uploading account/group).",
		'local InsertService = game:GetService("InsertService")',
		"local decals = {",
	}
	for _, entry in targets do
		table.insert(lines, string.format("\t%s = %d,", entry.name, entry.decalId :: number))
	end
	for _, line in
		{
			"}",
			"local out = {}",
			"for name, decalId in decals do",
			"\tlocal ok, model = pcall(InsertService.LoadAsset, InsertService, decalId)",
			'\tlocal decal = ok and model:FindFirstChildWhichIsA("Decal", true)',
			'\tlocal id = decal and tonumber(string.match(decal.Texture, "%d+$"))',
			"\tif id and id ~= decalId then",
			"\t\tout[name] = id",
			"\telse",
			'\t\twarn("could not resolve " .. name)',
			"\tend",
			"\tif ok then",
			"\t\tmodel:Destroy()",
			"\tend",
			"end",
			'print(game:GetService("HttpService"):JSONEncode(out))',
			"-- Save the printed JSON to a file, then: lune run tools/resolve_decals --apply <file>",
		}
	do
		table.insert(lines, line)
	end
	print(table.concat(lines, "\n"))
	process.exit(0)
end

local resolved: { [string]: number } = {}
local failures: { string } = {}

local applyPath = args:string("apply")
if applyPath then
	local decoded = serde.decode("json", fs.readFile(applyPath))
	assert(type(decoded) == "table", "--apply: expected a JSON object of name -> image id")
	for _, entry in targets do
		local id = tonumber(decoded[entry.name])
		if id and id > 0 and id ~= entry.decalId then
			resolved[entry.name] = id
		else
			table.insert(failures, entry.name .. ": missing or invalid id in " .. applyPath)
		end
	end
else
	local apiKey = process.env.ROBLOX_API_KEY
	if apiKey == nil or apiKey == "" then
		print("FAIL  ROBLOX_API_KEY is not set (or use --studio-script / --apply)")
		process.exit(1)
	end
	local client = OpenCloud.new({ apiKey = apiKey :: string, log = print })
	for _, entry in targets do
		local id, err = Decal.resolve(client, entry.decalId :: number)
		if id then
			resolved[entry.name] = id
		else
			table.insert(failures, entry.name .. ": " .. tostring(err))
		end
	end
end

for _, entry in targets do
	local id = resolved[entry.name]
	if id then
		entry.status = "uploaded"
		entry.assetId = id
		print(string.format("ok    %s: image %d (decal %d)", entry.name, id, entry.decalId :: number))
	end
end
Manifest.save(paths.manifest, manifest)
fs.writeFile(paths.idsModule, Manifest.renderIds(manifest, paths.manifest))

for _, line in failures do
	print("FAIL  " .. line)
end
print(
	string.format(
		"%s  %d resolved, %d still unresolved",
		if #failures == 0 then "PASS" else "FAIL",
		#targets - #failures,
		#failures
	)
)
if #failures > 0 then
	print("Fallback: lune run tools/resolve_decals --studio-script")
	process.exit(1)
end
