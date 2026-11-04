--!strict
--[[
	Static guard for §5.8 anti-patterns inside the UI module: no legacy
	fonts, no literal colors outside Theme, no untouched default text.
]]
local fs = require("@lune/fs")
local T = require("@shared/Test")

local ROOT = "src/UI"

local function collect(dir: string, out: { string })
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			collect(path, out)
		elseif string.sub(name, -5) == ".luau" then
			table.insert(out, path)
		end
	end
end

local files: { string } = {}
collect(ROOT, files)
table.sort(files)

local BANNED: { { pattern: string, why: string, allow: { [string]: boolean }? } } = {
	{ pattern = "Enum%.Font%.", why = "legacy Font enum; use Theme.font" },
	{ pattern = "SourceSans", why = "default font (§5.8)" },
	{ pattern = "Arial", why = "default font (§5.8)" },
	{
		pattern = "Color3%.fromRGB%(",
		why = "literal color; use Theme.color",
		allow = { ["src/UI/Theme.luau"] = true },
	},
	{ pattern = "Color3%.new%(", why = "literal color; use Theme.color" },
	{ pattern = "Color3%.fromHex%(", why = "literal color; use Theme.color" },
	{ pattern = "BrickColor", why = "literal color; use Theme.color" },
	{ pattern = "TODO", why = "placeholder text (§2.1.5)" },
}

T.describe("UI anti-patterns (§5.8)", function()
	T.it("scans at least the kit", function()
		T.expect(#files >= 20).toBe(true)
	end)

	for _, rule in BANNED do
		T.it("no " .. rule.why, function()
			local hits: { string } = {}
			for _, path in files do
				if rule.allow and rule.allow[path] then
					continue
				end
				local source = fs.readFile(path)
				local line = 0
				for text in string.gmatch(source .. "\n", "([^\n]*)\n") do
					line += 1
					if string.find(text, rule.pattern) then
						table.insert(hits, `{path}:{line}`)
					end
				end
			end
			if #hits > 0 then
				error(rule.why .. " at " .. table.concat(hits, ", "))
			end
		end)
	end
end)
