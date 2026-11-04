--!strict
--[[
	Leaderboards screen (brief §5.5): a tab per board, the top entries with medal rows for 1-3,
	and your own rank pinned at the bottom. Boards come from `env.boards` (the same defs the
	server's Leaderboards.new got) and `params.board` picks the opening tab. The open board
	refreshes when the server says its top changed.

	Leaderboards.surface(env, part, boardId) draws one board on a SurfaceGui for the lobby wall.
]]

local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Models = require("./Models")
local Parts = require("./Parts")
local ScreenManager = require("../UI/ScreenManager")
local Tokens = require("../UI/Tokens")

local LeaderboardsScreen = {}

local function rows(parent: Instance, model: Models.BoardModel, startOrder: number): number
	local order = startOrder
	if model.empty then
		Parts.text(parent, order, model.empty, { color = "inkSoft", align = "Center" })
		return order + 1
	end
	for _, row in model.rows do
		Kit.ListRow.new({
			Title = row.title,
			Subtitle = row.subtitle,
			Rank = row.rank,
			Value = row.value,
			Variant = row.variant,
			LayoutOrder = order,
			Parent = parent,
		})
		order += 1
	end
	return order
end

function LeaderboardsScreen.build(env: Parts.Env, ctx: ScreenManager.ScreenContext): ScreenManager.Screen
	local loc = env.loc
	local remotes = env.remotes("Leaderboards")
	local boards: { any } = env.boards or {}
	local params = ctx.params or {}
	local root, panel = Parts.panel(ctx, loc:t("leaderboards.title"), "icon_leaderboard", { footer = true })
	panel.footer:ClearAllChildren()
	Create.padding(Tokens.space.sm, Tokens.space.lg, Tokens.space.sm, Tokens.space.lg).Parent = panel.footer

	local selected = 1
	for i, def in boards do
		if def.id == params.board then
			selected = i
		end
	end
	local list = Create.group({
		Name = "Entries",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = panel.body,
	}, { Create.list("Vertical", Tokens.space.xs, "Center", "Top") })

	local generation = 0
	local function load()
		generation += 1
		local mine = generation
		local def = boards[selected]
		Parts.clear(list)
		Parts.clear(panel.footer)
		if def == nil then
			return
		end
		Parts.text(list, 1, loc:t("common.loading"), { color = "inkSoft", align = "Center" })
		Parts.spawn(function()
			local result = remotes.Get:invokeAsync(def.id)
			if mine ~= generation then
				return
			end
			Parts.clear(list)
			local model = Models.leaderboard(loc, def, if result.ok then result.value else nil, env.now(), env.userId)
			local order = 1
			if model.resetsIn then
				Parts.text(list, order, model.resetsIn, { size = "caption", color = "inkSoft", align = "Center" })
				order += 1
			end
			rows(list, model, order)
			Kit.ListRow.new({
				Title = model.you.title,
				Subtitle = model.you.subtitle,
				Rank = model.you.rank,
				Value = model.you.value,
				Variant = "Pinned",
				Parent = panel.footer,
			})
		end)
	end

	local labels: { string } = {}
	for _, def in boards do
		table.insert(labels, Models.label(loc, { def.nameKey, "board." .. def.id }, def.id))
	end
	local tabsRoot = Kit.Tabs.new({
		Items = labels,
		Selected = selected,
		LayoutOrder = 1,
		Parent = panel.body,
		OnChanged = function(index: number)
			selected = index
			load()
		end,
	})

	local connection = remotes.Updated:connect(function(boardId: string)
		local def = boards[selected]
		if def and def.id == boardId then
			load()
		end
	end)
	root.Destroying:Connect(function()
		connection:Disconnect()
	end)
	load()
	return { root = root, defaultFocus = tabsRoot }
end

--[[
	A physical board: the top of `boardId` on a SurfaceGui on `part`'s front face, refreshed
	whenever the server says it changed. Returns a function that stops it.
]]
function LeaderboardsScreen.surface(env: Parts.Env, part: BasePart, boardId: string): () -> ()
	local loc = env.loc
	local remotes = env.remotes("Leaderboards")
	local def = Models.find(env.boards, "id", boardId) or { id = boardId }
	local gui = Create.new("SurfaceGui", {
		Name = "Leaderboard_" .. boardId,
		Face = Enum.NormalId.Front,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 40,
		LightInfluence = 0,
		Adornee = part,
		Parent = part,
	})
	local _, panel = Kit.Panel.new({
		Title = Models.label(loc, { def.nameKey, "board." .. boardId }, boardId),
		Icon = "icon_leaderboard",
		Variant = "Gold",
		FooterHeight = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	local generation = 0
	local function load()
		generation += 1
		local mine = generation
		Parts.spawn(function()
			local result = remotes.Get:invokeAsync(boardId)
			if mine ~= generation then
				return
			end
			Parts.clear(panel.body)
			rows(
				panel.body,
				Models.leaderboard(loc, def, if result.ok then result.value else nil, env.now(), env.userId),
				1
			)
		end)
	end
	local connection = remotes.Updated:connect(function(id: string)
		if id == boardId then
			load()
		end
	end)
	load()
	return function()
		connection:Disconnect()
		gui:Destroy()
	end
end

return LeaderboardsScreen
