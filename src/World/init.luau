--!strict
--[[
	World: static geometry described as plain data, built into Instances (brief §8).

	Games describe hubs, worlds and stage chunks as `Spec` trees (numbers, strings and booleans
	only), so layouts are reproducible, diffable and testable under lune. The same tree builds:
	  * at runtime in Roblox: `World.instantiate(spec)`,
	  * as a deterministic .rbxmx from lune: `tools/lib/model.luau` (`Model.write`), which a game's
	    generator tool calls and CI runs with `--check`.

	Nothing here touches Roblox globals at require time. `instantiate` takes an `Env` (the
	constructors to use); the default reads the Roblox globals when it is called.
]]

export type Vec3 = { number } -- { x, y, z }

export type Shape = "Block" | "Ball" | "Cylinder" | "Wedge" | "CornerWedge"

export type AttributeValue = string | number | boolean

export type Spec = {
	-- Default "Part". See World.CLASSES.
	className: string?,
	name: string,
	-- BaseParts: size in studs, center position, orientation in degrees (Roblox's
	-- Orientation order: Y, then X, then Z).
	size: Vec3?,
	position: Vec3?,
	rotation: Vec3?,
	shape: Shape?, -- Part only
	color: string?, -- "#RRGGBB"
	material: string?, -- Enum.Material name
	transparency: number?,
	reflectance: number?,
	anchored: boolean?, -- default true
	canCollide: boolean?,
	canTouch: boolean?,
	canQuery: boolean?,
	castShadow: boolean?,
	-- Any node.
	attributes: { [string]: any }?, -- string, boolean or finite number (checked by validate)
	tags: { string }?,
	-- Escape hatch for other simple properties (SpawnLocation.Duration, Seat.Disabled, ...).
	properties: { [string]: any }?,
	-- Model only: name of a direct child BasePart to use as PrimaryPart.
	primary: string?,
	children: { Spec }?,
}

export type Env = {
	Instance: any,
	Vector3: any,
	CFrame: any,
	Color3: any,
	Enum: any,
}

export type Stats = {
	parts: number,
	instances: number,
	min: Vec3?,
	max: Vec3?,
}

local World = {}

-- Classes a spec may use. `true` marks BaseParts.
World.CLASSES = {
	Part = true,
	WedgePart = true,
	CornerWedgePart = true,
	TrussPart = true,
	SpawnLocation = true,
	Seat = true,
	Model = false,
	Folder = false,
} :: { [string]: boolean }

World.SHAPES = { Block = true, Ball = true, Cylinder = true, Wedge = true, CornerWedge = true } :: { [string]: boolean }

-- Enum.Material names accepted by `validate` (the Roblox built-in material list).
World.MATERIALS = {
	Plastic = true,
	SmoothPlastic = true,
	Neon = true,
	Wood = true,
	WoodPlanks = true,
	Marble = true,
	Slate = true,
	Concrete = true,
	Granite = true,
	Brick = true,
	Pebble = true,
	Cobblestone = true,
	Rock = true,
	Sandstone = true,
	Basalt = true,
	CrackedLava = true,
	Limestone = true,
	Pavement = true,
	CorrodedMetal = true,
	DiamondPlate = true,
	Foil = true,
	Metal = true,
	Grass = true,
	LeafyGrass = true,
	Sand = true,
	Fabric = true,
	Snow = true,
	Mud = true,
	Ground = true,
	Asphalt = true,
	Salt = true,
	Ice = true,
	Glacier = true,
	Glass = true,
	ForceField = true,
	Cardboard = true,
	Carpet = true,
	CeramicTiles = true,
	ClayRoofTiles = true,
	RoofShingles = true,
	Leather = true,
	Plaster = true,
	Rubber = true,
} :: { [string]: boolean }

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isVec3(v: any): boolean
	return type(v) == "table" and #v == 3 and isFinite(v[1]) and isFinite(v[2]) and isFinite(v[3])
end

local function isPartClass(className: string): boolean
	return World.CLASSES[className] == true
end

local function classOf(spec: Spec): string
	return spec.className or "Part"
end

