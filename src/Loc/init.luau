--!strict
--[[
	Loc: every player-facing string goes through here (brief §3.1, §4).

	A game declares its string tables in code, one table per locale, keyed by string id:

		local loc = Loc.new({
			source = "en",
			tables = {
				en = { ["hud.wins"] = "Wins", ["win.title"] = "+{wins} WINS", ["lunges"] = { one = "{count} lunge", other = "{count} lunges" } },
				["pt-br"] = { ["hud.wins"] = "Vitórias", ... },
				es = { ["hud.wins"] = "Victorias", ... },
			},
		})
		loc:setLocale(Loc.normalize(player.LocaleId))
		loc:t("win.title", { wins = 12 })         --> "+12 WINS"
		loc:plural("lunges", 3)                    --> "3 lunges"

	Placeholders: `{name}` inserts the argument (numbers are grouped: 1,234 / 1.234), and
	`{name:compact}` (1.2K / 1,2K), `{name:grouped}`, `{name:raw}` pick a format. Missing
	translations fall back to the source locale; a key missing from the source returns the key
	and warns once, so a gap is visible and never a crash. `Loc.validate` finds missing keys,
	extra keys, placeholder mismatches and missing plural forms for a test to assert on.

	Number formats wrap UI.Format so the kit and Loc agree. Pure; safe under lune.
]]

local Format = require("./UI/Format")
local Log = require("./Util/Log")

export type Entry = string | { [string]: string }
export type Table = { [string]: Entry }
export type Tables = { [string]: Table }
export type Args = { [string]: any }

export type Options = {
	source: string?,
	tables: Tables,
	locale: string?,
}

export type Issue = {
	locale: string,
	key: string,
	kind: "missing" | "extra" | "placeholders" | "pluralForms" | "badEntry",
	detail: string?,
}

export type Loc = {
	source: string,
	locale: string,
	tables: Tables,
	t: (self: Loc, key: string, args: Args?) -> string,
	plural: (self: Loc, key: string, count: number, args: Args?) -> string,
	has: (self: Loc, key: string) -> boolean,
	setLocale: (self: Loc, locale: string) -> string,
	getLocale: (self: Loc) -> string,
	number: (self: Loc, n: number) -> string,
	compact: (self: Loc, n: number) -> string,
	grouped: (self: Loc, n: number) -> string,
	onLocaleChanged: (self: Loc, fn: (locale: string) -> ()) -> () -> (),
	_warned: { [string]: boolean },
	_listeners: { (string) -> () },
}

local Loc = {}

--- Locales both games ship (brief §3.1).
Loc.SUPPORTED = { "en", "pt-br", "es" }

--- The decimal and thousands separators per locale family.
local SEPARATORS: { [string]: { decimal: string, thousands: string } } = {
	en = { decimal = ".", thousands = "," },
	pt = { decimal = ",", thousands = "." },
	es = { decimal = ",", thousands = "." },
}

local function family(locale: string): string
	return (string.match(locale, "^(%a+)") or locale)
end

--[[
	Maps a Roblox LocaleId ("en-us", "pt-br", "es-mx", "es-es") to one of `available`
	(default Loc.SUPPORTED): exact match first, then the language family, then the first entry.
]]
function Loc.normalize(localeId: string?, available: { string }?): string
	local list: { string } = available or Loc.SUPPORTED
	local id = string.lower(localeId or "")
	id = (string.gsub(id, "_", "-"))
	for _, candidate in list do
		if candidate == id then
			return candidate
		end
	end
	local fam = family(id)
	for _, candidate in list do
		if family(candidate) == fam then
			return candidate
		end
	end
	return list[1]
end

--[[
	CLDR cardinal "one" for the shipped languages, integers only (counts in UI are whole):
	en and es: exactly 1; pt (Brazil): 0 and 1.
]]
function Loc.pluralCategory(locale: string, count: number): string
	local n = math.abs(count)
	local fam = family(locale)
	if fam == "pt" then
		if n == 0 or n == 1 then
			return "one"
		end
		return "other"
	end
	if n == 1 then
		return "one"
	end
	return "other"
end

local function separatorsFor(locale: string)
	return SEPARATORS[family(locale)] or SEPARATORS.en
end

--- Swaps UI.Format's "1,234.5" separators for the locale's.
local function localize(text: string, locale: string): string
	local seps = separatorsFor(locale)
	if seps.decimal == "." then
		return text
	end
	-- Two-step swap through a sentinel so "," and "." don't overwrite each other.
	local swapped = string.gsub(text, ",", "\0")
	swapped = string.gsub(swapped, "%.", seps.decimal)
	swapped = string.gsub(swapped, "%z", seps.thousands)
	return swapped
end

function Loc.compact(n: number, locale: string): string
	return localize(Format.compact(n), locale)
end

function Loc.grouped(n: number, locale: string): string
	return localize(Format.grouped(n), locale)
end

