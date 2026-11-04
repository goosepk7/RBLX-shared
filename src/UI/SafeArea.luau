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

		local area = UI.SafeArea.new({ Name = "StiltsHUD" })
		Kit.CurrencyPill.new({ ..., Parent = area.anchors.TopLeft })
		area.banners.show({ Text = "..." })
]]

local Create = require("./Create")
local Layout = require("./Layout")
local Tokens = require("./Tokens")
local Banner = require("./Kit/Banner")
local Toast = require("./Kit/Toast")

export type AnchorName = "TopLeft" | "TopCenter" | "TopRight" | "RightRail" | "BottomRight" | "BottomCenter" | "Center"

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
	getScale: () -> number,
	setVisible: (boolean) -> (),
	destroy: () -> (),
}

local SafeArea = {}

local function anchor(name: string, props: { [string]: any }, layout: Instance?): Frame
	local frame = Create.group(props)
	frame.Name = name
	if layout then
		layout.Parent = frame
	end
	return frame
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
	local gui = Create.new("ScreenGui", {
		Name = p.Name or "RBLXSharedUI",
		DisplayOrder = p.DisplayOrder or Tokens.layers.hud,
		IgnoreGuiInset = false,
		ResetOnSpawn = p.ResetOnSpawn == true,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})

	local content = Create.group({ Name = "Content" }, {
		Create.padding(0, Layout.GUTTER, Layout.GUTTER, Layout.GUTTER),
	})
	content.Parent = gui

	-- The UIScale lives on an inner frame sized 1/scale so scaled children
	-- still span exactly the safe area.
	local scaled = Create.group({ Name = "Scaled" })
	local scale = Create.new("UIScale", { Scale = 1, Parent = scaled })
	scaled.Parent = content

	local gap = Tokens.size.iconButtonGap
	local anchors: { [AnchorName]: Frame } = {
		TopLeft = anchor("TopLeft", {
			Position = UDim2.fromOffset(0, Tokens.space.sm),
			Size = UDim2.new(0.3, 0, 0.5, 0),
		}, Create.list("Vertical", Tokens.space.sm, "Left", "Top")),
		TopCenter = anchor("TopCenter", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.new(0.4, 0, 0, 120),
		}),
		TopRight = anchor("TopRight", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, Tokens.space.sm),
			Size = UDim2.new(0.3, 0, 0, Tokens.size.iconButton + Tokens.edge.chip),
		}, Create.list("Horizontal", gap, "Right", "Top")),
		RightRail = anchor("RightRail", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.42),
			Size = UDim2.new(0, Tokens.size.iconButton, 0.5, 0),
		}, Create.list("Vertical", gap, "Right", "Center")),
		BottomRight = anchor("BottomRight", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromScale(0.38, 0.5),
		}),
		BottomCenter = anchor("BottomCenter", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.new(0.24, 0, 0, Tokens.size.chipHeight + Tokens.edge.chip),
		}, Create.list("Horizontal", gap, "Center", "Bottom")),
		Center = anchor("Center", {}),
	}
	for _, frame in anchors do
		frame.Parent = scaled
	end

	local overlay = Create.group({ Name = "Overlay", ZIndex = 60, Parent = scaled })
	local banners = Banner.lane(overlay)
	local toasts = Toast.lane(overlay)

	local function update()
		local size = gui.AbsoluteSize
		local s = Layout.scaleFor(size.X, size.Y)
		scale.Scale = s
		scaled.Size = UDim2.fromScale(1 / s, 1 / s)
	end
	local conn = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)

	gui.Parent = p.Parent or defaultParent()
	update()

	return {
		gui = gui,
		content = scaled,
		scale = scale,
		anchors = anchors,
		banners = banners,
		toasts = toasts,
		getScale = function()
			return scale.Scale
		end,
		setVisible = function(visible: boolean)
			gui.Enabled = visible
		end,
		destroy = function()
			conn:Disconnect()
			gui:Destroy()
		end,
	}
end

return SafeArea
