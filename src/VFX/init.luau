--!strict
--[[
	VFX (brief §4, §5.7): particle presets, highlight/outline helpers, camera shake with an
	intensity cap, and screen flash. Client side.

	  local vfx = Shared.VFX.new()
	  vfx:emit("sparkle", character.HumanoidRootPart)        -- pooled emitter on the part
	  vfx:emitAt("splash", hitPosition)                       -- one-off at a world position
	  local glow = vfx:highlight(model, { color = "warning", duration = 0.6 })
	  vfx:shake(0.4)                                          -- trauma 0..1, capped, scaled by Settings
	  vfx:flash("white", { peak = 0.5 })                      -- off when the player turns flashes off

	Settings drive `setShakeScale` (0 turns shake off) and `setFlashesEnabled`. Highlights are
	capped below Roblox's limit of 31 visible at once: past the cap the oldest one is removed.

	Pure parts (Shake, Presets) run under lune; the rest needs Roblox, with `createInstance`,
	`camera`, `runService`, `playerGui`, `terrain` and `task` injectable.
]]

local Presets = require("@self/Presets")
local Roblox = require("./Util/Roblox")
local Shake = require("@self/Shake")
local Theme = require("./UI/Theme")
local Tokens = require("./UI/Tokens")

export type Preset = Presets.Preset

export type HighlightOptions = {
	color: Theme.ColorName?, -- outline, default "white"
	fill: Theme.ColorName?, -- fill color, default = color
	fillTransparency: number?, -- default 0.75
	outlineTransparency: number?, -- default 0
	duration: number?, -- seconds; nil = until removed
	alwaysOnTop: boolean?, -- default false (occluded like the world)
	fadeIn: number?, -- seconds, default 0.12
}

export type HighlightHandle = {
	instance: Instance,
	remove: (fade: number?) -> (),
}

export type FlashOptions = {
	peak: number?, -- opacity at the peak, 0..1, default 0.55
	duration: number?, -- seconds total, default 0.35
}

export type Options = {
	createInstance: ((className: string) -> any)?,
	camera: (() -> Camera?)?,
	runService: any?,
	playerGui: (() -> Instance?)?,
	terrain: (() -> Instance?)?,
	task: any?,
	tweenService: any?,
	shake: Shake.Options?,
	maxHighlights: number?, -- default 24 (Roblox renders at most 31)
}

export type VFX = {
	emit: (self: VFX, preset: string, target: Instance, count: number?) -> (),
	emitAt: (self: VFX, preset: string, position: Vector3, count: number?) -> (),
	highlight: (self: VFX, target: Instance, options: HighlightOptions?) -> HighlightHandle,
	shake: (self: VFX, amount: number) -> (),
	setShakeScale: (self: VFX, scale: number) -> (),
	flash: (self: VFX, color: Theme.ColorName?, options: FlashOptions?) -> (),
	setFlashesEnabled: (self: VFX, enabled: boolean) -> (),
	activeHighlights: (self: VFX) -> number,
	destroy: (self: VFX) -> (),
}

local VFX = {}

VFX.Shake = Shake
VFX.Presets = Presets

VFX.MAX_HIGHLIGHTS = 24

--- Adds or replaces a preset (validated). Games namespace theirs: "car.mudSpray".
function VFX.definePreset(name: string, preset: Preset)
	local problems = Presets.validate(name, preset)
	if #problems > 0 then
		error("VFX.definePreset: " .. table.concat(problems, "; "), 2)
	end
	Presets.list[name] = preset
end

local DIRECTIONS = { Top = "Top", Bottom = "Bottom", Front = "Front", Back = "Back", Left = "Left", Right = "Right" }

