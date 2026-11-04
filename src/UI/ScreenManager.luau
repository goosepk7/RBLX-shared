--!strict
--[[
	ScreenManager (§5.3): one screen at a time, push/pop with transitions,
	input-mode aware (Touch/Gamepad/Keyboard), console focus navigation,
	the 2-modal cap (§5.4), and HUD hiding for cinematic moments.

		local screens = UI.ScreenManager.new(area)
		screens:register("Shop", function(ctx) return { root = buildShop(ctx.params), defaultFocus = buyButton } end)
		screens:push("Shop", { tab = "Passes" })
		screens:pop()
		screens:setCinematic(true) -- hides HUD + screens during world unlock / rebirth

	Screen factories are called on every push so screens always open with
	fresh state; keep expensive data in controllers, not in screen roots.
]]

local Create = require("./Create")
local Layout = require("./Layout")
local Modal = require("./Kit/Modal")
local Motion = require("./Motion")
local SafeArea = require("./SafeArea")
local Tokens = require("./Tokens")

export type InputMode = Layout.InputMode

export type ScreenContext = {
	params: any,
	manager: ScreenManager,
	inputMode: InputMode,
	close: () -> (),
}

export type Screen = {
	root: GuiObject,
	defaultFocus: GuiObject?,
	onShow: (() -> ())?,
	onHide: (() -> ())?,
	onInputModeChanged: ((InputMode) -> ())?,
}

export type ScreenFactory = (ScreenContext) -> Screen

type Entry = { name: string, screen: Screen, holder: Frame }

export type ScreenManager = {
	register: (self: ScreenManager, name: string, factory: ScreenFactory) -> (),
	push: (self: ScreenManager, name: string, params: any?) -> Screen,
	pop: (self: ScreenManager) -> (),
	replace: (self: ScreenManager, name: string, params: any?) -> Screen,
	clear: (self: ScreenManager) -> (),
	current: (self: ScreenManager) -> string?,
	depth: (self: ScreenManager) -> number,
	showModal: (
		self: ScreenManager,
		content: GuiObject,
		opts: { DismissOnBackdrop: boolean?, OnClosed: (() -> ())? }?
	) -> Modal.Handle?,
	modalCount: (self: ScreenManager) -> number,
	closeTopModal: (self: ScreenManager) -> (),
	getInputMode: (self: ScreenManager) -> InputMode,
	onInputModeChanged: (self: ScreenManager, fn: (InputMode) -> ()) -> () -> (),
	setCinematic: (self: ScreenManager, on: boolean) -> (),
	destroy: (self: ScreenManager) -> (),
}

local ScreenManager = {}
ScreenManager.__index = ScreenManager

type Internal = ScreenManager & {
	_area: SafeArea.SafeArea,
	_layer: Frame,
	_modalLayer: Frame,
	_factories: { [string]: ScreenFactory },
	_stack: { Entry },
	_modals: { Modal.Handle },
	_mode: InputMode,
	_modeListeners: { (InputMode) -> () },
	_conns: { RBXScriptConnection },
	_cinematic: boolean,
	_applyFocus: (self: Internal) -> (),
	_build: (self: Internal, name: string, params: any?) -> Entry,
}

local function initialMode(uis: UserInputService): InputMode
	if uis.GamepadEnabled and not uis.TouchEnabled and not uis.KeyboardEnabled then
		return "Gamepad"
	elseif uis.TouchEnabled and not uis.KeyboardEnabled then
		return "Touch"
	end
	return Layout.inputModeFor(uis:GetLastInputType().Name) or "Keyboard"
end

function ScreenManager.new(area: SafeArea.SafeArea): ScreenManager
	local uis = game:GetService("UserInputService")
	local self = setmetatable({}, ScreenManager) :: any
	self._area = area
	self._factories = {}
	self._stack = {}
	self._modals = {}
	self._modeListeners = {}
	self._conns = {}
	self._cinematic = false
	self._mode = initialMode(uis)
	self._layer = Create.group({ Name = "Screens", ZIndex = 40, Parent = area.content })
	self._modalLayer = Create.group({ Name = "Modals", ZIndex = 50, Parent = area.content })

	table.insert(
		self._conns,
		uis.LastInputTypeChanged:Connect(function(t: Enum.UserInputType)
			local mode = Layout.inputModeFor(t.Name)
			if mode and mode ~= self._mode then
				self._mode = mode
				self:_applyFocus()
				local top = self._stack[#self._stack]
				if top and top.screen.onInputModeChanged then
					top.screen.onInputModeChanged(mode)
				end
				for _, fn in self._modeListeners do
					task.spawn(fn, mode)
				end
			end
		end)
	)
	-- Console "B" closes the top modal, then the top screen.
	table.insert(
		self._conns,
		uis.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed or input.KeyCode ~= Enum.KeyCode.ButtonB then
				return
			end
			if #self._modals > 0 then
				self:closeTopModal()
			elseif #self._stack > 0 then
				self:pop()
			end
		end)
	)
	return self :: ScreenManager
end