--- Whole numbers grouped, fractions with one decimal (2.5 -> "2.5" / "2,5").
function Loc.number(n: number, locale: string): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "0"
	end
	if n == math.floor(n) then
		return Loc.grouped(n, locale)
	end
	local text = string.format("%.1f", n)
	local whole, frac = string.match(text, "^(-?%d+)%.(%d)$")
	if whole and frac then
		local grouped = Format.grouped(tonumber(whole) :: number)
		if string.sub(whole, 1, 1) == "-" and string.sub(grouped, 1, 1) ~= "-" then
			grouped = "-" .. grouped
		end
		if frac == "0" then
			return localize(grouped, locale)
		end
		return localize(grouped .. "." .. frac, locale)
	end
	return text
end

local function formatValue(value: any, spec: string?, locale: string): string
	if type(value) == "number" then
		if spec == "compact" then
			return Loc.compact(value, locale)
		elseif spec == "grouped" then
			return Loc.grouped(value, locale)
		elseif spec == "raw" then
			return tostring(value)
		end
		return Loc.number(value, locale)
	end
	return tostring(value)
end

--- Fills `{name}` / `{name:spec}` from args. Unknown placeholders stay as written.
function Loc.interpolate(text: string, args: Args?, locale: string?): string
	if not args then
		return text
	end
	local loc = locale or "en"
	local function replace(name: string, spec: string): string?
		local value = args[name]
		if value == nil then
			return nil
		end
		return formatValue(value, if spec == "" then nil else spec, loc)
	end
	-- gsub's typed signature only knows one-capture callbacks; two captures are fine at runtime.
	local out = string.gsub(text, "{([%w_]+):?([%w_]*)}", replace :: any)
	return out
end

--- The sorted, de-duplicated placeholder names in a string.
function Loc.placeholders(text: string): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for name in string.gmatch(text, "{([%w_]+):?[%w_]*}") do
		if not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

local function entryPlaceholders(entry: Entry): { string }
	if type(entry) == "string" then
		return Loc.placeholders(entry)
	end
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, form in entry do
		for _, name in Loc.placeholders(form) do
			if not seen[name] then
				seen[name] = true
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

local function requiredForms(locale: string): { string }
	-- Every shipped language has "one" and "other".
	local _ = locale
	return { "one", "other" }
end

--[[
	Checks every locale against the source: keys missing or extra, placeholders that differ,
	plural entries without the locale's forms, entries that aren't strings or form tables.
	Returns a list of issues (empty when everything lines up).
]]
function Loc.validate(tables: Tables, source: string?): { Issue }
	local src = source or "en"
	local issues: { Issue } = {}
	local base = tables[src]
	if not base then
		table.insert(issues, { locale = src, key = "*", kind = "missing", detail = "no source table" })
		return issues
	end
	local locales: { string } = {}
	for locale in tables do
		table.insert(locales, locale)
	end
	table.sort(locales)

	local function checkEntry(locale: string, key: string, entry: any): boolean
		if type(entry) == "string" then
			return true
		end
		if type(entry) ~= "table" then
			table.insert(issues, { locale = locale, key = key, kind = "badEntry", detail = type(entry) })
			return false
		end
		for form, text in entry do
			if type(form) ~= "string" or type(text) ~= "string" then
				table.insert(
					issues,
					{ locale = locale, key = key, kind = "badEntry", detail = "plural forms must be strings" }
				)
				return false
			end
		end
		for _, form in requiredForms(locale) do
			if entry[form] == nil then
				table.insert(
					issues,
					{ locale = locale, key = key, kind = "pluralForms", detail = "missing '" .. form .. "'" }
				)
			end
		end
		return true
	end

	local keys: { string } = {}
	for key in base do
		table.insert(keys, key)
	end
	table.sort(keys)

	for _, locale in locales do
		local t = tables[locale]
		for _, key in keys do
			local entry = t[key]
			if entry == nil then
				if locale ~= src then
					table.insert(issues, { locale = locale, key = key, kind = "missing" })
				end
			elseif checkEntry(locale, key, entry) and locale ~= src then
				local baseEntry = base[key]
				if type(baseEntry) ~= type(entry) then
					table.insert(issues, {
						locale = locale,
						key = key,
						kind = "pluralForms",
						detail = "source is " .. (if type(baseEntry) == "table" then "plural" else "plain"),
					})
				else
					local a = table.concat(entryPlaceholders(baseEntry), ",")
					local b = table.concat(entryPlaceholders(entry), ",")
					if a ~= b then
						table.insert(issues, {
							locale = locale,
							key = key,
							kind = "placeholders",
							detail = "{" .. a .. "} vs {" .. b .. "}",
						})
					end
				end
			end
		end
		if locale ~= src then
			local extra: { string } = {}
			for key in t do
				if base[key] == nil then
					table.insert(extra, key)
				end
			end
			table.sort(extra)
			for _, key in extra do
				table.insert(issues, { locale = locale, key = key, kind = "extra" })
			end
		end
	end
	return issues
