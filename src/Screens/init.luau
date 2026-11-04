--!strict
--[[
	Screens: the shared screens from brief §5.5, built from the UI kit and driven by the v0.2
	remotes. Client only. One call registers them and wires the pushes:

	  local Shared = require(ReplicatedStorage.Packages.RBLXShared)
	  local loc = Shared.Loc.new({ tables = Shared.Loc.merge(Shared.Strings, require(Strings)) })
	  local area = Shared.UI.SafeArea.new()
	  local screens = Shared.UI.ScreenManager.new(area)
	  local env = Shared.Screens.install({
	  	loc = loc, manager = screens, area = area,
	  	catalog = { items = Config.Items, passes = Config.Passes, products = Config.Products,
	  		currencyIcons = { Wins = "icon_wins" } },
	  	boards = Config.Boards, events = Config.EventsById, badges = Config.BadgesByKey,
	  })
	  screens:push("Shop", { tab = "passes" })
	  Shared.Screens.Purchase.request(env, "product", "Boost2x30")

	Registered screens: Shop, Rebirth, Codes, Leaderboards, Daily, EventLobby. The overlays
	(Tutorial, the event chip, leaderboard walls) are started by the game where it wants them.
	Pushes wired by install: badge toasts (Earned, Announced), the rebirth banner, purchase
	confirmations, and opening Daily when today's claim is ready (`autoOpenDaily`, default true).

	What each screen shows is decided by Screens.Models (pure, tested). The screens' own strings
	are in Shared.Strings (areas shop, rebirth, codes, leaderboards, daily, events, badges,
	tutorial, rewards, time, errors). Content names come from the game's tables:

		currency.<Id>     "Wins"               bonus.<name>   rebirth bonus, "Wins multiplier"
		item.<id>         (or the def's nameKey) board.<id>   (or nameKey)
		pass.<key>        (or nameKey)         event.<id>     (or nameKey)
		product.<key>     (or nameKey)         badge.<key>    (or nameKey; .description too)
		boost.<id>        "2x Wins"            fail.<reason>  a game's own refusal reason
]]

local Codes = require("@self/Codes")
local Daily = require("@self/Daily")
local EventLobby = require("@self/EventLobby")
local Leaderboards = require("@self/Leaderboards")
local Loc = require("./Loc")
local Models = require("@self/Models")
local Net = require("./Net")
local Parts = require("@self/Parts")
local Purchase = require("@self/Purchase")
local Rebirth = require("@self/Rebirth")
local Remotes = require("./Remotes")
local Roblox = require("./Util/Roblox")
local SafeArea = require("./UI/SafeArea")
local ScreenManager = require("./UI/ScreenManager")
local Shop = require("@self/Shop")
local Tutorial = require("@self/Tutorial")

export type Env = Parts.Env

export type InstallOptions = {
	loc: Loc.Loc,
	manager: ScreenManager.ScreenManager,
	area: SafeArea.SafeArea,
	catalog: Models.Catalog?,
	boards: { any }?,
	events: { [string]: any }?,
	badges: { [string]: any }?,
	balances: (() -> { [string]: number })?,
	-- Net context the client remotes bind to (tests). Default: Net's client context.
	context: Net.Context?,
	userId: number?,
	now: (() -> number)?,
	autoOpenDaily: boolean?,
	-- Which pushes to wire. Default: all of them.
	toasts: { badges: boolean?, rebirths: boolean?, purchases: boolean? }?,
}

local Screens = {
	Codes = Codes,
	Daily = Daily,
	EventLobby = EventLobby,
	Leaderboards = Leaderboards,
	Models = Models,
	Parts = Parts,
	Purchase = Purchase,
	Rebirth = Rebirth,
	Shop = Shop,
	Tutorial = Tutorial,
}

Screens.NAMES = table.freeze({ "Shop", "Rebirth", "Codes", "Leaderboards", "Daily", "EventLobby" })

local BUILDERS: { [string]: (Env, ScreenManager.ScreenContext) -> ScreenManager.Screen } = {
	Shop = Shop.build,
	Rebirth = Rebirth.build,
	Codes = Codes.build,
	Leaderboards = Leaderboards.build,
	Daily = Daily.build,
	EventLobby = EventLobby.build,
}

-- The Env the screens share, from install options (no screens registered).
function Screens.env(options: InstallOptions): Env
	local localUserId = options.userId
	if localUserId == nil and Roblox.isRoblox() then
		local player = Roblox.service("Players").LocalPlayer
		localUserId = if player then player.UserId else 0
	end
	local context = options.context
	return {
		loc = options.loc,
		manager = options.manager,
		area = options.area,
		catalog = options.catalog or {},
		userId = localUserId or 0,
		now = options.now or os.time,
		remotes = function(module: string): any
			return Remotes.client(module, context)
		end,
		balances = options.balances,
		boards = options.boards,
		events = options.events,
		badges = options.badges,
	}
end

--[[
	Registers the shared screens on `options.manager` and wires the pushes. Returns the Env, which
	Purchase.request, Tutorial.start, EventLobby.chip and Leaderboards.surface take.
]]
function Screens.install(options: InstallOptions): Env
	local env = Screens.env(options)
	for _, name in Screens.NAMES do
		local build = BUILDERS[name]
		env.manager:register(name, function(ctx: ScreenManager.ScreenContext)
			return build(env, ctx)
		end)
	end
	local toasts: { badges: boolean?, rebirths: boolean?, purchases: boolean? } = options.toasts or {}
	if toasts.badges ~= false then
		local badges = env.remotes("Badges")
		local function show(payload: any)
			local toast = Models.badgeToast(env.loc, env.badges, payload, env.userId)
			env.area.toasts.show({ Title = toast.title, Text = toast.text, Icon = toast.icon, Variant = "Badge" })
		end
		badges.Earned:connect(show)
		badges.Announced:connect(function(payload: any)
			-- The earner already got their own toast from Earned.
			if payload.userId ~= env.userId then
				show(payload)
			end
		end)
	end
	if toasts.rebirths ~= false then
		env.remotes("Rebirth").Rebirthed:connect(function(payload: any)
			if payload.userId ~= env.userId then
				env.area.banners.show({
					Text = env.loc:t("rebirth.banner", { name = payload.name or "", count = payload.count }),
					Variant = "Gold",
					Icon = "icon_rebirth",
				})
			end
		end)
	end
	if toasts.purchases ~= false then
		env.remotes("Shop").Confirmed:connect(function(payload: any)
			Purchase.confirmed(env, payload)
		end)
	end
	if options.autoOpenDaily ~= false then
		env.remotes("Daily").Available:connect(function(status: any)
			if env.manager:current() == nil then
				env.manager:push("Daily", { status = status })
			end
		end)
	end
	return env
end

return Screens
