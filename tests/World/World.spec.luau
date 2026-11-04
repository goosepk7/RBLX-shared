--!strict
local T = require("@shared/Test")
local World = require("@shared/World")
local Model = require("@tools/lib/model")
local expect = T.expect

type Spec = World.Spec

local function sample(): Spec
	return World.group("Hub", {
		{ name = "Floor", size = { 40, 2, 40 }, position = { 0, -1, 0 }, color = "#3DD68C", material = "Grass" },
		{
			name = "Plinth",
			shape = "Cylinder",
			size = { 2, 20, 20 },
			position = { 10, 1, 0 },
			rotation = { 0, 0, 90 },
			tags = { "Plinth", "Showroom" },
			attributes = { slot = 1, label = "A", gold = false },
		},
		{ className = "SpawnLocation", name = "Spawn", size = { 6, 1, 6 }, properties = { Duration = 0 } },
		World.group("Props", {
			{ className = "WedgePart", name = "Ramp", size = { 4, 2, 6 }, position = { 0, 1, 10 } },
		}, { className = "Folder" }),
	}, { primary = "Floor" })
end

T.describe("World.validate", function()
	T.it("accepts a well-formed tree", function()
		expect(World.validate(sample())).toEqual({})
	end)

	T.it("names every bad node by path", function()
		local bad = World.group("Hub", {
			{ name = "A", size = { 0, 1, 1 } },
			{ name = "B", size = { 1, 1, 1 }, color = "teal", material = "Lava" },
			{ name = "B", size = { 1, 1, 1 }, position = { 0 / 0, 0, 0 } },
			{ className = "Folder", name = "F", size = { 1, 1, 1 } },
			{ className = "Script", name = "S" },
			{ className = "WedgePart", name = "W", size = { 1, 1, 1 }, shape = "Ball" },
		}, { primary = "Missing" })
		local problems = World.validate(bad)
		local text = table.concat(problems, "\n")
		expect(text).toMatch("Hub%.A: size must be positive")
		expect(text).toMatch("Hub%.B: color must be #RRGGBB")
		expect(text).toMatch("Hub%.B: unknown material Lava")
		expect(text).toMatch("Hub: duplicate child name B")
		expect(text).toMatch("Hub%.B: position must be")
		expect(text).toMatch("Hub%.F: size is only for parts")
		expect(text).toMatch("Hub%.S: unknown className Script")
		expect(text).toMatch("Hub%.W: shape is only for Part")
		expect(text).toMatch("Hub: primary Missing is not a direct child part")
	end)

	T.it("rejects attribute values a DataModel can't hold", function()
		local problems = World.validate({ name = "P", size = { 1, 1, 1 }, attributes = { v = math.huge } })
		expect(problems[1]).toMatch("attributes%.v")
	end)
end)

T.describe("World.stats", function()
	T.it("counts parts, instances and bounds", function()
		local stats = World.stats(sample())
		expect(stats.parts).toBe(4)
		expect(stats.instances).toBe(6)
		expect(stats.min).toEqual({ -20, -2, -20 })
		expect(stats.max).toEqual({ 20, 2, 20 }) -- the cylinder stands upright: 2 studs tall
		expect(World.countParts(sample())).toBe(4)
	end)

	T.it("finds tagged nodes", function()
		local found = World.findTagged(sample(), "Plinth")
		expect(#found).toBe(1)
		expect(found[1].name).toBe("Plinth")
	end)
end)

T.describe("World composition", function()
	T.it("translate moves parts and leaves the input alone", function()
		local input = sample()
		local moved = World.translate(input, { 5, 0, -5 })
		expect((moved.children :: { Spec })[1].position).toEqual({ 5, -1, -5 })
		expect((input.children :: { Spec })[1].position).toEqual({ 0, -1, 0 })
	end)

	T.it("rotateY turns positions and orientation like Roblox", function()
		local spec: Spec = { name = "P", size = { 1, 1, 1 }, position = { 0, 0, -10 } }
		local turned = World.rotateY(spec, 90)
		-- Facing -Z rotated +90 deg about Y faces -X.
		expect(turned.position).toEqual({ -10, 0, 0 })
		expect(turned.rotation).toEqual({ 0, 90, 0 })
		local around = World.rotateY(spec, 180, { 0, 0, -5 })
		expect(around.position).toEqual({ 0, 0, 0 })
	end)
end)

T.describe("World.instantiate (lune roblox)", function()
	T.it("builds instances with properties, attributes, tags and PrimaryPart", function()
		local inst: any = World.instantiate(sample(), Model.env())
		expect(inst.ClassName).toBe("Model")
		expect(inst.PrimaryPart.Name).toBe("Floor")
		local plinth = inst:FindFirstChild("Plinth")
		expect(plinth:GetAttribute("slot")).toBe(1)
		expect(plinth:HasTag("Showroom")).toBe(true)
		expect(plinth.Anchored).toBe(true)
		expect(plinth.CFrame.Position.X).toBeNear(10)
		expect(inst:FindFirstChild("Spawn").Duration).toBe(0)
		expect(inst:FindFirstChild("Props").ClassName).toBe("Folder")
		expect(inst:FindFirstChild("Props"):FindFirstChild("Ramp").ClassName).toBe("WedgePart")
	end)

	T.it("refuses an invalid spec with every problem listed", function()
		expect(function()
			World.instantiate({ name = "", size = { -1, 1, 1 } }, Model.env())
		end).toThrow("size must be positive")
	end)

	T.it("renders byte-identical .rbxmx for the same spec", function()
		local a = Model.render(sample())
		local b = Model.render(World.copy(sample()))
		expect(a == b).toBe(true)
		expect(a).toMatch("<roblox")
		expect(a).toMatch("Plinth")
	end)

	T.it("write --check passes when current and fails on drift", function()
		local fs = require("@lune/fs")
		local path = "tests/World/.out/Hub.rbxmx"
		Model.write(sample(), path)
		expect(Model.write(sample(), path, { check = true })).toBe(true)
		local changed = sample();
		((changed.children :: { Spec })[1]).color = "#FF5A6E"
		expect(Model.write(changed, path, { check = true })).toBe(false)
		fs.removeDir("tests/World/.out")
	end)
end)