function ScreenManager._applyFocus(self: Internal)
	local guiService = game:GetService("GuiService")
	if self._mode ~= "Gamepad" then
		guiService.SelectedObject = nil
		return
	end
	local top = self._stack[#self._stack]
	if top and top.screen.defaultFocus and top.screen.defaultFocus:IsDescendantOf(game) then
		guiService.SelectedObject = top.screen.defaultFocus
	end
end

function ScreenManager.register(self: Internal, name: string, factory: ScreenFactory)
	self._factories[name] = factory
end

local function transitionIn(holder: Frame)
	local scale = holder:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = Tokens.motion.modalStartScale
	holder.Position = UDim2.fromScale(0, 0.04)
	holder.Visible = true
	Motion.enter(scale, { Scale = 1 })
	Motion.tween(holder, Tokens.motion.enterDuration, "Enter", { Position = UDim2.fromScale(0, 0) })
end

local function transitionOut(holder: Frame, destroy: boolean)
	local scale = holder:FindFirstChildOfClass("UIScale") :: UIScale
	Motion.exit(scale, { Scale = 0.94 })
	Motion.exit(holder, { Position = UDim2.fromScale(0, 0.04) }).Completed:Once(function()
		if destroy then
			holder:Destroy()
		else
			holder.Visible = false
		end
	end)
end

function ScreenManager._build(self: Internal, name: string, params: any?): Entry
	local factory = self._factories[name]
	if factory == nil then
		error(`UI.ScreenManager: no screen registered as "{name}"`, 3)
	end
	local holder = Create.group({ Name = name, Visible = false, ZIndex = 40 })
	Create.new("UIScale", { Scale = 1, Parent = holder })
	local screen = factory({
		params = params,
		manager = self :: any,
		inputMode = self._mode,
		close = function()
			local top = self._stack[#self._stack]
			if top and top.holder == holder then
				self:pop()
			end
		end,
	})
	screen.root.Parent = holder
	holder.Parent = self._layer
	return { name = name, screen = screen, holder = holder }
end

function ScreenManager.push(self: Internal, name: string, params: any?): Screen
	local below = self._stack[#self._stack]
	if below then
		if below.screen.onHide then
			below.screen.onHide()
		end
		transitionOut(below.holder, false)
	end
	local entry = self:_build(name, params)
	table.insert(self._stack, entry)
	if not self._cinematic then
		transitionIn(entry.holder)
	end
	if entry.screen.onShow then
		entry.screen.onShow()
	end
	self:_applyFocus()
	return entry.screen
end

function ScreenManager.pop(self: Internal)
	local top = table.remove(self._stack)
	if top == nil then
		return
	end
	if top.screen.onHide then
		top.screen.onHide()
	end
	transitionOut(top.holder, true)
	local below = self._stack[#self._stack]
	if below then
		if not self._cinematic then
			transitionIn(below.holder)
		end
		if below.screen.onShow then
			below.screen.onShow()
		end
	end
	self:_applyFocus()
end

function ScreenManager.replace(self: Internal, name: string, params: any?): Screen
	local top = table.remove(self._stack)
	if top then
		if top.screen.onHide then
			top.screen.onHide()
		end
		transitionOut(top.holder, true)
	end
	return self:push(name, params)
end

function ScreenManager.clear(self: Internal)
	while #self._stack > 0 do
		self:pop()
	end
end

function ScreenManager.current(self: Internal): string?
	local top = self._stack[#self._stack]
	return if top then top.name else nil
end

function ScreenManager.depth(self: Internal): number
	return #self._stack
end

--- Shows content in a Modal. Returns nil (and opens nothing) when two
--- modals are already open: §5.4 forbids a third.
function ScreenManager.showModal(
	self: Internal,
	content: GuiObject,
	opts: { DismissOnBackdrop: boolean?, OnClosed: (() -> ())? }?
): Modal.Handle?
	if #self._modals >= Tokens.limits.maxModals then
		warn(`UI.ScreenManager: refused a third modal (max {Tokens.limits.maxModals}); close one first`)
		return nil
	end
	local o: { DismissOnBackdrop: boolean?, OnClosed: (() -> ())? } = opts or {}
	local handle: Modal.Handle
	handle = Modal.new({
		Content = content,
		DismissOnBackdrop = o.DismissOnBackdrop,
		OnClosed = function()
			local i = table.find(self._modals, handle)
			if i then
				table.remove(self._modals, i)
			end
			handle.root:Destroy()
			if o.OnClosed then
				o.OnClosed()
			end
		end,
	})
	table.insert(self._modals, handle)
	handle.open(self._modalLayer)
	return handle
end

function ScreenManager.modalCount(self: Internal): number
	return #self._modals
end

function ScreenManager.closeTopModal(self: Internal)
	local top = self._modals[#self._modals]
	if top then
		top.close()
	end
end

function ScreenManager.getInputMode(self: Internal): InputMode
	return self._mode
end

function ScreenManager.onInputModeChanged(self: Internal, fn: (InputMode) -> ()): () -> ()
	table.insert(self._modeListeners, fn)
	return function()
		local i = table.find(self._modeListeners, fn)
		if i then
			table.remove(self._modeListeners, i)
		end
	end
end

--- Hides every HUD anchor, screen and modal (world unlock, rebirth, Iron
--- Build award). Banners stay so the moment can still announce itself.
function ScreenManager.setCinematic(self: Internal, on: boolean)
	self._cinematic = on
	for name, frame in self._area.anchors do
		if name ~= "TopCenter" then
			frame.Visible = not on
		end
	end
	self._layer.Visible = not on
	self._modalLayer.Visible = not on
	self._area.toasts.root.Visible = not on
	if not on then
		local top = self._stack[#self._stack]
		if top then
			top.holder.Visible = true
		end
	end
end

function ScreenManager.destroy(self: Internal)
	for _, c in self._conns do
		c:Disconnect()
	end
	self._layer:Destroy()
	self._modalLayer:Destroy()
end

return ScreenManager
