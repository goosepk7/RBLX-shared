--!strict
--[[
	The Admin panel (§3.3, §5.5), client side, in the shared theme.

		Shared.Admin.Client.new({ screens = screens, loc = loc, area = area })

	Opens when the owner types "/admin" (the server sends Open) or calls `admin.open()`. Tabs:
	Players (strikes, flags, inspect), Data (any player's profile, live or saved, and the
	DataDiagnostics view), Flags (AntiExploit log), Analytics (recent events), Sims (run one
	on this server) and Console (type any command; the audit log of every admin command).
	Everything comes from the server's Query/Run remotes, which only answer owners.
]]

local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Theme = require("../UI/Theme")
local Tokens = require("../UI/Tokens")

export type Options = {
	screens: any, -- UI.ScreenManager
	loc: any,
	area: any?, -- UI.SafeArea, for toasts with command replies
	remotes: any, -- Admin.remotes() on the client
	name: string?, -- screen name, default "Admin"
}

export type Client = {
	open: () -> (),
	destroy: () -> (),
}

local Panel = {}

local TABS = { "players", "data", "flags", "analytics", "sims", "console" }

--- Flattens a profile document into sorted "path = value" pairs for the inspector.
function Panel.flatten(value: any, limit: number?): { { path: string, value: string } }
	local out: { { path: string, value: string } } = {}
	local max = limit or 300
	local function walk(v: any, path: string)
		if #out >= max then
			return
		end
		if type(v) == "table" then
			local keys: { string } = {}
			for k in v do
				table.insert(keys, tostring(k))
			end
			table.sort(keys)
			if #keys == 0 then
				table.insert(out, { path = path, value = "{}" })
			end
			for _, k in keys do
				local child = v[k]
				if child == nil then
					child = v[tonumber(k) :: any]
				end
				walk(child, if path == "" then k else path .. "." .. k)
			end
		else
			table.insert(out, { path = path, value = tostring(v) })
		end
	end
	walk(value, "")
	return out
end

