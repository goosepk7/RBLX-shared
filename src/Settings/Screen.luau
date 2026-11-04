--!strict
--[[
	The Settings screen (§5.5): sliders, toggles and choices with instant feedback.

		Shared.Settings.Screen.register(screens, { client = settings, loc = loc })
		screens:push("Settings")      -- e.g. from the top-right gear

	One scrolling Panel, a header per section, one row per setting: label and hint on the left,
	the control on the right. Every change goes through the Settings client, so it applies the
	moment the player touches it. Choices are a button that steps to the next option. A section
	appears only if it has something to change (a `controls` choice with one option is hidden).
	The footer's primary action is Done; Restore defaults sits beside it as a Ghost button.
	Picking a colorblind palette rebuilds the screen so its own colors update too.
]]

local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Theme = require("../UI/Theme")
local Tokens = require("../UI/Tokens")

type Client = any -- Settings.Client (required lazily to avoid a cycle with init)
type Loc = any

export type Options = {
	client: Client,
	loc: Loc,
	onClose: (() -> ())?,
	size: UDim2?,
}

local Screen = {}

local CONTROL_W = 230
local SLIDER_W = 170
local VALUE_W = 56

local function sectionVisible(client: Client, section: string): boolean
	for _, def in client.schema.list do
		if def.section == section and (def.kind ~= "choice" or #def.options > 1) then
			return true
		end
	end
	return false
end

local function labelFor(loc: Loc, def: any): string
	return loc:t(def.label or ("settings." .. def.id))
end

local function optionLabel(loc: Loc, def: any, option: string): string
	local key = (def.label or ("settings." .. def.id)) .. "." .. option
	if loc:has(key) then
		return loc:t(key)
	end
	return option
end

local function percent(loc: Loc, def: any, value: number): string
	local t = (value - def.min) / (def.max - def.min)
	return loc:t("common.percent", { value = math.floor(t * 100 + 0.5) })
end

local function row(parent: Instance, order: number, loc: Loc, def: any): Frame
	local hasHint = def.hint ~= nil
	local height = if hasHint then Tokens.size.rowHeight + 14 else Tokens.size.rowHeight
	local frame = Create.new("Frame", {
		Name = "Row_" .. def.id,
		BackgroundColor3 = Theme.color("paper"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = order,
		Parent = parent,
	}, {
		Create.corner(Tokens.radius.button),
		Create.stroke("line", Tokens.border.card),
		Create.padding(0, Tokens.space.md),
	}) :: Frame
	local text = Create.group({
		Name = "Text",
		Size = UDim2.new(1, -(CONTROL_W + Tokens.space.md), 1, 0),
		Parent = frame,
	}, { Create.list("Vertical", Tokens.space.xxs, "Left", "Center") })
	Create.text({
		Name = "Label",
		Text = labelFor(loc, def),
		Role = "value",
		SizeName = "body",
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 1,
		Parent = text,
	})
	if hasHint then
		Create.text({
			Name = "Hint",
			Text = loc:t(def.hint),
			Role = "caption",
			SizeName = "caption",
			Color = "inkSoft",
			Wrapped = true,
			Size = UDim2.new(1, 0, 0, 30),
			LayoutOrder = 2,
			Parent = text,
		})
	end
	return frame
end

local function control(frame: Frame): Frame
	return Create.group({
		Name = "Control",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.new(0, CONTROL_W, 1, 0),
		Parent = frame,
	}, { Create.list("Horizontal", Tokens.space.sm, "Right", "Center") })
end

--- Builds the screen root (a Panel). Returns the root and a destroy function.
function Screen.build(options: Options): (Frame, () -> ())
	local client, loc = options.client, options.loc
	local conns: { { Disconnect: (any) -> () } } = {}
	local updaters: { [string]: (any) -> () } = {}

	local root, panel = Kit.Panel.new({
		Name = "Settings",
		Title = loc:t("settings.title"),
		Icon = "icon_settings",
		Scroll = true,
		Size = options.size or UDim2.new(0, 600, 1, -Tokens.space.lg * 2),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		OnClose = options.onClose,
	})
	Create.new("UISizeConstraint", { MaxSize = Vector2.new(600, 560), Parent = root })
	local body = panel.body
	Create.list("Vertical", Tokens.space.sm).Parent = body
	Create.padding(Tokens.space.lg, Tokens.space.lg).Parent = body

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	for _, section in { "audio", "comfort", "accessibility", "controls", "language", "game" } do
		if not sectionVisible(client, section) then
			continue
		end
		Create.text({
			Name = "Section_" .. section,
			Text = loc:t("settings.section." .. section),
			Role = "display",
			SizeName = "h3",
			Size = UDim2.new(1, 0, 0, 30),
			LayoutOrder = nextOrder(),
			Parent = body,
		})
		for _, def in client.schema.list do
			if def.section ~= section or (def.kind == "choice" and #def.options <= 1) then
				continue
			end
			local frame = row(body, nextOrder(), loc, def)
			local slot = control(frame)
			local id = def.id
			if def.kind == "toggle" then
				local _, toggle = Kit.Toggle.new({
					Value = client:get(id) :: boolean,
					Parent = slot,
					OnChanged = function(v: boolean)
						client:set(id, v)
					end,
				})
				updaters[id] = function(v: any)
					toggle.setValue(v, true)
				end
			elseif def.kind == "slider" then
				local valueLabel = Create.text({
					Name = "Value",
					Text = percent(loc, def, client:get(id) :: number),
					Role = "value",
					SizeName = "body",
					XAlign = "Right",
					Size = UDim2.new(0, VALUE_W, 1, 0),
					LayoutOrder = 2,
					Parent = slot,
				})
				local _, slider = Kit.Slider.new({
					Value = client:get(id) :: number,
					Min = def.min,
					Max = def.max,
					Step = def.step,
					Width = SLIDER_W,
					LayoutOrder = 1,
					Parent = slot,
					OnChanged = function(v: number)
						valueLabel.Text = percent(loc, def, v)
						client:set(id, v)
					end,
					OnCommitted = function()
						client:flush()
					end,
				})
				updaters[id] = function(v: any)
					slider.setValue(v, true)
					valueLabel.Text = percent(loc, def, v)
				end
			else
				local choices: { string } = def.options
				local _, button
				_, button = Kit.Button.new({
					Text = optionLabel(loc, def, client:get(id) :: string),
					Variant = "Secondary",
					Size = "Small",
					Width = CONTROL_W,
					Parent = slot,
					OnActivated = function()
						local current = table.find(choices, client:get(id) :: string) or 1
						client:set(id, choices[current % #choices + 1])
					end,
				})
				updaters[id] = function(v: any)
					button.setText(optionLabel(loc, def, v))
				end
			end
		end
	end

	Create.list("Horizontal", Tokens.space.md, "Right", "Center").Parent = panel.footer
	Create.padding(0, Tokens.space.lg).Parent = panel.footer
	Kit.Button.new({
		Text = loc:t("settings.reset"),
		Variant = "Ghost",
		Size = "Small",
		Width = 200,
		LayoutOrder = 1,
		Parent = panel.footer,
		OnActivated = function()
			client:reset()
			client:flush()
		end,
	})
	Kit.Button.new({
		Text = loc:t("settings.done"),
		Variant = "Primary",
		Width = 180,
		LayoutOrder = 2,
		Parent = panel.footer,
		OnActivated = function()
			client:flush()
			if options.onClose then
				options.onClose()
			end
		end,
	})

	table.insert(
		conns,
		client.Changed:Connect(function(id: string, value: any)
			local update = updaters[id]
			if update then
				update(value)
			end
		end)
	)

	local function destroy()
		for _, c in conns do
			c:Disconnect()
		end
		client:flush()
		panel.destroy()
	end
	return root, destroy
end

--- Registers the "Settings" screen (or `name`) on a ScreenManager. The screen rebuilds itself
--- when the language or colorblind palette changes, so its own text and colors follow.
function Screen.register(screens: any, options: { client: Client, loc: Loc, name: string? })
	local name = options.name or "Settings"
	screens:register(name, function(ctx: any)
		local holder = Create.group({ Name = "SettingsHolder" })
		local destroyCurrent: (() -> ())? = nil
		local function build()
			if destroyCurrent then
				destroyCurrent()
			end
			local root, destroy = Screen.build({ client = options.client, loc = options.loc, onClose = ctx.close })
			root.Parent = holder
			destroyCurrent = destroy
		end
		build()
		local unsubscribeLocale = options.loc:onLocaleChanged(function()
			build()
		end)
		local unsubscribePalette = Theme.onPaletteChanged(function()
			build()
		end)
		-- Covered by another screen: save what's pending. Popped: the holder is destroyed.
		holder.Destroying:Connect(function()
			unsubscribeLocale()
			unsubscribePalette()
			if destroyCurrent then
				destroyCurrent()
				destroyCurrent = nil
			end
		end)
		return {
			root = holder,
			onHide = function()
				options.client:flush()
			end,
		}
	end)
end

return Screen
