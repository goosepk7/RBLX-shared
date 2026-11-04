--!strict
--[[
	Daily Rewards screen (brief §5.5): the 7-day strip (claimed, today, upcoming), the streak,
	and one Claim button. Opens by itself when the server says today's claim is open
	(Screens.install wires Daily.Available).
]]

local Common = require("../UI/Kit/Common")
local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Models = require("./Models")
local Parts = require("./Parts")
local ScreenManager = require("../UI/ScreenManager")
local Tokens = require("../UI/Tokens")

local DailyScreen = {}

local CARD_VARIANT: { [string]: any } = { claimed = "Inset", today = "Accent", upcoming = "Plain" }

function DailyScreen.build(env: Parts.Env, ctx: ScreenManager.ScreenContext): ScreenManager.Screen
	local loc = env.loc
	local remotes = env.remotes("Daily")
	local root, panel = Parts.panel(ctx, loc:t("daily.title"), "icon_star", { variant = "Gold", footer = true })
	local claim: () -> ()
	local buttonRoot, button = Kit.Button.new({
		Text = loc:t("daily.claim"),
		Variant = "Gold",
		Width = 260,
		Disabled = true,
		Parent = panel.footer,
		OnActivated = function()
			claim()
		end,
	})

	local function render(status: any)
		Parts.clear(panel.body)
		if status == nil then
			Parts.text(panel.body, 1, loc:t("common.loading"), { color = "inkSoft", align = "Center" })
			return
		end
		local model = Models.daily(loc, status, env.now(), env.catalog)
		local order = Parts.counter()
		Parts.text(panel.body, order(), model.streak, { size = "h3", role = "display", align = "Center" })
		if model.broken then
			Parts.text(panel.body, order(), model.broken, { size = "caption", color = "warning", align = "Center" })
		end
		local _, strip = Kit.Grid.new({
			Variant = "Static",
			MinCellWidth = 96,
			CellAspect = 1.3,
			LayoutOrder = order(),
			Parent = panel.body,
		})
		for index, day in model.days do
			local _, card = Kit.Card.new({
				Variant = CARD_VARIANT[day.state],
				Disabled = day.state == "claimed",
				Size = UDim2.fromScale(1, 1),
				Padding = Tokens.space.sm,
				LayoutOrder = index,
				Parent = strip.content,
			})
			Create.list("Vertical", Tokens.space.xs, "Center", "Top").Parent = card.content
			Parts.text(card.content, 1, day.label, { size = "caption", role = "button", align = "Center" })
			Common.icon(if day.state == "claimed" then "icon_check" else (day.icon or "icon_star"), {
				Size = UDim2.fromOffset(Tokens.size.iconMd, Tokens.size.iconMd),
				LayoutOrder = 2,
				Parent = card.content,
			}, 64)
			for i, line in day.lines do
				Parts.text(card.content, 2 + i, line, { size = "caption", align = "Center" })
			end
		end
		if model.nextIn then
			Parts.text(panel.body, order(), model.nextIn, { size = "caption", color = "inkSoft", align = "Center" })
		end
		button.setText(model.buttonLabel)
		button.setDisabled(not model.canClaim)
	end

	function claim()
		Parts.call(env, "daily", remotes.Claim, nil, button, function(ok: boolean, value: any)
			if ok then
				local lines = Models.rewardLines(loc, value.applied, env.catalog)
				Parts.toast(env, table.concat(lines, ", "), "Gold", loc:t("daily.title"), "icon_star")
				render(value.status)
			else
				Parts.toast(env, value, "Danger")
			end
		end)
	end

	render(ctx.params and ctx.params.status)
	Parts.spawn(function()
		local result = remotes.Status:invokeAsync()
		if result.ok and result.value then
			render(result.value)
		end
	end)
	return { root = root, defaultFocus = buttonRoot }
end

return DailyScreen