local function clear(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function Panel.client(options: Options): Client
	local loc, screens, remotes = options.loc, options.screens, options.remotes
	local name = options.name or "Admin"
	local conns: { any } = {}

	local function toast(ok: boolean, text: string)
		if options.area then
			options.area.toasts.show({ Text = string.sub(text, 1, 300), Variant = if ok then "Success" else "Danger" })
		end
	end

	local function query(view: string, arg: any): any
		local result = remotes.Query:invokeAsync({ view = view, arg = arg })
		if not result.ok then
			toast(false, loc:t("admin.failed"))
			return nil
		end
		return result.value
	end

	local function runLine(line: string): (boolean, string)
		local result = remotes.Run:invokeAsync(line)
		if not result.ok then
			return false, loc:t("admin.failed")
		end
		return result.value.ok, result.value.message
	end

	screens:register(name, function(ctx: any)
		local root, panel = Kit.Panel.new({
			Name = "AdminPanel",
			Title = loc:t("admin.title"),
			Icon = "icon_settings",
			Variant = "Secondary",
			Size = UDim2.new(0, 760, 1, -Tokens.space.lg * 2),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			FooterHeight = 0,
			OnClose = ctx.close,
		})
		Create.new("UISizeConstraint", { MaxSize = Vector2.new(760, 600), Parent = root })
		local body = panel.body
		Create.padding(Tokens.space.md, Tokens.space.lg).Parent = body

		local labels = {}
		for _, tab in TABS do
			table.insert(labels, loc:t("admin.tab." .. tab))
		end
		local toolbar = Create.group({
			Name = "Toolbar",
			Size = UDim2.new(1, 0, 0, Tokens.size.buttonHeightSmall + Tokens.edge.button),
			Position = UDim2.fromOffset(0, Tokens.size.tabHeight + Tokens.space.xs * 2 + Tokens.space.sm),
			Visible = false,
			Parent = body,
		}, { Create.list("Horizontal", Tokens.space.sm, "Left", "Center") })
		local listTop = Tokens.size.tabHeight + Tokens.space.xs * 2 + Tokens.space.sm
		local list = Create.new("ScrollingFrame", {
			Name = "List",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, listTop),
			Size = UDim2.new(1, 0, 1, -listTop),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.color("lineDark"),
			Parent = body,
		}, { Create.list("Vertical", Tokens.space.sm) }) :: ScrollingFrame

		local current = "players"
		local inspectArg: any = nil

		local function setToolbar(visible: boolean)
			toolbar.Visible = visible
			clear(toolbar)
			local top = listTop
				+ (if visible then Tokens.size.buttonHeightSmall + Tokens.edge.button + Tokens.space.sm else 0)
			list.Position = UDim2.fromOffset(0, top)
			list.Size = UDim2.new(1, 0, 1, -top)
		end

		local function row(order: number, title: string, subtitle: string?, value: string?, variant: string?): any
			local _, handle = Kit.ListRow.new({
				Title = title,
				Subtitle = subtitle,
				Value = value,
				Variant = (variant or "Default") :: any,
				LayoutOrder = order,
				Parent = list,
			})
			return handle
		end

		local function empty()
			row(1, loc:t("admin.empty"))
		end

		local render: (string) -> ()

		local function inputBar(placeholder: string, buttonText: string, onSubmit: (string) -> ()): any
			setToolbar(true)
			local _, input = Kit.TextInput.new({
				Placeholder = placeholder,
				Width = 480,
				MaxLength = 200,
				LayoutOrder = 1,
				Parent = toolbar,
				OnSubmit = onSubmit,
			})
			Kit.Button.new({
				Text = buttonText,
				Variant = "Primary",
				Size = "Small",
				Width = 160,
				LayoutOrder = 2,
				Parent = toolbar,
				OnActivated = function()
					onSubmit(input.getText())
				end,
			})
			return input
		end

		local views: { [string]: () -> () } = {}

		views.players = function()
			setToolbar(false)
			local players = query("players", nil) or {}
			if #players == 0 then
				empty()
			end
			for i, p in players do
				local handle = row(
					i,
					p.displayName,
					loc:t("admin.player.subtitle", { name = p.name, userId = p.userId, strikes = p.strikes }),
					if p.flagged
						then loc:t("admin.player.flagged")
						elseif not p.loaded then loc:t("admin.player.loading")
						else nil,
					if p.flagged then "Pinned" else nil
				)
				Kit.Button.new({
					Text = loc:t("admin.inspect"),
					Variant = "Secondary",
					Size = "Small",
					Width = 136,
					Parent = handle.trailing,
					OnActivated = function()
						inspectArg = p.userId
						render("data")
					end,
				})
			end
		end

		views.data = function()
			inputBar(loc:t("admin.lookup"), loc:t("admin.inspect"), function(text: string)
				inspectArg = if text == "" then nil else (tonumber(text) or text)
				render("data")
			end)
			local order = 0
			local function add(title: string, value: string?, variant: string?)
				order += 1
				row(order, title, nil, value, variant)
			end
			if inspectArg ~= nil then
				local result = query("inspect", inspectArg)
				if result == nil then
					return
				end
				if result.error then
					add(result.error, nil, "Pinned")
					return
				end
				add(loc:t("admin.data.source." .. result.source), tostring(result.userId), "Pinned")
				for _, pair in Panel.flatten(result.document) do
					add(pair.path, pair.value)
				end
			else
				local result = query("diagnostics", nil) or {}
				add(loc:t("admin.data.diagnostics"), nil, "Pinned")
				for _, pair in Panel.flatten(result, 200) do
					add(pair.path, pair.value)
				end
			end
		end

		views.flags = function()
			setToolbar(false)
			local flags = query("flags", nil) or {}
			if #flags == 0 then
				empty()
			end
			for i = #flags, 1, -1 do
				local f = flags[i]
				local reasons = {}
				for _, r in f.reasons or {} do
					table.insert(reasons, r.category)
				end
				row(
					#flags - i + 1,
					f.name,
					loc:t("admin.flag.subtitle", {
						strikes = f.strikes,
						reasons = table.concat(reasons, ", "),
					}),
					tostring(f.userId),
					"Pinned"
				)
			end
		end

		views.analytics = function()
			setToolbar(false)
			local events = query("analytics", nil) or {}
			if #events == 0 then
				empty()
			end
			for i, e in events do
				local detail = e.kind .. " · " .. tostring(e.userId)
				if e.stepName or e.levelName then
					detail ..= " · " .. tostring(e.stepName or e.levelName)
				end
				row(i, e.name, detail, if e.value ~= nil then tostring(e.value) else e.status)
			end
		end

		views.sims = function()
			setToolbar(false)
			local sims = query("sims", nil) or {}
			if #sims == 0 then
				empty()
			end
			for i, s in sims do
				local handle = row(i, s.name, s.description)
				local _, button
				_, button = Kit.Button.new({
					Text = loc:t("admin.run"),
					Variant = "Primary",
					Size = "Small",
					Width = 136,
					Parent = handle.trailing,
					OnActivated = function()
						button.setLoading(true)
						local ok, message = runLine("sim " .. s.name)
						button.setLoading(false)
						handle.setValue(loc:t(if ok then "admin.sim.passed" else "admin.sim.failed"))
						toast(ok, message)
					end,
				})
			end
		end

		views.console = function()
			local input
			input = inputBar(loc:t("admin.command"), loc:t("admin.run"), function(text: string)
				if text == "" then
					return
				end
				input.setLoading(true)
				local ok, message = runLine(text)
				input.setLoading(false)
				input.setVariant(if ok then "Success" else "Danger", string.sub(message, 1, 200))
				toast(ok, message)
				render("console")
			end)
			local audit = query("audit", nil) or {}
			for i, entry in audit do
				row(
					i,
					entry.line,
					entry.name .. " · " .. string.sub(entry.message, 1, 120),
					nil,
					if entry.ok then nil else "Pinned"
				)
			end
		end

		render = function(tab: string)
			current = tab
			clear(list)
			task.spawn(views[tab])
		end

		Kit.Tabs.new({
			Items = labels,
			Variant = "Secondary",
			Parent = body,
			OnChanged = function(index: number)
				if TABS[index] ~= "data" then
					inspectArg = nil
				end
				render(TABS[index])
			end,
		})

		render(current)
		return { root = root }
	end)

	local function open()
		if screens:current() ~= name then
			screens:push(name)
		end
	end

	table.insert(conns, remotes.Open:connect(open))
	table.insert(
		conns,
		remotes.Reply:connect(function(reply: { ok: boolean, message: string })
			toast(reply.ok, reply.message)
		end)
	)

	return {
		open = open,
		destroy = function()
			for _, c in conns do
				if type(c) == "table" and c.Disconnect then
					c:Disconnect()
				end
			end
		end,
	}
end

return Panel
