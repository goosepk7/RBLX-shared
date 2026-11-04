--!strict
--[[
	Writes a World spec as a deterministic .rbxmx (brief §8: worlds are built by generator
	scripts from layout data). Games call this from their own generator tool:

		local Model = require("@sharedtools/lib/model")
		Model.run(HubLayout.build(), "src/Workspace/Hub.rbxmx", process.args)

	`--check` compares instead of writing and exits 1 on drift, so CI catches a layout edit
	without a regenerated file. Output is byte-stable: World.instantiate applies attributes,
	properties and tags in sorted order and lune's serializer numbers referents in tree order.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

-- Relative, not @shared: game repos run this through the submodule, where the package's
-- .luaurc aliases do not apply (lune resolves aliases from the entry script's config).
local World = require("../../src/World")

local Model = {}

function Model.env(): World.Env
	-- The lune typedefs only declare `Instance`; the datatype constructors exist at runtime.
	local lib = roblox :: any
	return {
		Instance = lib.Instance,
		Vector3 = lib.Vector3,
		CFrame = lib.CFrame,
		Color3 = lib.Color3,
		Enum = lib.Enum,
	}
end

--- The .rbxmx text for a spec.
function Model.render(spec: World.Spec): string
	local inst = World.instantiate(spec, Model.env())
	local xml = roblox.serializeModel({ inst :: any }, true)
	-- Normalise line endings so the file is the same on every OS.
	return (string.gsub(xml, "\r\n", "\n"))
end

--- Writes (or with check, compares) one model file. Returns true when the file is current.
function Model.write(spec: World.Spec, outPath: string, options: { check: boolean? }?): boolean
	local rendered = Model.render(spec)
	if options and options.check then
		local current = if fs.isFile(outPath) then fs.readFile(outPath) else ""
		return current == rendered
	end
	local dir = string.match(outPath, "^(.*)/[^/]+$")
	if dir and not fs.isDir(dir) then
		fs.writeDir(dir)
	end
	fs.writeFile(outPath, rendered)
	return true
end

--- CLI helper: writes or checks, prints a PASS/FAIL line with the part count, exits 1 on drift.
function Model.run(spec: World.Spec, outPath: string, argv: { string }, regenerate: string?)
	local check = table.find(argv, "--check") ~= nil
	local stats = World.stats(spec)
	if check then
		if Model.write(spec, outPath, { check = true }) then
			print(string.format("PASS  %s is current (%d parts)", outPath, stats.parts))
		else
			print(string.format("FAIL  %s is out of date with its layout", outPath))
			if regenerate then
				print("      run: " .. regenerate)
			end
			process.exit(1)
		end
	else
		Model.write(spec, outPath)
		print(string.format("wrote %s (%d parts, %d instances)", outPath, stats.parts, stats.instances))
	end
end

return Model
