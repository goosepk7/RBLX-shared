--!strict
--[[
	Every kit component has a gallery story, and every variant it declares
	appears in that story (§5.3: "a story ... that renders every variant").
]]
local Stories = require("@shared/UI/Gallery/Stories")
local UI = require("@shared/UI")
local T = require("@shared/Test")
local expect = T.expect

T.describe("UI.Gallery stories", function()
	T.it("cover every kit component", function()
		local covered: { [string]: boolean } = {}
		for _, story in Stories do
			covered[story.component] = true
		end
		for name in UI.Kit :: { [string]: any } do
			if not covered[name] then
				error(`Kit.{name} has no story in Gallery/Stories.luau`)
			end
		end
	end)

	T.it("cover every declared variant", function()
		for _, story in Stories do
			local component = (UI.Kit :: any)[story.component]
			expect(component).toBeTruthy()
			local names: { [string]: boolean } = {}
			for _, v in story.variants do
				names[v.name] = true
			end
			for _, variant in component.Variants do
				if not names[variant] then
					error(`{story.component} story is missing variant "{variant}"`)
				end
			end
		end
	end)

	T.it("story names are unique within a component", function()
		for _, story in Stories do
			local seen: { [string]: boolean } = {}
			for _, v in story.variants do
				expect(seen[v.name]).toBeNil()
				seen[v.name] = true
			end
		end
	end)

	T.it("every component exposes a constructor", function()
		for name, component in UI.Kit :: { [string]: any } do
			local ctor = component.new or component.show or component.spawn or component.burst or component.lane
			if type(ctor) ~= "function" then
				error(`Kit.{name} has no constructor`)
			end
			expect(type(component.Variants)).toBe("table")
		end
	end)
end)
