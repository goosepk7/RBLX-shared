--!strict
--[[
	Event lobby (brief §5.5): the event's name, a live countdown, who's in (and how many it
	needs), Join / Leave, and the results when it ends. `EventLobby.chip(env, parent)` is the
	HUD chip that shows the countdown everywhere and opens the lobby when tapped.

	State comes from the Events remotes: State (everyone, on every phase change) and Joined
	(this player). The countdown ticks locally from `endsAt`.
]]

local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Models = require("./Models")
local Parts = require("./Parts")
local Roblox = require("../Util/Roblox")
local ScreenManager = require("../UI/ScreenManager")
local Tokens = require("../UI/Tokens")

local EventLobby = {}

-- Tracks the event state on the client: the last State push plus this player's Joined flag.
export type Tracker = {
	get: () -> any,
	onChanged: (fn: (state: any) -> ()) -> () -> (),
	destroy: () -> (),
}

local trackers: { [any]: Tracker } = setmetatable({}, { __mode = "k" }) :: any

function EventLobby.tracker(env: Parts.Env): Tracker
	local existing = trackers[env]
	if existing then
		return existing
	end
	local remotes = env.remotes("Events")
	local state: any = { phase = "idle", participants = 0, minPlayers = 0, joined = false }
	local listeners: { (any) -> () } = {}
	local function emit()
		for _, fn in table.clone(listeners) do
			fn(state)
		end
	end
	local connections = {
		remotes.Finished:connect(function(outcome: any)
			if outcome.cancelled and table.find(outcome.participants or {}, env.userId) then
				Parts.toast(env, env.loc:t("events.cancelled"), "Warning", nil, "icon_event")
			end
		end),
		remotes.State:connect(function(next: any)
			local joined = state.joined and next.phase ~= "idle"
			state = table.clone(next)
			state.joined = joined
			emit()
		end),
		remotes.Joined:connect(function(joined: boolean)
			state = table.clone(state)
			state.joined = joined
			emit()
		end),
	}
	Parts.spawn(function()
		local result = remotes.GetState:invokeAsync()
		if result.ok and type(result.value) == "table" then
			state = result.value
			emit()
		end
	end)
	local tracker: Tracker = {
		get = function()
			return state
		end,
		onChanged = function(fn: (any) -> ()): () -> ()
			table.insert(listeners, fn)
			return function()
				local index = table.find(listeners, fn)
				if index then
					table.remove(listeners, index)
				end
			end
		end,
		destroy = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(listeners)
			trackers[env] = nil
		end,
	}
	trackers[env] = tracker
	return tracker
end

-- Calls `fn` about every second until the returned function is called.
local function ticker(fn: () -> ()): () -> ()
	local taskLib = Roblox.task()
	local running = true
	if taskLib then
		taskLib.spawn(function()
			while running do
				fn()
				taskLib.wait(1)
			end
		end)
	end
	return function()
		running = false
	end
end

local function playerNames(): { [number]: string }
	local names: { [number]: string } = {}
	local players = Roblox.isRoblox() and Roblox.service("Players")
	if players then
		for _, player in players:GetPlayers() do
			names[player.UserId] = player.DisplayName
		end
	end
	return names
end

function EventLobby.build(env: Parts.Env, ctx: ScreenManager.ScreenContext): ScreenManager.Screen
	local loc = env.loc
	local remotes = env.remotes("Events")
	local tracker = EventLobby.tracker(env)
	local root, panel = Parts.panel(ctx, loc:t("events.lobby"), "icon_event", { footer = true })
	local act: () -> ()
	local buttonRoot, button = Kit.Button.new({
		Text = loc:t("events.join"),
		Variant = "Primary",
		Width = 240,
		Disabled = true,
		Parent = panel.footer,
		OnActivated = function()
			act()
		end,
	})
	local current: Models.EventModel? = nil

	local name = Parts.text(panel.body, 1, "", { size = "h2", role = "display", align = "Center" })
	local status = Parts.text(panel.body, 2, "", { size = "h3", role = "number", align = "Center" })
	local players = Parts.text(panel.body, 3, "", { align = "Center" })
	local needs = Parts.text(panel.body, 4, "", { size = "caption", color = "inkSoft", align = "Center" })
	local joined = Parts.text(panel.body, 5, "", { color = "success", role = "button", align = "Center" })
	local results = Create.group({
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 6,
		Parent = panel.body,
	}, { Create.list("Vertical", Tokens.space.xs, "Center", "Top") })

	local function render()
		local model = Models.event(loc, tracker.get(), env.now(), env.events, playerNames())
		current = model
		name.Text = model.eventName or ""
		name.Visible = model.eventName ~= nil
		status.Text = model.status
		players.Text = model.players or ""
		players.Visible = model.players ~= nil
		needs.Text = model.needs or ""
		needs.Visible = model.needs ~= nil
		joined.Text = model.joinedText or ""
		joined.Visible = model.joinedText ~= nil
		Parts.clear(results)
		local placements: { string } = model.placements or {}
		for i, line in placements do
			Kit.ListRow.new({
				Title = line,
				Rank = i,
				Variant = if i <= 3 then ({ "Gold", "Silver", "Bronze" } :: { any })[i] else "Default",
				LayoutOrder = i,
				Parent = results,
			})
		end
		button.setText(model.actionLabel or loc:t("events.join"))
		button.setDisabled(model.action == "none")
	end

	function act()
		local model = current
		if model == nil or model.action == "none" then
			return
		end
		local remote = if model.action == "join" then remotes.Join else remotes.Leave
		Parts.call(env, "events", remote, nil, button, function(ok: boolean, value: any)
			if not ok then
				Parts.toast(env, value, "Danger")
			end
		end)
	end

	local unsubscribe = tracker.onChanged(render)
	local stopTicking = ticker(render)
	root.Destroying:Connect(function()
		unsubscribe()
		stopTicking()
	end)
	render()
	return { root = root, defaultFocus = buttonRoot }
