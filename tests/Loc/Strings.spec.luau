--!strict
local Format = require("@shared/UI/Format")
local Loc = require("@shared/Loc")
local Strings = require("@shared/Strings")
local T = require("@shared/Test")
local expect = T.expect

T.describe("Shared.Strings", function()
	T.it("is complete in every shipped locale, with matching placeholders", function()
		local problems: { string } = {}
		for _, issue in Loc.validate(Strings) do
			table.insert(problems, `{issue.locale} {issue.key}: {issue.kind} {issue.detail or ""}`)
		end
		if #problems > 0 then
			error("Shared.Strings issues:\n" .. table.concat(problems, "\n"))
		end
		for _, locale in Loc.SUPPORTED do
			expect(Strings[locale]).toBeTruthy()
		end
	end)

	T.it("keeps every key under its area prefix", function()
		for key in Strings.en do
			expect(string.find(key, "^%l%w*%.") ~= nil).toBe(true)
		end
	end)
end)

T.describe("Loc.merge", function()
	T.it("merges per locale", function()
		local merged = Loc.merge({ en = { a = "A" }, es = { a = "Á" } }, { en = { b = "B" } })
		expect(merged.en).toEqual({ a = "A", b = "B" })
		expect(merged.es).toEqual({ a = "Á" })
	end)

	T.it("refuses a key defined twice for the same locale", function()
		expect(function()
			Loc.merge({ en = { a = "A" } }, { en = { a = "Other" } })
		end).toThrow('"a" (en) is defined in table 1 and table 2')
	end)
end)

T.describe("Loc:bindKit", function()
	T.it("makes the kit's number helpers follow the locale", function()
		local loc = Loc.new({ tables = { en = {}, ["pt-br"] = {} } })
		local unbind = loc:bindKit()
		expect(Format.showCompact(1234)).toBe("1.2K")
		loc:setLocale("pt-br")
		expect(Format.showCompact(1234)).toBe("1,2K")
		expect(Format.showGrouped(1234567)).toBe("1.234.567")
		expect(Format.showDelta(2500)).toBe("+2,5K")
		unbind()
		expect(Format.showCompact(1234)).toBe("1.2K")
	end)
end)
