--!strict
--[[
	Rebirth screen (brief §5.5): what resets (red) and what's kept (green), every bonus before
	and after, the next milestone reward, progress toward the requirements, and the big red
	confirm. The button asks once more (Confirm, Destructive) before calling Rebirth; the
	server checks the requirements again.
]]

local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Models = require("./Models")
local Parts = require("./Parts")
local ScreenManager = require("../UI/ScreenManager")
local Tokens = require("../UI/Tokens")

local RebirthScreen = {}

local function section(parent: Instance, order: number, title: string, lines: { string }, color: any)
	local _, card = Kit.Card.new({ Variant = "Inset", AutoHeight = true, LayoutOrder = order, Parent = parent })
	Create.list("Vertical", Tokens.space.xs, "Left", "Top").Parent = card.content
	Parts.text(card.content, 1, title, { size = "h3", role = "display", color = color })
	for i, line in lines do
		Parts.text(card.content, i + 1, line)
	end
end

function RebirthScreen.build(env: Parts.Env, ctx: ScreenManager.ScreenContext): ScreenManager.Screen
	local loc = env.loc
	local remotes = env.remotes("Rebirth")
	local root, panel = Parts.panel(ctx, loc:t("rebirth.title"), "icon_rebirth", { variant = "Danger", footer = true })
	local body = panel.body
	local perform: () -> ()
	local confirmRoot, confirm = Kit.Button.new({
		Text = loc:t("rebirth.confirm"),
		Variant = "Danger",
		Width = 280,
		Disabled = true,
		Parent = panel.footer,
		OnActivated = function()
			perform()
		end,
	})
	local model: Models.RebirthModel? = nil

	local function render(preview: any)
		Parts.clear(body)
		if preview == nil then
			Parts.text(body, 1, loc:t("common.loading"), { color = "inkSoft", align = "Center" })
			confirm.setDisabled(true)
			return
		end
		local m = Models.rebirth(loc, preview, env.catalog)
		model = m
		local order = Parts.counter()
		Parts.text(body, order(), m.count, { size = "h3", role = "display", align = "Center" })
		Kit.ProgressBar.new({
			Value = m.progress,
			Variant = if m.canRebirth then "Success" else "Danger",
			Label = m.progressText,
			LayoutOrder = order(),
			Parent = body,
		})
		for _, line in m.parts do
			Parts.text(body, order(), line, { size = "caption", color = "inkSoft", align = "Center" })
		end
		local columns = Parts.stack(body, order(), "Horizontal", Tokens.space.md)
		for _, child in { 1, 2 } do
			local half = Create.group({
				Size = UDim2.new(0.5, -Tokens.space.md / 2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = child,
				Parent = columns,
			})
			if child == 1 then
				section(half, 1, loc:t("rebirth.lose"), m.lose, "danger")
			else
				section(half, 1, loc:t("rebirth.keep"), m.keep, "success")
			end
		end
		if #m.bonuses > 0 then
			local lines: { string } = {}
			for _, bonus in m.bonuses do
				table.insert(lines, bonus.line)
			end
			section(body, order(), m.bonusesTitle, lines, "ink")
		end
		if m.milestoneTitle then
			section(body, order(), m.milestoneTitle :: string, m.milestone, "gold")
		end
		confirm.setDisabled(not m.canRebirth)
	end

	local function refresh()
		Parts.spawn(function()
			local result = remotes.Preview:invokeAsync()
			render(if result.ok then result.value else nil)
		end)
	end

	local function rebirthNow()
		Parts.call(env, "rebirth", remotes.Rebirth, nil, confirm, function(ok: boolean, value: any)
			if ok then
				local count = if value.summary then value.summary.count else 0
				Parts.toast(env, loc:t("rebirth.done", { count = count }), "Gold", nil, "icon_rebirth")
				ctx.close()
			else
				Parts.toast(env, value, "Danger")
				refresh()
			end
		end)
	end

	function perform()
		local m = model
		if m == nil or not m.canRebirth then
			return
		end
		local modal: any = nil
		local content = Kit.Confirm.build({
			Title = m.confirmTitle,
			Message = m.confirmMessage,
			ConfirmText = m.confirmLabel,
			CancelText = loc:t("common.cancel"),
			Variant = "Destructive",
			Icon = "icon_rebirth",
			OnResult = function() end,
		}, function(confirmed: boolean)
			if modal == nil then
				return
			end
			modal.close()
			modal = nil
			if confirmed then
				rebirthNow()
			end
		end)
		modal = env.manager:showModal(content, { DismissOnBackdrop = false })
	end

	render(nil)
	refresh()
	return { root = root, defaultFocus = confirmRoot }
end

return RebirthScreen