-- Builds one ParticleEmitter per preset color (Roblox only: ColorSequence etc.).
local function buildEmitters(createInstance: (string) -> any, preset: Preset): { any }
	local emitters = {}
	for _, colorName in preset.colors do
		local e = createInstance("ParticleEmitter")
		e.Enabled = false
		e.Rate = 0
		e.Texture = Presets.TEXTURES[preset.texture]
		e.Color = ColorSequence.new(Theme.color(colorName :: any))
		e.LightEmission = preset.lightEmission or 0
		e.Lifetime = NumberRange.new(preset.lifetime.min, preset.lifetime.max)
		e.Speed = NumberRange.new(preset.speed.min, preset.speed.max)
		e.Size = NumberSequence.new(preset.size.start, preset.size.finish)
		e.Transparency = NumberSequence.new(preset.transparency.start, preset.transparency.finish)
		local spread = preset.spread or 30
		e.SpreadAngle = Vector2.new(spread, spread)
		local a = preset.acceleration
		e.Acceleration = if a then Vector3.new(a.x, a.y, a.z) else Vector3.zero
		e.Drag = preset.drag or 0
		if preset.rotation then
			e.Rotation = NumberRange.new(preset.rotation.min, preset.rotation.max)
		end
		if preset.rotSpeed then
			e.RotSpeed = NumberRange.new(preset.rotSpeed.min, preset.rotSpeed.max)
		end
		e.EmissionDirection = (Enum.NormalId :: any)[DIRECTIONS[preset.direction or "Top"]]
		e.LockedToPart = false
		table.insert(emitters, e)
	end
	return emitters
end

local function presetOf(name: string): Preset
	local preset = Presets.list[name]
	if preset == nil then
		error(`VFX: unknown preset "{name}"`, 3)
	end
	return preset
end