--- Every problem in a spec tree, as "Path.To.Node: reason". Empty when the tree is buildable.
--- Sibling names must be unique so instance paths (and .rbxmx diffs) are unambiguous.
function World.validate(spec: Spec): { string }
	local errors: { string } = {}
	local function fail(path: string, reason: string)
		table.insert(errors, path .. ": " .. reason)
	end

	local function visit(node: Spec, parentPath: string?)
		local name = node.name
		local path = if parentPath then parentPath .. "." .. tostring(name) else tostring(name)
		if type(name) ~= "string" or name == "" then
			fail(path, "name must be a non-empty string")
		end
		local className = classOf(node)
		if World.CLASSES[className] == nil then
			fail(path, "unknown className " .. tostring(className))
			return
		end
		local part = isPartClass(className)
		if part then
			if not isVec3(node.size) then
				fail(path, "size must be { x, y, z } of finite numbers")
			else
				local size = node.size :: Vec3
				if size[1] <= 0 or size[2] <= 0 or size[3] <= 0 then
					fail(path, "size must be positive")
				end
			end
			if node.position ~= nil and not isVec3(node.position) then
				fail(path, "position must be { x, y, z } of finite numbers")
			end
			if node.rotation ~= nil and not isVec3(node.rotation) then
				fail(path, "rotation must be { rx, ry, rz } degrees")
			end
			if
				node.color ~= nil and (type(node.color) ~= "string" or not string.match(node.color, "^#%x%x%x%x%x%x$"))
			then
				fail(path, "color must be #RRGGBB")
			end
			if node.material ~= nil and not World.MATERIALS[node.material] then
				fail(path, "unknown material " .. tostring(node.material))
			end
			if node.shape ~= nil then
				if className ~= "Part" then
					fail(path, "shape is only for Part")
				elseif not World.SHAPES[node.shape] then
					fail(path, "unknown shape " .. tostring(node.shape))
				end
			end
			for _, field in { "transparency", "reflectance" } do
				local v = (node :: any)[field]
				if v ~= nil and (not isFinite(v) or v < 0 or v > 1) then
					fail(path, field .. " must be in [0, 1]")
				end
			end
		else
			for _, field in { "size", "position", "rotation", "shape", "color", "material" } do
				if (node :: any)[field] ~= nil then
					fail(path, field .. " is only for parts")
				end
			end
		end
		if node.primary ~= nil and className ~= "Model" then
			fail(path, "primary is only for Model")
		end
		for _, mapField in { "attributes", "properties" } do
			local map = (node :: any)[mapField]
			if map ~= nil then
				if type(map) ~= "table" then
					fail(path, mapField .. " must be a table")
				else
					for k, v in map do
						local t = type(v)
						if type(k) ~= "string" or (t ~= "string" and t ~= "boolean" and not isFinite(v)) then
							fail(path, mapField .. "." .. tostring(k) .. " must be a string, boolean or finite number")
						end
					end
				end
			end
		end
		if node.tags ~= nil then
			for _, tag in node.tags do
				if type(tag) ~= "string" or tag == "" then
					fail(path, "tags must be non-empty strings")
				end
			end
		end
		local seen: { [string]: boolean } = {}
		local primaryFound = node.primary == nil
		for _, child in node.children or {} :: { Spec } do
			if type(child.name) == "string" then
				if seen[child.name] then
					fail(path, "duplicate child name " .. child.name)
				end
				seen[child.name] = true
				if child.name == node.primary and isPartClass(classOf(child)) then
					primaryFound = true
				end
			end
			visit(child, path)
		end
		if not primaryFound then
			fail(path, "primary " .. tostring(node.primary) .. " is not a direct child part")
		end
	end

	visit(spec, nil)
	return errors
end

--- Half extents of a part's world-axis bounding box, rotation included.
function World.extents(node: Spec): Vec3
	local s = node.size or { 0, 0, 0 }
	local r = node.rotation or { 0, 0, 0 }
	local rx, ry, rz = math.rad(r[1]), math.rad(r[2]), math.rad(r[3])
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	-- R = Ry * Rx * Rz (Roblox Orientation order).
	local m = {
		{ cy * cz + sy * sx * sz, -cy * sz + sy * sx * cz, sy * cx },
		{ cx * sz, cx * cz, -sx },
		{ -sy * cz + cy * sx * sz, sy * sz + cy * sx * cz, cy * cx },
	}
	local out: Vec3 = {}
	for i = 1, 3 do
		local row = m[i]
		local v = math.abs(row[1]) * s[1] / 2 + math.abs(row[2]) * s[2] / 2 + math.abs(row[3]) * s[3] / 2
		out[i] = math.floor(v * 10000 + 0.5) / 10000
	end
	return out
