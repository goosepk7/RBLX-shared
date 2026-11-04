--!strict
--[[
	Stories: every kit component, every variant, plus Disabled and Loading
	states where the component supports them. The gallery (/uigallery)
	renders these; tests/UI/stories.spec.luau checks that every entry in a
	component's `Variants` list has a story here.

	Story text is sample content for the gallery only (owner-facing debug
	screen), so it is not routed through Loc.
]]

local Create = require("../Create")
local Kit = require("../Kit")

export type Env = {
	icon: (name: string) -> string, -- resolves an icon asset name to an image id
	overlay: () -> GuiObject, -- full-screen layer for modals, drawers, pops
	inputMode: () -> "Touch" | "Gamepad" | "Keyboard",
}

export type Variant = {
	name: string, -- matches an entry in the component's Variants, or a state name
	build: (env: Env) -> GuiObject,
}

export type Story = {
	component: string, -- key in Kit
	cell: { x: number, y: number }?, -- px per variant cell; default 260 x 150
	variants: { Variant },
}

local function frame(build: (Frame) -> ()): Frame
	local f = Create.group()
	build(f)
	return f
end

local function center(gui: GuiObject): GuiObject
	gui.AnchorPoint = Vector2.new(0.5, 0.5)
	gui.Position = UDim2.fromScale(0.5, 0.5)
	return gui
end

local function variantsOf(names: { any }, build: (name: string, env: Env) -> GuiObject): { Variant }
	local out: { Variant } = {}
	for _, name in names do
		table.insert(out, {
			name = name,
			build = function(env: Env)
				return build(name, env)
			end,
		})
	end
	return out
end

local function concat(a: { Variant }, b: { Variant }): { Variant }
	local out = table.clone(a)
	for _, v in b do
		table.insert(out, v)
	end
	return out
end

-- A Primary button that triggers a transient effect, used by stories for
-- components that only exist while animating.
local function trigger(text: string, fn: () -> ()): GuiObject
	local root = Kit.Button.new({ Text = text, Variant = "Secondary", Size = "Small", Width = 200, OnActivated = fn })
	return center(root)
end

