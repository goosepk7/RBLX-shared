--!strict
--[[
	UI Gallery: renders every story (every component x variant) on one
	scrolling screen, with a Stilts/Car accent toggle and a phone-size frame
	toggle, so the owner can review the kit on device.

	Client bootstrap:
		local UI = RBLXShared.UI
		UI.Gallery.bindChatCommand({
			allowedUserIds = Config.Admins, -- Studio always allowed
		})
	Then type /uigallery in chat.
]]

local Create = require("./Create")
local Kit = require("./Kit")
local Layout = require("./Layout")
local Stories = require("@self/Stories")
local Theme = require("./Theme")
local Tokens = require("./Tokens")

export type Options = {
	parent: Instance?,
	allowedUserIds: { number }?,
}

local Gallery = {}

Gallery.Stories = Stories
Gallery.COMMAND = "/uigallery"

local DEFAULT_CELL = { x = 260, y = 150 }

local mounted: ScreenGui? = nil

local function buildSection(story: Stories.Story, env: Stories.Env, order: number): Frame
	local cell = story.cell or DEFAULT_CELL
	local section = Create.group({
		Name = story.component,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	}, { Create.list("Vertical", Tokens.space.sm, "Left", "Top") })
	Create.text({
		Name = "Heading",
		Text = story.component,
		Role = "display",
		SizeName = "h2",
		Color = "ink",
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = 1,
		Parent = section,
	})
	local grid = Create.group({
		Name = "Variants",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = section,
	}, {
		Create.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(cell.x, cell.y + 24),
			CellPadding = UDim2.fromOffset(Tokens.space.md, Tokens.space.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for i, variant in story.variants do
		local slot = Create.new("Frame", {
			Name = variant.name,
			BackgroundColor3 = Theme.color("paper"),
			BorderSizePixel = 0,
			LayoutOrder = i,
			Parent = grid,
		}, { Create.corner(Tokens.radius.card), Create.stroke("line", Tokens.border.card) })
		Create.text({
			Name = "Caption",
			Text = variant.name,
			Role = "caption",
			SizeName = "caption",
			Color = "inkSoft",
			XAlign = "Center",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, -4),
			Size = UDim2.new(1, 0, 0, 18),
			Parent = slot,
		})
		local stage = Create.group({ Name = "Stage", Size = UDim2.new(1, 0, 1, -24), Parent = slot })
		variant.build(env).Parent = stage
	end
	return section
end

--- Opens the gallery (replacing any open one). Returns the ScreenGui.
function Gallery.mount(opts: Options?): ScreenGui
	Gallery.unmount()
	local o: Options = opts or {}
	local parent = o.parent
	if parent == nil then
		local player = game:GetService("Players").LocalPlayer
		parent = player:WaitForChild("PlayerGui", 10)
		if parent == nil then
			error("UI.Gallery.mount: PlayerGui did not load within 10 s", 2)
		end
	end

	local function screenGui(name: string, order: number, fullBleed: boolean): ScreenGui
		return Create.new("ScreenGui", {
			Name = name,
			DisplayOrder = order,
			ResetOnSpawn = false,
			IgnoreGuiInset = fullBleed,
			ScreenInsets = if fullBleed then Enum.ScreenInsets.None else Enum.ScreenInsets.CoreUISafeInsets,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		})
	end
	-- Stack: full-bleed paper background, safe-area gallery panel, full-bleed
	-- dim layer for modal backdrops, safe-area layer for modal content.
	local background = screenGui("UIGalleryBackground", Tokens.layers.gallery - 1, true)
	local gui = screenGui("UIGallery", Tokens.layers.gallery, false)
	local dimGui = screenGui("UIGalleryDim", Tokens.layers.gallery + 1, true)
	local overlayGui = screenGui("UIGalleryOverlay", Tokens.layers.gallery + 2, false)
	Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.color("paper2"),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = background,
	})
	local scaled = Create.group({ Name = "Scaled", Parent = gui })
	local uiScale = Create.new("UIScale", { Parent = scaled })
	local overlay = Create.group({ Name = "Overlay", Parent = overlayGui })
	local dim = Create.group({ Name = "Backdrops", Parent = dimGui })
	gui.Destroying:Connect(function()
		background:Destroy()
		dimGui:Destroy()
		overlayGui:Destroy()
	end)

	local env: Stories.Env = {
		overlay = function()
			return overlay
		end,
		backdrop = function()
			return dim
		end,
		inputMode = function()
			local uis = game:GetService("UserInputService")
			return Layout.inputModeFor(uis:GetLastInputType().Name) or "Keyboard"
		end,
	}

	local root, panel = Kit.Panel.new({
		Title = "UI Gallery",
		Size = UDim2.new(1, -Tokens.space.lg * 2, 1, -Tokens.space.lg * 2),
		Position = UDim2.fromOffset(Tokens.space.lg, Tokens.space.lg),
		Scroll = true,
		FooterHeight = 0,
		OnClose = Gallery.unmount,
	})
	root.Parent = scaled

	local body = panel.body
	local function render()
		for _, child in body:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local controls = Create.group({
			Name = "Controls",
			Size = UDim2.new(1, 0, 0, 64),
			LayoutOrder = 0,
			Parent = body,
		}, { Create.list("Horizontal", Tokens.space.lg, "Left", "Center") })
		Kit.Tabs.new({
			Items = { "+1 Stilts", "Evolve a Car" },
			Selected = if Theme.getGame() == "car" then 2 else 1,
			Width = 340,
			Parent = controls,
			OnChanged = function(i)
				Theme.setGame(if i == 2 then "car" else "stilts")
			end,
		})
		Kit.Chip.new({
			Text = string.format("UI scale %.2f", uiScale.Scale),
			Variant = "Info",
			Parent = controls,
		})
		for i, story in Stories do
			buildSection(story, env, i).Parent = body
		end
	end

	local function rescale()
		local s = Layout.scaleFor(gui.AbsoluteSize.X, gui.AbsoluteSize.Y)
		uiScale.Scale = s
		scaled.Size = UDim2.fromScale(1 / s, 1 / s)
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale)

	local disconnect = Theme.onGameChanged(function()
		-- Rebuild so every component re-reads the accent tokens.
		task.defer(render)
	end)
	gui.Destroying:Connect(disconnect)

	background.Parent = parent
	gui.Parent = parent
	dimGui.Parent = parent
	overlayGui.Parent = parent
	rescale()
	render()
	mounted = gui
	return gui
