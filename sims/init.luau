--!strict
--[[
	Lune entry point: `lune run sims [name-filter]`.

	Finds sims/**/*.sim.luau (each returns a Sim.Runner definition), runs them, and writes
	sims/out/<name>/summary.json, one CSV per recorded series, report.md, and any artifacts.
	Exits 1 if any sim fails.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Sim = require("@shared/Sim")

local filter: string? = process.args[1]
local outRoot = "sims/out"

local function collect(dir: string, out: { string })
	local names = fs.readDir(dir)
	table.sort(names)
	for _, name in names do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			if path ~= outRoot then
				collect(path, out)
			end
		elseif string.sub(name, -9) == ".sim.luau" then
			table.insert(out, path)
		end
	end
end

local files: { string } = {}
collect("sims", files)

local definitions: { Sim.Definition } = {}
local loadFailed = false
for _, path in files do
	local ok, definition = pcall(function()
		return (require :: any)("@" .. string.sub(path, 1, -6))
	end)
	if ok and type(definition) == "table" and type(definition.run) == "function" then
		if definition.environment ~= "studio" then
			table.insert(definitions, definition)
		end
	else
		loadFailed = true
		print(string.format("[SIM LOAD ERROR] %s: %s", path, tostring(definition)))
	end
end

local summary = Sim.Runner.runAll(definitions, nil, filter)

for _, result in summary.results do
	local dir = outRoot .. "/" .. string.gsub(result.name, "[^%w%._-]", "_")
	fs.writeDir(dir)
	local one = Sim.Runner.serialize({ ok = result.ok, passed = 0, failed = 0, results = { result } }).results[1]
	fs.writeFile(dir .. "/summary.json", Sim.Json.encode(one, true) .. "\n")
	for _, series in result.recorder:seriesNames() do
		fs.writeFile(dir .. "/" .. series .. ".csv", result.recorder:csv(series))
	end
	local report = {
		"# " .. result.name,
		"",
		result.description,
		"",
		string.format("Seed `%s`, %s, %.0f ms.", result.seed, if result.ok then "PASS" else "FAIL", result.durationMs),
		"",
	}
	local targets = Sim.Targets.new()
	for _, t in result.targets do
		targets:check(t.name, t.value, { min = t.min, max = t.max })
	end
	if #result.targets > 0 then
		table.insert(report, targets:markdown())
	end
	for _, note in result.notes do
		table.insert(report, "- " .. note)
	end
	if result.error then
		table.insert(report, "\n**Error:** `" .. result.error .. "`")
	end
	fs.writeFile(dir .. "/report.md", table.concat(report, "\n") .. "\n")
	for fileName, content in result.artifacts do
		fs.writeFile(dir .. "/" .. fileName, content)
	end
end

if not summary.ok or loadFailed or #definitions == 0 then
	process.exit(1)
end
