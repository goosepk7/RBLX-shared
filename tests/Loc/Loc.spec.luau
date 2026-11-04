--!strict
local Loc = require("@shared/Loc")
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")
local expect = T.expect

local function tables(): Loc.Tables
	return {
		en = {
			["hud.wins"] = "Wins",
			["win.title"] = "+{wins} WINS",
			["height"] = "{height} studs",
			["lunges"] = { one = "{count} lunge", other = "{count} lunges" },
			["only.en"] = "Only English",
		},
		["pt-br"] = {
			["hud.wins"] = "Vitórias",
			["win.title"] = "+{wins} VITÓRIAS",
			["height"] = "{height} studs",
			["lunges"] = { one = "{count} investida", other = "{count} investidas" },
		},
		es = {
			["hud.wins"] = "Victorias",
			["win.title"] = "+{wins} VICTORIAS",
			["height"] = "{height} studs",
			["lunges"] = { one = "{count} embestida", other = "{count} embestidas" },
		},
	}
end

T.describe("Loc.normalize", function()
	T.it("maps Roblox LocaleIds to shipped locales", function()
		expect(Loc.normalize("en-us")).toBe("en")
		expect(Loc.normalize("pt-br")).toBe("pt-br")
		expect(Loc.normalize("pt-pt")).toBe("pt-br")
		expect(Loc.normalize("es-mx")).toBe("es")
		expect(Loc.normalize("es_ES")).toBe("es")
		expect(Loc.normalize("ja-jp")).toBe("en")
		expect(Loc.normalize(nil)).toBe("en")
	end)
end)

T.describe("Loc.pluralCategory", function()
	T.it("follows CLDR for en, es and pt", function()
		expect(Loc.pluralCategory("en", 1)).toBe("one")
		expect(Loc.pluralCategory("en", 0)).toBe("other")
		expect(Loc.pluralCategory("es", 2)).toBe("other")
		expect(Loc.pluralCategory("pt-br", 0)).toBe("one")
		expect(Loc.pluralCategory("pt-br", 1)).toBe("one")
		expect(Loc.pluralCategory("pt-br", 2)).toBe("other")
	end)
end)

T.describe("Loc numbers", function()
	T.it("uses the locale's separators", function()
		expect(Loc.grouped(1234567, "en")).toBe("1,234,567")
		expect(Loc.grouped(1234567, "pt-br")).toBe("1.234.567")
		expect(Loc.compact(1250, "en")).toBe("1.2K")
		expect(Loc.compact(1250, "es")).toBe("1,2K")
		expect(Loc.number(2.5, "en")).toBe("2.5")
		expect(Loc.number(2.5, "pt-br")).toBe("2,5")
		expect(Loc.number(1234.5, "es")).toBe("1.234,5")
		expect(Loc.number(-3.25, "en")).toBe("-3.2")
		expect(Loc.number(7, "en")).toBe("7")
		expect(Loc.number(0 / 0, "en")).toBe("0")
	end)
end)

T.describe("Loc instance", function()
	T.it("interpolates and formats placeholders", function()
		local loc = Loc.new({ tables = tables() })
		expect(loc:t("win.title", { wins = 1200 })).toBe("+1,200 WINS")
		expect(loc:t("height", { height = 12.75 })).toBe("12.8 studs")
		expect(Loc.interpolate("{n:compact} / {n:raw} / {missing}", { n = 4500 })).toBe("4.5K / 4500 / {missing}")
	end)

	T.it("switches locale and falls back to the source", function()
		local loc = Loc.new({ tables = tables(), locale = "pt-BR" })
		expect(loc:getLocale()).toBe("pt-br")
		expect(loc:t("hud.wins")).toBe("Vitórias")
		expect(loc:t("win.title", { wins = 1200 })).toBe("+1.200 VITÓRIAS")
		expect(loc:t("only.en")).toBe("Only English")
		expect(loc:setLocale("fr-fr")).toBe("en")
	end)

	T.it("picks plural forms", function()
		local loc = Loc.new({ tables = tables() })
		expect(loc:plural("lunges", 1)).toBe("1 lunge")
		expect(loc:plural("lunges", 3)).toBe("3 lunges")
		expect(loc:t("lunges", { count = 1 })).toBe("1 lunge")
		loc:setLocale("pt-br")
		expect(loc:plural("lunges", 0)).toBe("0 investida")
		expect(loc:plural("lunges", 2)).toBe("2 investidas")
	end)

	T.it("returns the key and warns once for a missing string", function()
		local entries, restore = Log.capture()
		local loc = Loc.new({ tables = tables() })
		expect(loc:t("nope")).toBe("nope")
		expect(loc:t("nope")).toBe("nope")
		restore()
		expect(#entries).toBe(1)
		expect(entries[1].level).toBe("warn")
		expect(loc:has("nope")).toBe(false)
	end)

	T.it("notifies locale listeners", function()
		local loc = Loc.new({ tables = tables() })
		local seen: { string } = {}
		local off = loc:onLocaleChanged(function(locale)
			table.insert(seen, locale)
		end)
		loc:setLocale("es")
		loc:setLocale("es")
		off()
		loc:setLocale("en")
		expect(seen).toEqual({ "es" })
	end)
end)

T.describe("Loc.validate", function()
	T.it("passes matching tables except for real gaps", function()
		local issues = Loc.validate(tables())
		-- only.en is missing in both translations.
		expect(#issues).toBe(2)
		expect(issues[1].kind).toBe("missing")
		expect(issues[1].key).toBe("only.en")
	end)

	T.it("finds placeholder mismatches, extra keys and missing plural forms", function()
		local t = tables()
		t.en["only.en"] = nil
		t["pt-br"]["only.en"] = nil
		(t["pt-br"] :: any)["win.title"] = "+{vitorias} VITÓRIAS"
		(t.es :: any)["lunges"] = { other = "{count} embestidas" }
		(t.es :: any)["stray"] = "x"
		local kinds: { string } = {}
		for _, issue in Loc.validate(t) do
			table.insert(kinds, issue.locale .. ":" .. issue.key .. ":" .. issue.kind)
		end
		table.sort(kinds)
		expect(kinds).toEqual({ "es:lunges:pluralForms", "es:stray:extra", "pt-br:win.title:placeholders" })
	end)
end)

T.describe("Loc.toCsv", function()
	T.it("writes Roblox's localization table columns", function()
		local csv = Loc.toCsv({ en = { a = 'Say "hi"' }, es = { a = "Hola" } })
		expect(csv).toBe('Key,Source,Context,Example,en,es\n"a","Say ""hi""","","","Say ""hi""","Hola"\n')
	end)
end)