end

--- Part count, instance count and the world-axis bounds of every part (rotation included).
--- For the §3.1 budgets and "fits on the island" tests.
function World.stats(spec: Spec): Stats
	local stats: Stats = { parts = 0, instances = 0, min = nil, max = nil }
	local function visit(node: Spec)
		stats.instances += 1
		if isPartClass(classOf(node)) then
			stats.parts += 1
			local p = node.position or { 0, 0, 0 }
			local half = World.extents(node)
			local lo = { p[1] - half[1], p[2] - half[2], p[3] - half[3] }
			local hi = { p[1] + half[1], p[2] + half[2], p[3] + half[3] }
			local min, max = stats.min, stats.max
			if min == nil or max == nil then
				stats.min, stats.max = lo, hi
			else
				for i = 1, 3 do
					min[i] = math.min(min[i], lo[i])
					max[i] = math.max(max[i], hi[i])
				end
			end
		end
		for _, child in node.children or {} :: { Spec } do
			visit(child)
		end
	end
	visit(spec)
	return stats
end

function World.countParts(spec: Spec): number
	return World.stats(spec).parts
end

--- Every node (depth first, parents first) with its dotted path.
function World.each(spec: Spec, fn: (node: Spec, path: string) -> ())
	local function visit(node: Spec, parentPath: string?)
		local path = if parentPath then parentPath .. "." .. node.name else node.name
		fn(node, path)
		for _, child in node.children or {} :: { Spec } do
			visit(child, path)
		end
	end
	visit(spec, nil)
end

--- Nodes carrying a tag, for tests ("there are 8 plinths").
function World.findTagged(spec: Spec, tag: string): { Spec }
	local found: { Spec } = {}
	World.each(spec, function(node)
		for _, t in node.tags or {} :: { string } do
			if t == tag then
				table.insert(found, node)
				return
			end
		end
	end)
	return found
end

-- Composition helpers. They return new trees and never change their input.

local function copySpec(spec: Spec): Spec
	local out: any = table.clone(spec)
	if spec.size then
		out.size = table.clone(spec.size)
	end
	if spec.position then
		out.position = table.clone(spec.position)
	end
	if spec.rotation then
		out.rotation = table.clone(spec.rotation)
	end
	if spec.children then
		local children: { Spec } = {}
		for i, child in spec.children do
			children[i] = copySpec(child)
		end
		out.children = children
	end
	return out :: Spec
end

World.copy = copySpec

--- A Model (or Folder with `className = "Folder"` in extra) holding children.
function World.group(name: string, children: { Spec }, extra: { [string]: any }?): Spec
	local spec: any = { className = "Model", name = name, children = children }
	for k, v in extra or {} :: { [string]: any } do
		spec[k] = v
	end
	return spec :: Spec
end

--- Moves every part in the tree by offset.
function World.translate(spec: Spec, offset: Vec3): Spec
	local out = copySpec(spec)
	local function visit(node: Spec)
		if isPartClass(classOf(node)) then
			local p = node.position or { 0, 0, 0 }
			node.position = { p[1] + offset[1], p[2] + offset[2], p[3] + offset[3] }
		end
		for _, child in node.children or {} :: { Spec } do
			visit(child)
		end
	end
	visit(out)
	return out
end