function VFX.new(options: Options?): VFX
	local opts: Options = options or {}
	local createInstance: (string) -> any = opts.createInstance
		or function(className: string): any
			return Instance.new(className :: any)
		end
	local taskLib: any = opts.task
	local maxHighlights = math.min(opts.maxHighlights or VFX.MAX_HIGHLIGHTS, 30)
	local shakeModel = Shake.new(opts.shake)
	local flashesEnabled = true
	local destroyed = false

	local function getTask(): any
		taskLib = taskLib or Roblox.task()
		return taskLib
	end

	local function camera(): Camera?
		if opts.camera then
			return opts.camera()
		end
		local workspace = Roblox.service("Workspace")
		return workspace.CurrentCamera
	end

	local function tween(instance: Instance, seconds: number, goal: { [string]: any })
		local service: any = opts.tweenService or Roblox.service("TweenService")
		local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		service:Create(instance, info, goal):Play()
	end

	local vfx = {} :: VFX

	-- Emitters cached per target, so repeated emits reuse instances.
	local cache: { [Instance]: { [string]: { any } } } = setmetatable({}, { __mode = "k" }) :: any

	function vfx.emit(_self: VFX, name: string, target: Instance, count: number?)
		if destroyed then
			return
		end
		local preset = presetOf(name)
		local byPreset = cache[target]
		if byPreset == nil then
			byPreset = {}
			cache[target] = byPreset
		end
		local emitters = byPreset[name]
		if emitters == nil or emitters[1].Parent == nil then
			emitters = buildEmitters(createInstance, preset)
			for _, e in emitters do
				e.Name = "VFX_" .. name
				e.Parent = target
			end
			byPreset[name] = emitters
		end
		local counts = Presets.split(count or preset.count, #emitters)
		for i, e in emitters do
			e:Emit(counts[i])
		end
	end

	function vfx.emitAt(self: VFX, name: string, position: Vector3, count: number?)
		if destroyed then
			return
		end
		local preset = presetOf(name)
		local holder: Instance? = if opts.terrain then opts.terrain() else Roblox.service("Workspace").Terrain
		local attachment = createInstance("Attachment")
		attachment.Name = "VFX_" .. name
		attachment.WorldPosition = position
		attachment.Parent = holder
		self:emit(name, attachment, count)
		getTask().delay(preset.lifetime.max + 0.5, function()
			attachment:Destroy()
		end)
	end

	local highlights: { HighlightHandle } = {}

	function vfx.highlight(_self: VFX, target: Instance, hOptions: HighlightOptions?): HighlightHandle
		local o: HighlightOptions = hOptions or {}
		while #highlights >= maxHighlights do
			highlights[1].remove(0)
		end
		local outline = Theme.color(o.color or "white")
		local h = createInstance("Highlight")
		h.Name = "VFX_Highlight"
		h.Adornee = target
		h.OutlineColor = outline
		h.FillColor = Theme.color(o.fill or o.color or "white")
		h.DepthMode = if o.alwaysOnTop then Enum.HighlightDepthMode.AlwaysOnTop else Enum.HighlightDepthMode.Occluded
		local fillTarget = o.fillTransparency or 0.75
		local outlineTarget = o.outlineTransparency or 0
		h.FillTransparency = 1
		h.OutlineTransparency = 1
		h.Parent = target
		local fadeIn = o.fadeIn or Tokens.motion.fastDuration
		if fadeIn > 0 then
			tween(h, fadeIn, { FillTransparency = fillTarget, OutlineTransparency = outlineTarget })
		else
			h.FillTransparency = fillTarget
			h.OutlineTransparency = outlineTarget
		end
		local removed = false
		local handle: HighlightHandle
		handle = {
			instance = h,
			remove = function(fade: number?)
				if removed then
					return
				end
				removed = true
				local i = table.find(highlights, handle)
				if i then
					table.remove(highlights, i)
				end
				local seconds = fade or Tokens.motion.exitDuration
				if seconds > 0 then
					tween(h, seconds, { FillTransparency = 1, OutlineTransparency = 1 })
					getTask().delay(seconds, function()
						h:Destroy()
					end)
				else
					h:Destroy()
				end
			end,
		}
		table.insert(highlights, handle)
		if o.duration then
			getTask().delay(o.duration, function()
				handle.remove(nil)
			end)
		end
		return handle
	end

	function vfx.activeHighlights(_self: VFX): number
		return #highlights
	end

	-- Camera shake: applied after the camera scripts each frame, so it never accumulates.
	local bound = false
	local BIND_NAME = "RBLXShared.VFX.Shake"

	local function unbindShake()
		if bound then
			bound = false
			local runService: any = opts.runService or Roblox.service("RunService")
			runService:UnbindFromRenderStep(BIND_NAME)
		end
	end

	local function bindShake()
		if bound then
			return
		end
		bound = true
		local runService: any = opts.runService or Roblox.service("RunService")
		runService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt: number)
			local sample = shakeModel:step(dt)
			local cam = camera()
			if cam then
				cam.CFrame = cam.CFrame
					* CFrame.new(sample.x, sample.y, 0)
					* CFrame.Angles(math.rad(sample.pitch), math.rad(sample.yaw), math.rad(sample.roll))
			end
			if not shakeModel:isActive() then
				unbindShake()
			end
		end)
	end

	function vfx.shake(_self: VFX, amount: number)
		if destroyed or shakeModel.scale <= 0 then
			return
		end
		shakeModel:add(amount)
		bindShake()
	end

	function vfx.setShakeScale(_self: VFX, scale: number)
		shakeModel:setScale(scale)
		if shakeModel.scale <= 0 then
			shakeModel:reset()
		end
	end

	local flashGui: ScreenGui? = nil

	function vfx.flash(_self: VFX, colorName: Theme.ColorName?, fOptions: FlashOptions?)
		if destroyed or not flashesEnabled then
			return
		end
		local o: FlashOptions = fOptions or {}
		local parent: Instance? = if opts.playerGui
			then opts.playerGui()
			else Roblox.service("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if parent == nil then
			return
		end
		if flashGui == nil or flashGui.Parent == nil then
			local gui = createInstance("ScreenGui")
			gui.Name = "RBLXShared_Flash"
			gui.IgnoreGuiInset = true
			gui.ResetOnSpawn = false
			gui.DisplayOrder = Tokens.layers.banner + 5
			gui.Parent = parent
			flashGui = gui
		end
		local frame = createInstance("Frame")
		frame.Name = "Flash"
		frame.BorderSizePixel = 0
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Theme.color(colorName or "white")
		frame.BackgroundTransparency = 1
		frame.Active = false
		frame.Parent = flashGui
		local peak = math.clamp(o.peak or 0.55, 0, 0.85) -- never a full white-out
		local total = o.duration or 0.35
		local rise = math.min(0.06, total * 0.25)
		tween(frame, rise, { BackgroundTransparency = 1 - peak })
		getTask().delay(rise, function()
			tween(frame, total - rise, { BackgroundTransparency = 1 })
		end)
		getTask().delay(total + 0.05, function()
			frame:Destroy()
		end)
	end

	function vfx.setFlashesEnabled(_self: VFX, enabled: boolean)
		flashesEnabled = enabled
	end

	function vfx.destroy(_self: VFX)
		destroyed = true
		unbindShake()
		for _, h in table.clone(highlights) do
			h.remove(0)
		end
		if flashGui then
			flashGui:Destroy()
		end
	end

	return vfx
end

return VFX
