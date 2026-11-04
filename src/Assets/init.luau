--!strict
--[[
	Assets: manifest-backed asset lookup (brief §1.5). Code never hardcodes an asset id:

		Assets.get("icon_wins")                 --> "rbxassetid://123", or "" while pending
		Assets.image("icon_wins", { size = 64 }) --> ImageLabel, or a visible placeholder
		Assets.sound("sfx_win")                  --> Sound (silent while pending, warns once)

	Ids come from generated AssetIds tables (tools/gen_asset_ids.luau writes one per repo from
	assets/manifest.json). RBLXShared's own table is registered automatically; each game
	registers its table once at startup:

		Assets.register(require(ReplicatedStorage.Stilts.AssetIds), "stilts")

	Until an asset is uploaded, image() returns a solid-color card showing the asset name, so a
	missing upload is obvious on screen instead of silently blank. Unknown names warn once (or
	error in strict mode, which tests and the lint use).
]]

local Color = require("./UI/Color")
local SharedIds = require("@self/AssetIds")
local Tokens = require("./UI/Tokens")

export type Kind = "image" | "audio" | "animation" | "mesh" | "video"
export type Status = "pending" | "uploaded"

-- Structurally identical to Types.AssetRef.
export type AssetRef = {
	name: string,
	kind: Kind,
	status: Status,
	assetId: number?,
	uri: string,
	placeholder: boolean,
}

export type IdEntry = { kind: string, status: string, assetId: number? }
export type IdTable = { [string]: IdEntry }

export type ImageOptions = {
	-- Pixel size variant: 64 resolves "<name>_64" when registered.
	size: number?,
	-- Properties applied to the returned instance (Size, Position, AnchorPoint, ...).
	props: { [string]: any }?,
}

type Registered = { kind: string, status: string, assetId: number?, owner: string }

local Assets = {}

local registry: { [string]: Registered } = {}
local warned: { [string]: boolean } = {}
local strict = false
local warnFn: (string) -> () = function(message: string)
	warn(message)
end

local VALID_KINDS: { [string]: boolean } = { image = true, audio = true, animation = true, mesh = true, video = true }

-- Registers a generated id table. Duplicate names across owners are an error: asset names
-- must be globally unique so Assets.get never depends on registration order.
function Assets.register(ids: IdTable, owner: string?)
	local who = owner or "game"
	for name, entry in ids do
		local existing = registry[name]
		if existing and existing.owner ~= who then
			error(string.format("Assets.register: %q is defined by both %s and %s", name, existing.owner, who), 2)
		end
		assert(VALID_KINDS[entry.kind], string.format("Assets.register: %q has unknown kind %q", name, entry.kind))
		assert(
			entry.status == "pending" or entry.status == "uploaded",
			string.format("Assets.register: %q has unknown status %q", name, entry.status)
		)
		if entry.status == "uploaded" then
			assert(
				type(entry.assetId) == "number",
				string.format("Assets.register: %q is uploaded but has no assetId", name)
			)
		end
		registry[name] = { kind = entry.kind, status = entry.status, assetId = entry.assetId, owner = who }
	end
end

-- Test helper: forget every registered id, including RBLXShared's own.
function Assets.clear()
	table.clear(registry)
	table.clear(warned)
end

-- Test helper: forget everything except RBLXShared's own ids.
function Assets.reset()
	Assets.clear()
	Assets.register(SharedIds, "RBLXShared")
end

-- In strict mode unknown names raise instead of warning (tests, lint, Studio sims).
function Assets.setStrict(enabled: boolean)
	strict = enabled
end

function Assets.setWarnHandler(handler: (string) -> ())
	warnFn = handler
end

local function unknown(name: string)
	local message = string.format("[Assets] unknown asset %q (add it to assets/manifest.json)", name)
	if strict then
		error(message, 3)
	end
	if not warned[name] then
		warned[name] = true
		warnFn(message)
	end
end

function Assets.has(name: string): boolean
	return registry[name] ~= nil
end

function Assets.ref(name: string): AssetRef
	local entry = registry[name]
	if not entry then
		unknown(name)
		return { name = name, kind = "image", status = "pending", assetId = nil, uri = "", placeholder = true }
	end
	local uploaded = entry.status == "uploaded" and entry.assetId ~= nil
	return {
		name = name,
		kind = entry.kind :: Kind,
		status = entry.status :: Status,
		assetId = entry.assetId,
		uri = if uploaded then "rbxassetid://" .. string.format("%d", entry.assetId :: number) else "",
		placeholder = not uploaded,
	}
end

-- Content id string for Image/SoundId/AnimationId properties; "" while pending or unknown.
function Assets.get(name: string): string
	return Assets.ref(name).uri
end

-- "<name>_<size>" when that variant is registered, else the base name.
function Assets.variant(name: string, size: number?): string
	if size then
		local sized = string.format("%s_%d", name, size)
		if registry[sized] then
			return sized
		end
	end
	return name