end

function Gallery.unmount()
	if mounted then
		mounted:Destroy()
		mounted = nil
	end
end

function Gallery.toggle(opts: Options?)
	if mounted and mounted.Parent then
		Gallery.unmount()
	else
		Gallery.mount(opts)
	end
end

--- True when the local player may open the gallery: always in Studio,
--- otherwise only listed UserIds.
function Gallery.isAllowed(userId: number, allowed: { number }?, isStudio: boolean): boolean
	if isStudio then
		return true
	end
	return allowed ~= nil and table.find(allowed, userId) ~= nil
end

--- Registers /uigallery as a local TextChatCommand. Returns a disconnect fn.
function Gallery.bindChatCommand(opts: Options?): () -> ()
	local o: Options = opts or {}
	local players = game:GetService("Players")
	local runService = game:GetService("RunService")
	local textChat = game:GetService("TextChatService")
	local player = players.LocalPlayer
	if not Gallery.isAllowed(player.UserId, o.allowedUserIds, runService:IsStudio()) then
		return function() end
	end
	local command = Create.new("TextChatCommand", {
		Name = "UIGalleryCommand",
		PrimaryAlias = Gallery.COMMAND,
		Parent = textChat,
	})
	local conn = command.Triggered:Connect(function(source: TextSource)
		if source.UserId == player.UserId then
			Gallery.toggle(o)
		end
	end)
	return function()
		conn:Disconnect()
		command:Destroy()
	end
end

return Gallery