end

--[[
	A CSV in Roblox's localization table import format (Key, Source, Context, Example, then one
	column per locale), for uploading the tables to the experience's cloud localization table.
	Plural entries export their "other" form.
]]
function Loc.toCsv(tables: Tables, source: string?): string
	local src = source or "en"
	local base: Table = tables[src] or {}
	local locales: { string } = {}
	for locale in tables do
		table.insert(locales, locale)
	end
	table.sort(locales)
	local function cell(s: string): string
		return '"' .. string.gsub(s, '"', '""') .. '"'
	end
	local function plain(entry: Entry?): string
		if entry == nil then
			return ""
		end
		if type(entry) == "string" then
			return entry
		end
		return entry.other or ""
	end
	local header = { "Key", "Source", "Context", "Example" }
	for _, locale in locales do
		table.insert(header, locale)
	end
	local lines = { table.concat(header, ",") }
	local keys: { string } = {}
	for key in base do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		local row = { cell(key), cell(plain(base[key])), '""', '""' }
		for _, locale in locales do
			table.insert(row, cell(plain(tables[locale][key])))
		end
		table.insert(lines, table.concat(row, ","))
	end
	return table.concat(lines, "\n") .. "\n"
end

local Instance = {}
Instance.__index = Instance

function Loc.new(options: Options): Loc
	local source = options.source or "en"
	assert(options.tables[source], "Loc.new: no table for source locale '" .. source .. "'")
	local self = setmetatable({
		source = source,
		locale = source,
		tables = options.tables,
		_warned = {},
		_listeners = {},
	}, Instance) :: any
	if options.locale then
		self:setLocale(options.locale)
	end
	return self :: Loc
end

local function lookup(self: Loc, key: string): Entry?
	local t = self.tables[self.locale]
	local entry = t and t[key]
	if entry ~= nil then
		return entry
	end
	return self.tables[self.source][key]
end

local function warnOnce(self: Loc, key: string, message: string)
	if self._warned[key] then
		return
	end
	self._warned[key] = true
	Log.warn("Loc", message)
end

function Instance.t(self: Loc, key: string, args: Args?): string
	local entry = lookup(self, key)
	if entry == nil then
		warnOnce(self, key, "missing string '" .. key .. "'")
		return key
	end
	if type(entry) == "table" then
		local count = args and args.count
		if type(count) == "number" then
			return self:plural(key, count, args)
		end
		return Loc.interpolate(entry.other or key, args, self.locale)
	end
	return Loc.interpolate(entry, args, self.locale)
end

--- A plural entry `{ one = ..., other = ... }`; `{count}` is filled from `count`.
function Instance.plural(self: Loc, key: string, count: number, args: Args?): string
	local entry = lookup(self, key)
	if entry == nil then
		warnOnce(self, key, "missing string '" .. key .. "'")
		return key
	end
	local merged: Args = { count = count }
	if args then
		for k, v in args do
			if k ~= "count" then
				merged[k] = v
			end
		end
	end
	if type(entry) == "string" then
		return Loc.interpolate(entry, merged, self.locale)
	end
	local category = Loc.pluralCategory(self.locale, count)
	local text = entry[category] or entry.other
	if text == nil then
		warnOnce(self, key .. "#" .. category, "string '" .. key .. "' has no '" .. category .. "' form")
		return key
	end
	return Loc.interpolate(text, merged, self.locale)
end

function Instance.has(self: Loc, key: string): boolean
	return lookup(self, key) ~= nil
end

--- Picks the closest available locale (see Loc.normalize) and returns it.
function Instance.setLocale(self: Loc, locale: string): string
	local available: { string } = {}
	for id in self.tables do
		table.insert(available, id)
	end
	table.sort(available, function(a, b)
		-- Source first so it is the fallback when nothing matches.
		if a == self.source then
			return true
		elseif b == self.source then
			return false
		end
		return a < b
	end)
	local chosen = Loc.normalize(locale, available)
	if chosen ~= self.locale then
		self.locale = chosen
		for _, fn in table.clone(self._listeners) do
			fn(chosen)
		end
	end
	return chosen
end

function Instance.getLocale(self: Loc): string
	return self.locale
end

function Instance.number(self: Loc, n: number): string
	return Loc.number(n, self.locale)
end

function Instance.compact(self: Loc, n: number): string
	return Loc.compact(n, self.locale)
end

function Instance.grouped(self: Loc, n: number): string
	return Loc.grouped(n, self.locale)
end

--- Calls `fn(locale)` after each change; returns a function that unsubscribes.
function Instance.onLocaleChanged(self: Loc, fn: (string) -> ()): () -> ()
	table.insert(self._listeners, fn)
	return function()
		local i = table.find(self._listeners, fn)
		if i then
			table.remove(self._listeners, i)
		end
	end
end

return Loc
