--!strict
--[[
	SafeArea (§5.3): the root every game UI lives in.

	- ScreenGui uses ScreenInsets.CoreUISafeInsets, which keeps content clear
	  of the device notch/cutouts AND the Roblox topbar buttons.
	- A UIScale driven by the viewport's shorter edge (Layout.scaleFor) makes
	  token sizes correct on every device.
	- A content frame applies the side gutter, and exposes named anchors for
	  the HUD layout in §5.4 so games never position HUD elements by hand.
	- Banner and Toast lanes are created once, top-center.
	- Modals get their own safe-area ScreenGui above the HUD, plus a
	  full-bleed backdrop ScreenGui (no insets) so the 55% dim covers the
	  notch bands and gutters too.

		local area = UI.SafeArea.new({ Name = "StiltsHUD" })
		Kit.CurrencyPill.new({ ..., Parent = area.anchors.TopLeft })
		area.banners.show({ Text = "..." })
]]

local Create = require("./Create")
local Layout = require("./Layout")
local Tokens = require("./Tokens")
local Banner = require("./Kit/Banner")
local Toast = require("./Kit/Toast")

export type AnchorName = Layout.AnchorName

export type Props = {
	Name: string?,
	DisplayOrder: number?,
	Parent: Instance?, -- default: LocalPlayer.PlayerGui
	ResetOnSpawn: boolean?,
}

export type SafeArea = {
	gui: ScreenGui,
	content: Frame,
	scale: UIScale,
	anchors: { [AnchorName]: Frame },
	banners: Banner.Lane,
	toasts: Toast.Lane,
	modalLayer: Frame, -- safe-area layer above the HUD for modal/drawer content
	backdropLayer: Frame, -- full-screen layer under modalLayer for dims/scrims
	getScale: () -> number,
	setVisible: (boolean) -> (),
	setModalsVisible: (boolean) -> (),
	destroy: () -> (),
}

local SafeArea = {}

local LAYOUTS: { [AnchorName]: () -> Instance } = {
	TopLeft = function()
		return Create.list("Vertical", Tokens.space.sm, "Left", "Top")
	end,
	TopRight = function()
		return Create.list("Horizontal", Tokens.size.iconButtonGap, "Right", "Top")
	end,
	RightRail = function()
		return Create.list("Vertical", Tokens.size.iconButtonGap, "Right", "Center")
	end,
	BottomCenter = function()
		return Create.list("Horizontal", Tokens.size.iconButtonGap, "Center", "Bottom")
	end,
}

local ANCHOR_NAMES: { AnchorName } =
	{ "TopLeft", "TopCenter", "TopRight", "RightRail", "BottomRight", "BottomCenter", "Center" }

type ScaledGui = { gui: ScreenGui, scaled: Frame, scale: UIScale }

-- A ScreenGui inside the safe insets with gutter padding and a UIScale'd
-- inner frame sized 1/scale, so scaled children span exactly the safe area.
local function scaledGui(name: string, order: number, resetOnSpawn: boolean): ScaledGui
	local gui = Create.new("ScreenGui", {
		Name = name,
		DisplayOrder = order,
		IgnoreGuiInset = false,
		ResetOnSpawn = resetOnSpawn,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	local content = Create.group({ Name = "Content", Parent = gui }, {
		Create.padding(0, Layout.GUTTER, Layout.GUTTER, Layout.GUTTER),
	})
	local scaled = Create.group({ Name = "Scaled", Parent = content })
	local scale = Create.new("UIScale", { Scale = 1, Parent = scaled })
	return { gui = gui, scaled = scaled, scale = scale }
end

local function defaultParent(): Instance
	local players = game:GetService("Players")
	local player = players.LocalPlayer
	if player == nil then
		error("UI.SafeArea.new: no LocalPlayer; pass Parent explicitly when not on a client", 3)
	end
	return player:WaitForChild("PlayerGui", 10) or error("UI.SafeArea.new: PlayerGui did not load within 10 s", 3)
end

function SafeArea.new(props: Props?): SafeArea
	local p: Props = props or {}
	local name = p.Name or "RBLXSharedUI"
	local resetOnSpawn = p.ResetOnSpawn == true
	local hud = scaledGui(name, p.DisplayOrder or Tokens.layers.hud, resetOnSpawn)
	local modal = scaledGui(name .. "Modals", Tokens.layers.modal, resetOnSpawn)
	local backdropGui = Create.new("ScreenGui", {
		Name = name .. "Backdrop",
		DisplayOrder = Tokens.layers.modal - 1,
		IgnoreGuiInset = true,
		ResetOnSpawn = resetOnSpawn,
		ScreenInsets = Enum.ScreenInsets.None,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	local backdropLayer = Create.group({ Name = "Backdrops", Parent = backdropGui })

	local anchors = {} :: { [AnchorName]: Frame }
	for _, anchorName in ANCHOR_NAMES do
		local frame = Create.group({ Name = anchorName, Parent = hud.scaled })
		local makeLayout = LAYOUTS[anchorName]
		if makeLayout then
			makeLayout().Parent = frame
		end
		(anchors :: any)[anchorName] = frame
	end

	local overlay = Create.group({ Name = "Overlay", ZIndex = 60, Parent = hud.scaled })
	local banners = Banner.lane(overlay)
	local toasts = Toast.lane(overlay)

	local function update()
		local size = hud.gui.AbsoluteSize
		local s = Layout.scaleFor(size.X, size.Y)
		for _, g in { hud, modal } do
			g.scale.Scale = s
			g.scaled.Size = UDim2.fromScale(1 / s, 1 / s)
		end
		-- Anchor rects come from Layout.anchors (the same geometry the specs
		-- check against the thumbstick zone). Only x is screen-relative there,
		-- so the content rect's y can be taken as 0 and everything converts
		-- back to the scaled frame's local units.
		local camera = workspace.CurrentCamera
		local screen = if camera then camera.ViewportSize else size
		local origin = hud.scaled.AbsolutePosition
		local area = hud.scaled.AbsoluteSize
		local rects = Layout.anchors(screen.X, screen.Y, { x = origin.X, y = 0, w = area.X, h = area.Y }, s)
		for anchorName, frame in anchors do
			local r: Layout.Rect = (rects :: any)[anchorName]
			frame.Position = UDim2.fromOffset((r.x - origin.X) / s, r.y / s)
			frame.Size = UDim2.fromOffset(r.w / s, r.h / s)
		end
	end
	local conns = {
		hud.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(update),
		hud.scaled:GetPropertyChangedSignal("AbsolutePosition"):Connect(update),
	}

	local parent = p.Parent or defaultParent()
	backdropGui.Parent = parent
	modal.gui.Parent = parent
	hud.gui.Parent = parent
	update()

	return {
		gui = hud.gui,
		content = hud.scaled,
		scale = hud.scale,
		anchors = anchors,
		banners = banners,
		toasts = toasts,
		modalLayer = modal.scaled,
		backdropLayer = backdropLayer,
		getScale = function()
			return hud.scale.Scale
		end,
		setVisible = function(visible: boolean)
			hud.gui.Enabled = visible
		end,
		setModalsVisible = function(visible: boolean)
			modal.gui.Enabled = visible
			backdropGui.Enabled = visible
		end,
		destroy = function()
			for _, c in conns do
				c:Disconnect()
			end
			hud.gui:Destroy()
			modal.gui:Destroy()
			backdropGui:Destroy()
		end,
	}
end

return SafeArea
