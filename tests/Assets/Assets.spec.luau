--!strict
local T = require("@shared/Test")
local Assets = require("@shared/Assets")
local expect = T.expect

T.describe("Assets", function()
	local warnings: { string } = {}

	T.beforeEach(function()
		Assets.reset()
		Assets.setStrict(false)
		table.clear(warnings)
		Assets.setWarnHandler(function(message)
			table.insert(warnings, message)
		end)
		Assets.register({
			icon_wins = { kind = "image", status = "uploaded", assetId = 123 },
			icon_wins_64 = { kind = "image", status = "pending", assetId = nil },
			sfx_win = { kind = "audio", status = "pending", assetId = nil },
		}, "game")
	end)

	T.afterEach(function()
		Assets.reset()
		Assets.setStrict(false)
	end)

	T.it("returns content ids for uploaded assets and empty strings while pending", function()
		expect(Assets.get("icon_wins")).toBe("rbxassetid://123")
		expect(Assets.get("icon_wins_64")).toBe("")
		expect(Assets.isPlaceholder("icon_wins")).toBe(false)
		expect(Assets.isPlaceholder("sfx_win")).toBe(true)
	end)

	T.it("ref() matches the shared AssetRef shape", function()
		expect(Assets.ref("icon_wins")).toEqual({
			name = "icon_wins",
			kind = "image",
			status = "uploaded",
			assetId = 123,
			uri = "rbxassetid://123",
			placeholder = false,
		})
	end)

	T.it("resolves size variants only when registered", function()
		expect(Assets.variant("icon_wins", 64)).toBe("icon_wins_64")
		expect(Assets.variant("icon_wins", 128)).toBe("icon_wins")
		expect(Assets.variant("icon_wins")).toBe("icon_wins")
	end)

	T.it("warns once for unknown names, or throws in strict mode", function()
		expect(Assets.get("icon_nope")).toBe("")
		Assets.get("icon_nope")
		expect(#warnings).toBe(1)
		expect(warnings[1]).toContain("icon_nope")
		Assets.setStrict(true)
		expect(function()
			Assets.get("icon_nope")
		end).toThrow("unknown asset")
	end)

	T.it("rejects duplicate names across owners and malformed entries", function()
		expect(function()
			Assets.register({ icon_wins = { kind = "image", status = "pending", assetId = nil } }, "other-game")
		end).toThrow("defined by both")
		expect(function()
			Assets.register({ bad = { kind = "texture", status = "pending", assetId = nil } }, "x")
		end).toThrow("unknown kind")
		expect(function()
			Assets.register({ bad = { kind = "image", status = "uploaded", assetId = nil } }, "x")
		end).toThrow("no assetId")
	end)

	T.it("lists all and pending assets sorted by name", function()
		local names = {}
		for _, ref in Assets.pending() do
			table.insert(names, ref.name)
		end
		expect(names).toEqual({ "icon_wins_64", "sfx_win" })
		expect(#Assets.list()).toBe(3)
	end)

	T.it("placeholder colors are stable per name and from the palette", function()
		local a = Assets.placeholderColor("icon_wins")
		expect(Assets.placeholderColor("icon_wins")).toEqual(a)
		expect(#a).toBe(3)
		local distinct: { [string]: boolean } = {}
		for _, name in { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" } do
			local c = Assets.placeholderColor(name)
			distinct[table.concat(c, ",")] = true
		end
		local count = 0
		for _ in distinct do
			count += 1
		end
		expect(count).toBeGreaterThan(3)
	end)
end)
