--!strict
local T = require("@shared/Test")
local Lint = require("@tools/lib/lint")
local expect = T.expect

local config = { netPaths = { "src/Net" }, manifests = {} }

local function rules(path: string, source: string, assets: { [string]: boolean }?): { string }
	local out = {}
	for _, f in Lint.checkSource(path, source, config, assets) do
		table.insert(out, string.format("%d:%s", f.line, f.rule))
	end
	return out
end

T.describe("tools/lib/lint", function()
	T.it("flags WaitForChild without a timeout only", function()
		expect(rules("src/X.luau", 'local a = folder:WaitForChild("A")\nlocal b = folder:WaitForChild("B", 10)')).toEqual({
			"1:waitforchild-timeout",
		})
		expect(rules("src/X.luau", "local c = f:WaitForChild(name(1, 2))")).toEqual({ "1:waitforchild-timeout" })
	end)

	T.it("flags remotes outside Net but not inside it", function()
		local src = 'local r = Instance.new("RemoteEvent")\nr:FireServer(1)\nr.OnServerEvent:Connect(f)'
		expect(rules("src/Game/Thing.luau", src)).toEqual({
			"1:remote-outside-net",
			"2:remote-outside-net",
			"3:remote-outside-net",
		})
		expect(rules("src/Net/Remote.luau", src)).toEqual({})
	end)

	T.it("flags hardcoded asset ids and unknown asset names", function()
		local src =
			'img.Image = "rbxassetid://12345"\nlocal a = Assets.get("icon_wins")\nlocal b = Assets.image("icon_nope", { size = 64 })'
		expect(rules("src/X.luau", src, { icon_wins = true })).toEqual({ "1:hardcoded-asset-id", "3:unknown-asset" })
		-- without manifests the asset-name rule is skipped
		expect(rules("src/X.luau", src, nil)).toEqual({ "1:hardcoded-asset-id" })
	end)

	T.it("flags discarded pcall results", function()
		expect(rules("src/X.luau", "pcall(save)\nlocal ok = pcall(save)\ntask.spawn(pcall, save)")).toEqual({
			"1:discarded-pcall",
			"3:discarded-pcall",
		})
	end)

	T.it("ignores comments, block comments and lint-ignore markers", function()
		local src = table.concat({
			'-- folder:WaitForChild("A")',
			"--[[",
			'  Assets.get("icon_nope") and r:FireServer()',
			"]]",
			'local s = "-- not a comment" folder:WaitForChild("B")',
			'folder:WaitForChild("C") -- lint-ignore: waitforchild-timeout',
			"-- lint-ignore: discarded-pcall",
			"pcall(f)",
		}, "\n")
		expect(rules("src/X.luau", src, {})).toEqual({ "5:waitforchild-timeout" })
	end)
end)