end

--[[
	The chip's text, longest form first: "Stilt Race: Starts in 0:42", then the status alone
	("Starts in 0:42", or "Flash Flood starts in 0:42!" for a warning), then the countdown
	alone ("0:42"). Each form keeps the countdown, so dropping to a shorter one never loses it.
]]
function EventLobby.chipTexts(model: Models.EventModel): { string }
	local out: { string } = {}
	local function add(text: string?)
		if text and text ~= "" and not table.find(out, text) then
			table.insert(out, text)
		end
	end
	if model.eventName and (model.phase == "lobby" or model.phase == "running") then
		add(model.eventName .. ": " .. model.status)
	end
	add(model.status)
	if model.phase ~= "idle" then
		add(model.timeLeft)
	end
	return out
end

-- The narrowest chip (px at reference scale) the countdown is promised to fit, in every
-- locale, for anything under an hour left (tests/Screens/EventLobby.spec). Games give the
-- chip at least this much.
EventLobby.CHIP_MIN_WIDTH = 120

-- Index into `EventLobby.chipTexts(model)` of the longest form that fits a chip `maxWidth`
-- wide (px at reference scale, icon included), by estimated width. No cap: the full form.
function EventLobby.chipFit(model: Models.EventModel, maxWidth: number?): number
	local texts = EventLobby.chipTexts(model)
	if maxWidth == nil then
		return 1
	end
	local room = Kit.Chip.labelWidth(maxWidth, true, false)
	for i, text in texts do
		if Kit.Chip.textWidth(text) <= room then
			return i
		end
	end
	return #texts
end

-- The text the chip shows (see chipTexts / chipFit).
function EventLobby.chipText(model: Models.EventModel, maxWidth: number?): string
	local texts = EventLobby.chipTexts(model)
	return texts[math.min(EventLobby.chipFit(model, maxWidth), #texts)] or ""
end

--[[
	The HUD chip: "Race starts in 0:42" while a lobby or warning is open, the time left while one
	runs, hidden when idle. Tapping it opens the lobby screen. Returns a function that removes it.
	With `maxWidth` the text drops to a shorter form (name first, then the words) instead of
	truncating the countdown: picked by estimated width, then stepped down while Roblox reports
	the label doesn't fit (a font or translation wider than the estimate).
]]
function EventLobby.chip(env: Parts.Env, parent: Instance, maxWidth: number?): () -> ()
	local loc = env.loc
	local tracker = EventLobby.tracker(env)
	local chipRoot, chip = Kit.Chip.new({
		Text = "",
		Variant = "Warning",
		Icon = "icon_event",
		MaxWidth = maxWidth,
		Parent = parent,
		OnActivated = function()
			if env.manager:current() ~= "EventLobby" then
				env.manager:push("EventLobby")
			end
		end,
	})
	local label = chipRoot:FindFirstChild("Label", true)
	-- Extra steps down for this event + phase, from TextFits; reset when either changes.
	local fitKey: string? = nil
	local stepDown = 0
	local function model(): Models.EventModel
		return Models.event(loc, tracker.get(), env.now(), env.events)
	end
	local function render()
		local m = model()
		chipRoot.Visible = m.phase ~= "idle"
		local key = m.phase .. "|" .. (m.eventName or "")
		if key ~= fitKey then
			fitKey = key
			stepDown = 0
		end
		local texts = EventLobby.chipTexts(m)
		local index = math.min(EventLobby.chipFit(m, maxWidth) + stepDown, #texts)
		chip.setText(texts[index] or "")
	end
	local fitConnection: RBXScriptConnection? = nil
	if maxWidth and label and label:IsA("TextLabel") then
		fitConnection = label:GetPropertyChangedSignal("TextFits"):Connect(function()
			if label.TextFits or not chipRoot.Visible then
				return
			end
			local m = model()
			local texts = EventLobby.chipTexts(m)
			if EventLobby.chipFit(m, maxWidth) + stepDown < #texts then
				stepDown += 1
				render()
			end
		end)
	end
	local unsubscribe = tracker.onChanged(render)
	local stopTicking = ticker(render)
	render()
	return function()
		unsubscribe()
		stopTicking()
		if fitConnection then
			fitConnection:Disconnect()
		end
		chipRoot:Destroy()
	end
end

return EventLobby