local Stories: { Story } = {
	{
		component = "Button",
		variants = concat(
			variantsOf(Kit.Button.Variants, function(name, env)
				return center((Kit.Button.new({
					Text = name,
					Variant = name :: any,
					Icon = if name == "Gold" then env.icon("icon_gold") else nil,
				})))
			end),
			{
				{
					name = "Disabled",
					build = function()
						return center((Kit.Button.new({ Text = "Disabled", Disabled = true })))
					end,
				},
				{
					name = "Loading",
					build = function()
						return center((Kit.Button.new({ Text = "Loading", Loading = true })))
					end,
				},
				{
					name = "Small + icon",
					build = function(env)
						return center((Kit.Button.new({
							Text = "Claim",
							Size = "Small",
							Variant = "Success",
							Icon = env.icon("icon_check"),
						})))
					end,
				},
			}
		),
	},
	{
		component = "IconButton",
		cell = { x = 140, y = 120 },
		variants = concat(
			variantsOf(Kit.IconButton.Variants, function(name, env)
				return center((Kit.IconButton.new({
					Icon = env.icon("icon_shop"),
					Label = name,
					Variant = name :: any,
					Badge = if name == "Secondary" then 3 else nil,
				})))
			end),
			{
				{
					name = "Disabled",
					build = function(env)
						return center(
							(Kit.IconButton.new({ Icon = env.icon("icon_lock"), Label = "Locked", Disabled = true }))
						)
					end,
				},
				{
					name = "Loading",
					build = function(env)
						return center((Kit.IconButton.new({
							Icon = env.icon("icon_settings"),
							Label = "Loading",
							Loading = true,
						})))
					end,
				},
			}
		),
	},
	{
		component = "Chip",
		variants = concat(
			variantsOf(Kit.Chip.Variants, function(name, env)
				return center((Kit.Chip.new({
					Text = name,
					Variant = name :: any,
					Icon = if name == "Warning" then env.icon("icon_warning") else nil,
				})))
			end),
			{
				{
					name = "Prompt",
					build = function()
						return center(
							(Kit.Chip.new({ Text = "Enter Pit", KeyHint = "E", OnActivated = function() end }))
						)
					end,
				},
				{
					name = "Disabled",
					build = function()
						return center((Kit.Chip.new({ Text = "Disabled", Disabled = true })))
					end,
				},
			}
		),
	},
	{
		component = "Card",
		cell = { x = 260, y = 170 },
		variants = variantsOf(Kit.Card.Variants, function(name)
			local root, card = Kit.Card.new({ Variant = name :: any, Size = UDim2.fromOffset(220, 120) })
			Create.text({
				Text = name,
				Role = "display",
				SizeName = "h3",
				XAlign = "Center",
				Parent = card.content,
			})
			return center(root)
		end),
	},
	{
		component = "Panel",
		cell = { x = 400, y = 300 },
		variants = variantsOf(Kit.Panel.Variants, function(name, env)
			local root, panel = Kit.Panel.new({
				Title = name .. " Panel",
				Variant = name :: any,
				Icon = env.icon("icon_shop"),
				Size = UDim2.fromOffset(380, 280),
				OnClose = function() end,
			})
			Kit.ListRow.new({ Title = "Body content", Subtitle = "Rows, grids, cards", Parent = panel.body })
			Kit.Button.new({ Text = "Primary action", Fill = true, Parent = panel.footer })
			return center(root)
		end),
	},
	{
		component = "Modal",
		variants = variantsOf(Kit.Modal.Variants, function(name, env)
			return trigger("Open " .. name, function()
				local modal: any
				local root, panel = Kit.Panel.new({
					Title = name .. " Modal",
					Size = if name == "Fullscreen" then nil else UDim2.fromOffset(440, 280),
					OnClose = function()
						modal.close()
					end,
				})
				Kit.Button.new({
					Text = "Got it",
					Fill = true,
					Parent = panel.footer,
					OnActivated = function()
						modal.close()
					end,
				})
				modal = Kit.Modal.new({
					Content = root,
					Variant = name :: any,
					DismissOnBackdrop = true,
					OnClosed = function()
						modal.root:Destroy()
					end,
				})
				modal.open(env.overlay())
			end)
		end),
	},
	{
		component = "Drawer",
		variants = variantsOf(Kit.Drawer.Variants, function(name, env)
			return trigger("Open " .. name, function()
				local drawer = Kit.Drawer.new({ Title = name .. " Drawer", Variant = name :: any })
				for i = 1, 6 do
					Kit.ListRow.new({
						Title = "Part " .. i,
						Subtitle = "Steel bar · 4 studs",
						Icon = env.icon("icon_part"),
						Value = tostring(i * 25),
						LayoutOrder = i,
						Parent = drawer.body,
					})
				end
				drawer.open(env.overlay())
			end)
		end),
	},
	{
		component = "Confirm",
		variants = variantsOf(Kit.Confirm.Variants, function(name, env)
			return trigger("Confirm: " .. name, function()
				Kit.Confirm.show(env.overlay(), {
					Title = if name == "Destructive" then "Rebirth?" else "Are you sure?",
					Message = "Wins and worlds reset. You keep cosmetics, codes and medals, and earn +25% Wins forever.",
					ConfirmText = if name == "Destructive" then "REBIRTH" else "Confirm",
					CancelText = "Not yet",
					Variant = name :: any,
					OnResult = function() end,
				})
			end)
		end),
	},
	{
		component = "Tabs",
		cell = { x = 360, y = 120 },
		variants = concat(
			variantsOf(Kit.Tabs.Variants, function(name)
				return center(
					(Kit.Tabs.new({ Items = { "Boosts", "Cosmetics", "Passes" }, Variant = name :: any, Width = 330 }))
				)
			end),
			{
				{
					name = "Disabled",
					build = function()
						return center((Kit.Tabs.new({ Items = { "Daily", "All time" }, Disabled = true, Width = 330 })))
					end,
				},
			}
		),
	},
	{
		component = "ProgressBar",
		variants = variantsOf(Kit.ProgressBar.Variants, function(name)
			local root, bar = Kit.ProgressBar.new({
				Value = 0.35,
				Variant = name :: any,
				Segments = 5,
				Label = name,
				Height = 26,
				Width = 220,
			})
			-- Animate so the fill motion is visible in the gallery.
			task.delay(0.6, function()
				bar.setValue(0.8)
			end)
			return center(root)
		end),
	},
	{
		component = "Stat",
		variants = variantsOf(Kit.Stat.Variants, function(name, env)
			local root, stat = Kit.Stat.new({
				Label = "Lifetime Wins",
				Value = 120,
				Variant = name :: any,
				Icon = env.icon("icon_wins"),
				Width = 220,
			})
			task.delay(0.8, function()
				stat.setValue(1340)
			end)
			return center(root)
		end),
	},
	{
		component = "CurrencyPill",
		variants = concat(
			variantsOf(Kit.CurrencyPill.Variants, function(name, env)
				local root, pill = Kit.CurrencyPill.new({
					Icon = env.icon(if name == "Gold" then "icon_gold" else "icon_wins"),
					Value = 1200,
					Variant = name :: any,
					OnPlus = function() end,
				})
				task.delay(1, function()
					pill.setValue(1200 + (if name == "Default" then 15 else 400))
				end)
				return center(root)
			end),
			{
				{
					name = "No plus (Height)",
					build = function(env)
						return center(
							(Kit.CurrencyPill.new({ Icon = env.icon("icon_height"), Value = 51, Suffix = " st" }))
						)
					end,
				},
				{
					name = "Loading",
					build = function(env)
						return center(
							(Kit.CurrencyPill.new({ Icon = env.icon("icon_cash"), Value = 0, Loading = true }))
						)
					end,
				},
			}
		),
	},
	{
		component = "ListRow",
		cell = { x = 380, y = 110 },
		variants = variantsOf(Kit.ListRow.Variants, function(name, env)
			local ranks = { Default = 7, Pinned = 214, Gold = 1, Silver = 2, Bronze = 3 }
			local root = Kit.ListRow.new({
				Title = if name == "Pinned" then "You" else "Player" .. ranks[name],
				Subtitle = "51.0 studs",
				Rank = ranks[name],
				Icon = env.icon("icon_height"),
				Value = "1.2K",
				Variant = name :: any,
			})
			root.Size = UDim2.fromOffset(350, root.Size.Y.Offset)
			return center(root)
		end),
	},
	{
		component = "Grid",
		cell = { x = 400, y = 260 },
		variants = variantsOf(Kit.Grid.Variants, function(name, env)
			return frame(function(f)
				local root, grid = Kit.Grid.new({
					Variant = name :: any,
					MinCellWidth = 110,
					CellAspect = 1,
					Size = UDim2.fromOffset(380, 240),
				})
				local icons = { "icon_wins", "icon_cash", "icon_part", "icon_star", "icon_codes", "icon_event" }
				for i, iconName in icons do
					local card, cardHandle =
						Kit.Card.new({ Variant = if i == 1 then "Accent" else "Elevated", LayoutOrder = i })
					Create.new("ImageLabel", {
						BackgroundTransparency = 1,
						Image = env.icon(iconName),
						Size = UDim2.fromScale(1, 1),
						ScaleType = Enum.ScaleType.Fit,
						Parent = cardHandle.content,
					})
					card.Parent = grid.content
				end
				center(root).Parent = f
			end)
		end),
	},
	{
		component = "Tooltip",
		cell = { x = 200, y = 110 },
		variants = variantsOf(Kit.Tooltip.Variants, function(name)
			return center((Kit.Tooltip.new({ Text = "Leaderboards", Variant = name :: any })))
		end),
	},
	{
		component = "Toast",
		cell = { x = 380, y = 110 },
		variants = variantsOf(Kit.Toast.Variants, function(name, env)
			local icon = ({
				Success = "icon_check",
				Danger = "icon_warning",
				Info = "icon_codes",
				Warning = "icon_warning",
				Gold = "icon_gold",
				Badge = "icon_star",
			} :: { [string]: string })[name]
			local card = Kit.Toast.build({
				Title = if name == "Badge" then "Badge earned!" else nil,
				Text = if name == "Badge" then "First Steps" else name .. " toast",
				Variant = name :: any,
				Icon = env.icon(icon),
			})
			card.Size = UDim2.fromOffset(340, card.Size.Y.Offset + (if name == "Badge" then 12 else 0))
			return center(card)
		end),
	},
	{
		component = "Banner",
		cell = { x = 420, y = 100 },
		variants = variantsOf(Kit.Banner.Variants, function(name, env)
			return center(Kit.Banner.build({
				Text = if name == "Warning" then "FLASH FLOOD IN 10s!" else name:upper() .. " ANNOUNCEMENT",
				Variant = name :: any,
				Icon = env.icon("icon_event"),
			}))
		end),
	},
	{
		component = "NumberPop",
		variants = variantsOf(Kit.NumberPop.Variants, function(name)
			local holder: GuiObject
			holder = trigger("Pop " .. name, function()
				local amount = if name == "Loss" then -40 else 25
				Kit.NumberPop.spawn(holder, amount, { Before = 1000, Variant = name :: any })
			end)
			return holder
		end),
	},
	{
		component = "Confetti",
		variants = variantsOf(Kit.Confetti.Variants, function(name, env)
			local holder: GuiObject
			holder = trigger("Confetti " .. name, function()
				local p = holder.AbsolutePosition + holder.AbsoluteSize / 2
				Kit.Confetti.burst(env.overlay(), p, name :: any)
			end)
			return holder
		end),
	},
}

return Stories
