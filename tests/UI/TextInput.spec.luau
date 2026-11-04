--!strict
local TextInput = require("@shared/UI/Kit/TextInput")
local T = require("@shared/Test")
local expect = T.expect

T.describe("UI.Kit.TextInput.clamp", function()
	T.it("keeps text within the limit unchanged", function()
		expect(TextInput.clamp("TALLER", 20)).toBe("TALLER")
		expect(TextInput.clamp("", 5)).toBe("")
	end)

	T.it("cuts at the limit in characters, not bytes", function()
		expect(TextInput.clamp("RELEASE", 3)).toBe("REL")
		expect(TextInput.clamp("ñandú", 4)).toBe("ñand")
		expect(TextInput.clamp("ação", 2)).toBe("aç")
	end)

	T.it("drops invalid UTF-8 from the first bad byte", function()
		expect(TextInput.clamp("ab\255cd", 10)).toBe("ab")
	end)
end)
