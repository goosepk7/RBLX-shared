--!strict
-- The v0.2 screens' strings: every key the screens use exists, and every key in their areas is
-- used. (tests/Loc/Strings.spec.luau checks completeness and placeholders for all of Strings.)
local Strings = require("@shared/Strings")
local T = require("@shared/Test")
local fs = require("@lune/fs")

local expect = T.expect

-- The areas the screens own.
local AREAS = {
	"shop",
	"rebirth",
	"codes",
	"leaderboards",
	"daily",
	"events",
	"badges",
	"tutorial",
	"rewards",
	"time",
	"errors",
}

-- Keys the screens build from a code or id at runtime ("shop.fail." .. reason).
local DYNAMIC_PREFIXES = {
	"shop.tab.",
	"shop.fail.",
	"rebirth.part.",
	"rebirth.fail.",
	"codes.fail.",
	"daily.fail.",
	"events.fail.",
	"errors.",
}

local function screenSources(): string
	local parts: { string } = {}
	for _, name in fs.readDir("src/Screens") do
		if string.sub(name, -5) == ".luau" then
			table.insert(parts, fs.readFile("src/Screens/" .. name))
		end
	end
	return table.concat(parts, "\n")
end

local function inArea(key: string): boolean
	local area = string.match(key, "^(%l%w*)%.")
	return area ~= nil and table.find(AREAS, area) ~= nil
end

T.describe("Screens strings", function()
	T.it("has every key the screens use, and no unused ones in their areas", function()
		local source = screenSources()
		local en = Strings.en
		for key in string.gmatch(source, '"(%l%w*%.[%w%.]+)"') do
			if (inArea(key) or string.sub(key, 1, 7) == "common.") and string.sub(key, -1) ~= "." then
				expect(if en[key] ~= nil then key else "missing " .. key).toBe(key)
			end
		end
		for key in en do
			if inArea(key) then
				local used = string.find(source, '"' .. key .. '"', 1, true) ~= nil
				for _, prefix in DYNAMIC_PREFIXES do
					if string.sub(key, 1, #prefix) == prefix then
						used = true
					end
				end
				expect(if used then key else "unused " .. key).toBe(key)
			end
		end
	end)
end)