end

function Assets.isPlaceholder(name: string): boolean
	return Assets.ref(name).placeholder
end

function Assets.list(): { AssetRef }
	local names = {}
	for name in registry do
		table.insert(names, name)
	end
	table.sort(names)
	local out = {}
	for _, name in names do
		table.insert(out, Assets.ref(name))
	end
	return out
end

function Assets.pending(): { AssetRef }
	local out = {}
	for _, ref in Assets.list() do
		if ref.placeholder then
			table.insert(out, ref)
		end
	end
	return out
end

-- Placeholder card colors come from the UI tokens: saturated fills that read with white,
-- Ink-stroked text. Picked by name hash so the same asset always gets the same color.
local PLACEHOLDER_TOKENS: { string } = {
	Tokens.accents.stilts.primary,
	Tokens.accents.stilts.secondary,
	Tokens.accents.car.primary,
	Tokens.palette.danger,
	Tokens.palette.info,
	Tokens.palette.successEdge,
	Tokens.palette.warningEdge,
	Tokens.palette.dangerEdge,
}

local function rgbOf(hex: string): { number }
	local c = Color.parse(hex)
	return { c.r, c.g, c.b }
end

local PLACEHOLDER_PALETTE: { { number } } = {}
for _, hex in PLACEHOLDER_TOKENS do
	table.insert(PLACEHOLDER_PALETTE, rgbOf(hex))
end
local INK = rgbOf(Tokens.palette.ink)
local WHITE = rgbOf(Tokens.palette.white)

local function hashName(name: string): number
	local hash = 5381
	for i = 1, #name do
		hash = (hash * 33 + string.byte(name, i)) % 4294967296
	end
	return hash
end

-- { r, g, b } in 0..255.
function Assets.placeholderColor(name: string): { number }
	return table.clone(PLACEHOLDER_PALETTE[hashName(name) % #PLACEHOLDER_PALETTE + 1])
end

local function applyProps(instance: Instance, props: { [string]: any }?)
	if props then
		for key, value in props do
			(instance :: any)[key] = value
		end
	end
end

-- The visible placeholder: a rounded colored card with the asset name in white, stroked text.
function Assets.placeholder(name: string, props: { [string]: any }?): Frame
	local rgb = Assets.placeholderColor(name)
	local frame = Instance.new("Frame")
	frame.Name = "Placeholder_" .. name
	frame.BackgroundColor3 = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(64, 64)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.chip)
	corner.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "AssetName"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = Font.new(Tokens.fonts.body, Enum.FontWeight.Bold)
	label.Text = name
	label.TextColor3 = Color3.fromRGB(WHITE[1], WHITE[2], WHITE[3])
	label.TextScaled = true
	label.TextWrapped = true
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.fromRGB(INK[1], INK[2], INK[3])
	label.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 4)
	padding.Parent = label

	applyProps(frame, props)
	return frame
end

-- ImageLabel for an uploaded image, or the placeholder card (a Frame) while pending.
function Assets.image(name: string, options: ImageOptions?): GuiObject
	local opts: ImageOptions = options or {}
	local resolved = Assets.variant(name, opts.size)
	local ref = Assets.ref(resolved)
	if ref.placeholder then
		return Assets.placeholder(resolved, opts.props)
	end
	local image = Instance.new("ImageLabel")
	image.Name = resolved
	image.BackgroundTransparency = 1
	image.Image = ref.uri
	image.ScaleType = Enum.ScaleType.Fit
	image.Size = UDim2.fromOffset(opts.size or 64, opts.size or 64)
	applyProps(image, opts.props)
	return image
end

-- Sets Image on an existing ImageLabel/ImageButton, or overlays a placeholder card inside it.
function Assets.applyImage(target: ImageLabel | ImageButton, name: string, size: number?)
	local resolved = Assets.variant(name, size)
	local ref = Assets.ref(resolved)
	local existing = target:FindFirstChild("Placeholder_" .. resolved)
	if ref.placeholder then
		(target :: any).Image = ""
		if not existing then
			Assets.placeholder(resolved, { Size = UDim2.fromScale(1, 1), Parent = target })
		end
	else
		(target :: any).Image = ref.uri
		if existing then
			existing:Destroy()
		end
	end
end

-- Sound with SoundId set (silent while pending; warns once so it shows in Output).
function Assets.sound(name: string, props: { [string]: any }?): Sound
	local ref = Assets.ref(name)
	if ref.kind ~= "audio" then
		error(string.format("Assets.sound: %q is a %s asset, not audio", name, ref.kind), 2)
	end
	if ref.placeholder and not warned["pending:" .. name] then
		warned["pending:" .. name] = true
		warnFn(string.format("[Assets] %q is pending upload; playing silence", name))
	end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = ref.uri
	applyProps(sound, props)
	return sound
end

Assets.register(SharedIds, "RBLXShared")

return Assets