--- Rotates every part in the tree about the vertical axis through `pivot` (default origin).
--- Positive degrees turn the same way as Orientation's Y (counterclockwise seen from above),
--- so a prefab authored facing -Z ends up facing the rotated direction.
function World.rotateY(spec: Spec, degrees: number, pivot: Vec3?): Spec
	local out = copySpec(spec)
	local c = pivot or { 0, 0, 0 }
	local r = math.rad(degrees)
	local cos, sin = math.cos(r), math.sin(r)
	local function round(n: number): number
		-- Keep layouts stable: 1e-4 stud precision hides float noise from cos/sin.
		return math.floor(n * 10000 + 0.5) / 10000
	end
	local function visit(node: Spec)
		if isPartClass(classOf(node)) then
			local p = node.position or { 0, 0, 0 }
			local dx, dz = p[1] - c[1], p[3] - c[3]
			-- Roblox's Y rotation: x' = x cos + z sin, z' = -x sin + z cos.
			node.position = { round(c[1] + dx * cos + dz * sin), p[2], round(c[3] - dx * sin + dz * cos) }
			local rot = node.rotation or { 0, 0, 0 }
			node.rotation = { rot[1], round(rot[2] + degrees), rot[3] }
		end
		for _, child in node.children or {} :: { Spec } do
			visit(child)
		end
	end
	visit(out)
	return out
end

-- Building.

function World.robloxEnv(): Env
	-- Read when called, never at require time (the globals are nil under lune).
	return {
		Instance = Instance,
		Vector3 = Vector3,
		CFrame = CFrame,
		Color3 = Color3,
		Enum = Enum,
	}
end

local function applyPart(inst: any, node: Spec, env: Env)
	local size = node.size :: Vec3
	inst.Size = env.Vector3.new(size[1], size[2], size[3])
	local p = node.position or { 0, 0, 0 }
	local r = node.rotation or { 0, 0, 0 }
	inst.CFrame = env.CFrame.new(p[1], p[2], p[3])
		* env.CFrame.fromOrientation(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
	inst.Anchored = if node.anchored == nil then true else node.anchored
	if node.shape then
		inst.Shape = env.Enum.PartType[node.shape]
	end
	if node.color then
		inst.Color = env.Color3.fromHex(node.color)
	end
	if node.material then
		inst.Material = env.Enum.Material[node.material]
	end
	if node.transparency ~= nil then
		inst.Transparency = node.transparency
	end
	if node.reflectance ~= nil then
		inst.Reflectance = node.reflectance
	end
	if node.canCollide ~= nil then
		inst.CanCollide = node.canCollide
	end
	if node.canTouch ~= nil then
		inst.CanTouch = node.canTouch
	end
	if node.canQuery ~= nil then
		inst.CanQuery = node.canQuery
	end
	if node.castShadow ~= nil then
		inst.CastShadow = node.castShadow
	end
	-- Studs look dated; every face smooth (brief §8).
	inst.TopSurface = env.Enum.SurfaceType.Smooth
	inst.BottomSurface = env.Enum.SurfaceType.Smooth
end

--- Builds the tree. Errors (listing every problem) if `validate` finds any.
--- Attribute and property keys are applied in sorted order so output is stable.
function World.instantiate(spec: Spec, env: Env?): Instance
	local problems = World.validate(spec)
	if #problems > 0 then
		error("World.instantiate: invalid spec\n  " .. table.concat(problems, "\n  "), 2)
	end
	local e = env or World.robloxEnv()

	local function sortedKeys(map: { [string]: any }): { string }
		local keys: { string } = {}
		for k in map do
			table.insert(keys, k)
		end
		table.sort(keys)
		return keys
	end

	local function build(node: Spec): any
		local className = classOf(node)
		local inst = e.Instance.new(className)
		inst.Name = node.name
		if isPartClass(className) then
			applyPart(inst, node, e)
		end
		if node.properties then
			for _, k in sortedKeys(node.properties) do
				inst[k] = node.properties[k]
			end
		end
		if node.attributes then
			for _, k in sortedKeys(node.attributes) do
				inst:SetAttribute(k, node.attributes[k])
			end
		end
		if node.tags then
			local tags = table.clone(node.tags)
			table.sort(tags)
			for _, tag in tags do
				inst:AddTag(tag)
			end
		end
		for _, child in node.children or {} :: { Spec } do
			local childInst = build(child)
			childInst.Parent = inst
			if node.primary == child.name then
				inst.PrimaryPart = childInst
			end
		end
		return inst
	end

	return build(spec) :: Instance
end

return World
