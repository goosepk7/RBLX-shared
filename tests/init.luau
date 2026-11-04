--!strict
--[[
	Lune entry point: `lune run tests [filter]`.

	Finds every tests/**/*.spec.luau, requires it under Test.beginFile(path), runs the suite,
	and exits 1 on any failure (or if a T.only is committed while running in CI).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Test = require("@shared/Test")

local filter: string? = process.args[1]

local function collect(dir: string, out: { string })
	local names = fs.readDir(dir)
	table.sort(names)
	for _, name in names do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			collect(path, out)
		elseif string.sub(name, -10) == ".spec.luau" then
			table.insert(out, path)
		end
	end
end

local files: { string } = {}
collect("tests", files)

local loadErrors = 0
for _, path in files do
	Test.beginFile(path)
	-- tests/foo/bar.spec.luau -> @tests/foo/bar.spec (require paths omit the extension)
	local modulePath = "@" .. string.sub(path, 1, -6)
	local ok, err = pcall(function()
		require(modulePath)
	end)
	if not ok then
		loadErrors += 1
		print(string.format("LOAD ERROR  %s\n      %s", path, tostring(err)))
	end
end

local result = Test.run({ filter = filter })
print(string.format("%d spec file(s)", #files))

local onlyInCI = Test.usesOnly() and process.env.CI ~= nil
if onlyInCI then
	print("FAIL  T.only is committed; remove it before merging")
end

if not result.ok or loadErrors > 0 or onlyInCI or #files == 0 then
	process.exit(1)
end
