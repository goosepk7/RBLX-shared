# RBLXShared API

`local Shared = require(ReplicatedStorage.Packages.RBLXShared)`. Each module is also reachable
as `Shared.<Module>`. Sections are added by the thread that owns the module; keep each one to
the public surface, with one example.

Version: 0.1.0 (semver; a breaking change bumps both games in the same change set).

---

## AntiExploit

Server-side strike registry (brief §3.3). Net reports malformed payloads, wrong-direction traffic
and floods; game systems report implausible movement or timing. At 3 strikes (default) the
player is flagged for the Admin panel. A flag never takes anything from a player by itself.

| API | Notes |
|---|---|
| `AntiExploit.default()` | Process-wide registry, bound to `Players` in Roblox. Net's default server context reports here. |
| `AntiExploit.configureDefault(options)` | Set the default's options once at server start, before anything reports a strike. |
| `AntiExploit.newRegistry({ threshold?, onFlag?, kickMessage?, historySize?, recentSize?, strikeLimit?, now? })` | `threshold` 3; `onFlag` `"none"` (default) or `"kick"`; flag log keeps 100, recent strikes per player 10. `strikeLimit` (default 5 back to back, then one per 5 s per player) caps what one player can trigger: extra strikes still count toward the flag but aren't recorded or signalled. |
| `registry:strike(player, category, detail?)` | Returns the player's total. Net uses `net.malformed`, `net.wrongDirection`, `net.flood`; games use their own, e.g. `stilts.teleport`. |
| `registry:getRecord(player)` | `{ userId, name, strikes, suppressed, flagged, flaggedAt?, byCategory, recent }`, or nil. |
| `registry:isFlagged(player)`, `registry:getFlagged()` | The flag log (oldest first) outlives the player's session; the Admin panel lists it. |
| `registry.Flagged`, `registry.Struck` | Signals: `(player, FlagRecord)` once per session at the threshold; `(player, StrikeRecord)` on every recorded strike. |
| `registry:forget(player)`, `:bindPlayers(Players)`, `:clear()` | Live-record cleanup (`default()` already forgets players as they leave). |

```luau
local registry = Shared.AntiExploit.default()
registry.Flagged:Connect(function(player, flag)
	Shared.Util.Log.warn("AntiExploit", player.Name .. " flagged after " .. flag.strikes .. " strikes")
end)
registry:strike(player, "stilts.teleport", "moved 140 studs in 0.1 s")
```

---

## Assets

Manifest-backed asset lookup. Code never hardcodes an asset id.

| Function | Returns | Notes |
|---|---|---|
| `Assets.register(ids, owner?)` | | Merge a generated `AssetIds` table. Call once per game at startup. Duplicate names across owners error. RBLXShared's own ids are pre-registered. |
| `Assets.get(name)` | `string` | `"rbxassetid://<id>"` when uploaded, `""` while pending. |
| `Assets.ref(name)` | `AssetRef` | `{ name, kind, status, assetId?, uri, placeholder }` (same shape as `Types.AssetRef`). |
| `Assets.variant(name, size?)` | `string` | `"<name>_<size>"` if registered (e.g. `icon_wins_64`), else `name`. |
| `Assets.image(name, { size?, props? })` | `GuiObject` | `ImageLabel`, or a placeholder card (UI token color, by name hash) showing the name while pending. |
| `Assets.applyImage(imageLabel, name, size?)` | | Sets `Image`, or overlays the placeholder card. |
| `Assets.sound(name, props?)` | `Sound` | Silent while pending (warns once). Errors if the asset isn't audio. |
| `Assets.has / isPlaceholder / list / pending` | | Introspection for admin panels and checks. |
| `Assets.setStrict(bool)` | | Unknown names throw instead of warning once. |
| `Assets.reset()` / `Assets.clear()` | | Test helpers: back to only RBLXShared's ids, or to an empty registry. |

```luau
Assets.register(require(ReplicatedStorage.Stilts.AssetIds), "stilts")
local icon = Assets.image("icon_wins", { size = 64, props = { Size = UDim2.fromOffset(32, 32) } })
```

Generated module: `tools/gen_asset_ids.luau` writes `AssetIds.luau` from `assets/manifest.json`
(path per repo in `assets/config.json`). See [TOOLING.md](TOOLING.md) for the manifest format.

---

## Data

Session-locked player profiles (brief §3.2). One server owns a profile at a time; it is saved
every 60 s, on leave and on shutdown, and a failed load never looks like a new player. Each
player is one key, `Player_<userId>`, holding `{ data, meta }`.

| API | Notes |
|---|---|
| `Data.Store.new({ name, template, version?, migrations?, reconcile?, scope?, key?, kickMessages?, ... })` | `version` defaults to 1. `migrations[v]` turns version v - 1 data into v (change it in place, or return new data); every step from 2 to `version` is required. `template` must be storable; keys missing from loaded data are added unless `reconcile = false`. Timing options, in seconds: `autosaveInterval` 60, `forceReleaseTimeout` `autosaveInterval` + 30 (must be longer than `autosaveInterval`), `lockTimeout` 600 (must be longer than `forceReleaseTimeout`), `lockRetryInterval` 5, `receiptWait` 15. Services and clocks are injectable for tests: `dataStoreService`, `messagingService` (`false` turns pings off), `players`, `task`, `now`, `clock`, `decisions`, `bindToClose`. |
| `store:bindPlayers({ kick?, bindToClose? })` | Loads on join, releases on leave, flushes on BindToClose. Kicks with a friendly message when a load fails or another server takes the profile. |
| `store:loadAsync(player)` | `(profile?, err?)`. `err` is `"dataStore"`, `"locked"`, `"corrupt"`, `"migration"`, `"newerVersion"`, `"closing"` or `"left"`; nothing is written on failure. |
| `store:get(player)`, `:getByUserId(id)`, `:isLoaded(player)`, `:waitForProfileAsync(player, timeout?)` | `waitForProfileAsync` returns nil once the load fails, the player leaves or `timeout` passes. Without a timeout it waits out a load under way, however long the lock takes, and gives up with a warning if no load starts within 30 s. |
| `profile.data`, `profile.meta`, `profile.Released` | Change `data` freely while active; changes after release aren't saved. `Released` fires once with `"left"`, `"shutdown"`, `"forceReleased"`, `"lockLost"` or `"removed"`. |
| `profile:saveAsync()`, `:isActive()`, `:hasReceipt(purchaseId)` | Autosave and release already cover normal play. |
| `store:releaseAsync(player)`, `store:closeAsync(timeout?)` | A release that fails keeps the lock and retries every 10 s. `closeAsync` waits up to 25 s. |
| `store:processReceipt(receipt, grant)` | The `ProcessReceipt` body. `grant(profile, receipt)` changes `profile.data` and may return false to decline for now. It runs at most once per PurchaseId, and `PurchaseGranted` goes back only after the grant is saved. The last 100 PurchaseIds are kept per profile. |
| `store.Loaded`, `store.Released`, `store.ReceiptGranted` | `(player, profile)`, `(player?, profile, reason)`, `(player?, profile, receipt)`. Confirm purchases to the client and log them to analytics from `ReceiptGranted`. |
| `store:viewAsync(userId)`, `:updateOfflineAsync(userId, edit)`, `:removeAsync(userId)` | Support tools. An offline edit refuses while the player is online elsewhere; `removeAsync` erases the key (and kicks if loaded here). |
| `store:getDiagnostics()`, `Data.getDiagnostics()` | The DataDiagnostics view: counters, per-profile save times, sizes and last error, the 20 most recent errors, and DataStore request budgets (`budgets.UpdateAsync` is the one every load and save spends). |
| `Data.check(value, rootName?)`, `Data.estimateSize(value)` | `(ok, path?, reason?, size?)`: can a DataStore hold this exactly? Names the first bad path, e.g. `data.stats.speed: NaN`. |
| `Data.isRetryable(err)`, `Data.MAX_SIZE`, `Data.MAX_RECEIPTS` | |

Session locks: a lock whose heartbeat (each save) is older than `lockTimeout` belongs to a dead
server and is taken at once. A live owner is asked to release, through `meta` and a
MessagingService ping; it saves and hands over. An owner that missed the ping sees the request at
its next autosave, which always comes before `forceReleaseTimeout` runs out, so the lock is only
taken from a server that is gone or can't save. Every save checks ownership inside its
`UpdateAsync` transform, so a server that lost the lock never overwrites newer data. Data that
can't be stored as is (NaN, infinity, invalid UTF-8, mixed or sparse tables, non-string keys,
Roblox types, over 4 MB) is never written; the save fails with the path, and a release hands the
lock back over the last good save.

```luau
local Profiles = Shared.Data.Store.new({
	name = "Stilts_Profiles",
	version = 2,
	template = { wins = 0, coins = 0, settings = { music = true } },
	migrations = {
		[2] = function(data)
			data.coins = data.cash or 0
			data.cash = nil
		end,
	},
})
Profiles:bindPlayers()

MarketplaceService.ProcessReceipt = function(receipt)
	return Profiles:processReceipt(receipt, function(profile, r)
		return Products.grant(profile.data, r.ProductId)
	end)
end
Profiles.ReceiptGranted:Connect(function(player, _profile, receipt)
	Analytics.purchase(player, receipt)
end)

local profile = Profiles:get(player)
if profile then
	profile.data.wins += 1
end
```

Daily backups and one-player restores: `tools/backup_profiles`, see [TOOLING.md](TOOLING.md).

---

## Economy

Currencies, earning and spending with reasons, stacked multipliers, timed boosts, overflow-safe
balances and a ledger for analytics (brief §4). Server only; nothing yields. Each player's wallet
lives in their profile at `profile.data.wallet`, so it saves and locks with the profile.

| API | Notes |
|---|---|
| `Economy.new({ currencies, reasons?, multiplyWithin?, maxMultiplier?, walletField?, ledgerSize?, tickInterval?, ... })` | `currencies` are `Types.Currency` (whole numbers unless `integer = false`, optional `max`, `starting`, `leaderstat`, `icon`). `reasons` maps a name to its kind: `"earn"` (multiplied, counts toward lifetime), `"grant"` (exact and whole, never multiplied, no lifetime unless `{ kind = "grant", lifetime = true }`), `"spend"` or `"adjust"`. Defaults: `purchase`, `code`, `refund` are grants; `admin`, `rebirth` are adjustments. `maxMultiplier` 100, `ledgerSize` 50 per player, `tickInterval` 5 s. Injectable: `task`, `now`, `clock`, `players`, `createLeaderstat`. |
| `economy:bindStore(store)` | Attaches each profile as Data loads it, detaches it on release, and forgets a player's multipliers when they leave. `attach(who, data)` / `detach(who)` do it by hand (`who` is a Player or a UserId everywhere). |
| `economy:earn(who, currency, amount, reason)` | `(granted, failure?)`: what reached the balance after multipliers, the carried fraction and the cap. Integer currencies carry fractions to the next earn, so 2 Wins at 1.25x pays 2, then 3. At the cap the balance stops but `lifetime` and `allTime` still count the whole earning. |
| `economy:spend(who, currency, amount, reason)`, `:spendMany(who, { [currency] = amount }, reason)`, `:canAfford(...)` | `(ok, failure?)`. Never below zero. `spendMany` takes every cost or none, and its signals fire after all of them. |
| `economy:set(who, currency, value, reason, { lifetime? })` | An `adjust`: rebirth resets (`set(p, "Wins", 0, "rebirth", { lifetime = 0 })`) and admin tools. |
| `economy:balance(who, currency)`, `:lifetime(...)`, `:allTime(...)` | `lifetime` is since the last reset (gates, Stilts height); spending never lowers it. `allTime` never resets. |
| `economy:setMultiplier(who, id, spec?)`, `:clearMultipliers(who)`, `:setGlobalMultiplier(id, spec?)` | A `Types.MultiplierSpec`: `{ group, factor, currencies?, reasons?, expiresAt? }`. Sources in a group add their bonuses (2x and +25% make 2.25x); groups multiply (rebirth x pass x event x boost); groups in `multiplyWithin` multiply their own sources. Per-player sources can be set before the wallet loads. `nil` removes one. |
| `economy:multiplier(who, currency, reason)`, `:multiplierBreakdown(...)` | The total, and `(total, { [group] = factor })` for "2.25x from passes" UI. |
| `economy:addBoost(who, id, factor, seconds, currencies?)`, `:removeBoost(who, id)`, `:getBoosts(who)` | Boosts are saved in the wallet, sit in the `boost` group, and count down only while the player is in a server. Buying the same id again adds time. |
| `economy:getLedger(who, limit?)`, `:getTotals()`, `:getDiagnostics()` | The newest ledger entries (`Types.LedgerEntry`), server-wide sums per currency and reason, and the Admin panel view. |
| `economy.Changed`, `economy.Transaction`, `economy.BoostsChanged` | `(player?, userId, currency, balance, delta, reason)`, a copy of each ledger entry (for Analytics), `(player?, userId)`. |
| `Economy.attributeName(currency)`, `.lifetimeAttributeName(currency)`, `.boostAttributeName(id)`, `Economy.observe(player, currency, callback)` | Player attributes the client reads: `Currency_<id>`, `CurrencyLifetime_<id>`, and `Boost_<id>` (the unix time the boost ends). `observe` calls back now and on every change. |
| `Economy.Wallet`, `Economy.Multipliers`, `Economy.newWallet()`, `Economy.MAX_BALANCE` | The pure math, for sims and tests. Balances stop at 1e15. |

Failures: `"notLoaded"`, `"unknownCurrency"`, `"unknownReason"`, `"wrongReasonKind"`,
`"invalidAmount"` (logged as warnings, since they are bugs) and `"insufficient"` (normal play,
not logged). A failed call changes nothing.

```luau
local economy = Shared.Economy.new({
	currencies = {
		{ id = "Wins", displayName = "Wins", leaderstat = true, icon = "icon_wins" },
	},
	reasons = { challenge = "earn", event = "earn", shop = "spend" },
})
economy:bindStore(Profiles)

-- Passes, when ownership is known (before or after the profile loads).
economy:setMultiplier(player, "pass.2xWins", { group = "pass", factor = 2, currencies = { "Wins" } })
economy:setMultiplier(player, "pass.vip", { group = "pass", factor = 1.25 })
economy:setMultiplier(player, "pass.lucky", { group = "lucky", factor = 2, reasons = { "event" } })
economy:addBoost(player, "boost.2xWins", 2, 30 * 60) -- the 30-minute dev product

economy:earn(player, "Wins", 4, "challenge") -- 4 x 2.25 (passes) x 2 (boost) = 18
local ok, failure = economy:spend(player, "Wins", 50, "shop") -- false, "insufficient"

MarketplaceService.ProcessReceipt = function(receipt)
	return Profiles:processReceipt(receipt, function(profile, r)
		-- A Wins pack: exact, and it never raises lifetime Wins (height).
		return economy:earn(profile.userId, "Wins", 500, "purchase") > 0
	end)
end
```

---

## Loc

Every player-facing string goes through Loc (brief §3.1). A game declares one string table per
locale in code; Loc fills placeholders, picks plural forms, formats numbers for the locale and
falls back to the source locale. Pure; works under lune.

| API | Notes |
|---|---|
| `Loc.new({ tables, source?, locale? })` | `tables[locale][key]` is a string or a plural entry `{ one = ..., other = ... }`. `source` defaults to `"en"` and must have a table. |
| `loc:t(key, args?)` | `{name}` inserts `args.name` (numbers grouped: `1,234`, `1.234` in pt-br/es); `{name:compact}` (1.2K / 1,2K), `{name:grouped}`, `{name:raw}`. A plural entry with `args.count` picks its form. Missing in the locale: the source's text. Missing everywhere: the key itself, with one warning. |
| `loc:plural(key, count, args?)` | CLDR "one"/"other": en and es one = 1; pt-br one = 0 or 1. `{count}` is filled. |
| `loc:setLocale(id)`, `:getLocale()`, `:onLocaleChanged(fn)` | `setLocale` takes a Roblox `LocaleId` (`"pt-br"`, `"es-mx"`) and picks the closest table; returns it. `onLocaleChanged` returns an unsubscribe function. |
| `loc:number(n)`, `:compact(n)`, `:grouped(n)`, `loc:has(key)` | Locale-aware wrappers over `UI.Format`. |
| `Loc.normalize(localeId, available?)`, `Loc.pluralCategory(locale, n)`, `Loc.interpolate(text, args, locale?)`, `Loc.placeholders(text)` | The pure pieces. `Loc.SUPPORTED` is `{ "en", "pt-br", "es" }`. |
| `Loc.validate(tables, source?)` | Issues `{ locale, key, kind, detail? }` with kind `missing`, `extra`, `placeholders`, `pluralForms`, `badEntry`. Games assert it is empty (or only `missing` while translations are pending) in a spec. |
| `Loc.toCsv(tables, source?)` | Roblox localization-table CSV (Key, Source, Context, Example, one column per locale) for importing into the experience's cloud table. |

```luau
local loc = Shared.Loc.new({ tables = require(ReplicatedStorage.Stilts.Strings) })
loc:setLocale(Players.LocalPlayer.LocaleId)
title.Text = loc:t("win.title", { wins = 2 }) -- "+2 WINS"
```

---

## Net

Every remote in both games goes through Net (brief §3.3). Declare remotes once in a module both
sides require; each side only gets its own methods, and calling the other side's errors.

| Definition | Server side | Client side |
|---|---|---|
| `Net.clientEvent(schema, { rateLimit?, unreliable?, guard? })` | `:connect(fn(player, payload))` | `:fire(payload) -> boolean` (false when nothing was sent) |
| `Net.serverEvent(schema, { unreliable? })` | `:fire(player, payload)`, `:fireAll`, `:fireExcept(player, payload)`, `:fireList(players, payload)` | `:connect(fn(payload))` |
| `Net.clientFunction(request, response, { rateLimit?, guard?, timeout? })` | `:handle(fn(player, request) -> response)` | `:invokeAsync(request, timeout?)` returns `{ ok = true, value }` or `{ ok = false, error }` |

`Net.namespace(name, remotes, { context?, guard? })` names and binds a table of definitions and
returns it. On the server it creates `ReplicatedStorage.RBLXSharedNet.<Namespace>.<Remote>`, so
bind every namespace during server startup. `guard(player) -> boolean` is a precondition such as
"profile loaded"; failing it drops the message without a strike.

Every client-to-server message runs: kill switch → rate limit → argument count → schema → guard →
handlers. Malformed traffic (extra arguments, wrong type, range or enum) and messages sent the
wrong way are dropped, counted, and reported as strikes. Rate-limited messages are dropped and
counted; only a sustained flood (more than 10 × burst drops in 10 s) adds a `net.flood` strike.
Because the limit comes first, a flood of bad messages costs at most `burst` strikes plus one
flood strike per window; wrong-way traffic gets the default limit too. The default limit is
10/s with a burst of 20 per player per remote, and the client holds itself to the same limit. Handler errors are reported with a traceback, never swallowed. Invoke errors:
`"disabled"`, `"invalid"`, `"rate_limited"`, `"unauthorized"`, `"unavailable"`, `"error"`, `"timeout"`.

Schemas (`local S = Net.Schema`). Each is `{ check(value) -> (ok, reason?) }`; checks never error
and stop early on oversized input.

| Schema | Accepts |
|---|---|
| `S.number({ min?, max?, integer? })`, `S.integer({ min?, max? })` | Finite numbers in range. NaN and ±inf are always rejected. |
| `S.string({ minLength?, maxLength?, pattern? })` | Valid UTF-8, at most `maxLength` bytes (default 256). Anchor patterns yourself. |
| `S.boolean()`, `S.literal(v)`, `S.enum({ ... })` | `enum` takes strings, numbers or booleans. |
| `S.optional(s)`, `S.none()`, `S.any()` | `none` is a remote with no payload. Avoid `any` on client-to-server remotes. |
| `S.array(s, { minLength?, maxLength? })`, `S.map(k, v, { maxEntries? })` | Size limits default to 64. |
| `S.struct(fields, { allowExtra? })`, `S.union(a, b, ...)` | Undeclared struct keys are malformed unless `allowExtra`. |
| `S.vector3 / vector2 / cframe({ maxMagnitude? })`, `S.color3()`, `S.enumItem(Enum.X)`, `S.instance(className?, { descendantOf? })` | Finite components only; pass `descendantOf` for instances. |
| `S.custom(describe, fn)` | `fn(value) -> (ok, reason?)`. If `fn` errors, the error is reported and the value is rejected. |

Kill switch. Names are `"Ns.Remote"`, `"Ns.*"` or `"*"` (every inbound remote).

| API | Notes |
|---|---|
| `Net.setEnabled(name, enabled, reason?)`, `Net.setAllEnabled(enabled, reason?)`, `Net.isEnabled(name)` | This server only. |
| `Net.KillSwitch.new(options?)`, `:startAsync()` | Every server: loads the persisted state, listens for change pings, re-reads every 300 s. |
| `switch:setEnabledAsync(name, enabled, reason?)` | Persists (DataStore `RBLXShared`, key `Net.KillSwitch`, versioned), applies here, pings the rest over MessagingService. Returns `(ok, err?)`. |

Clients see a `Disabled` attribute on the remote and skip sending. `Net.getMetrics()` returns,
per remote, `{ received, accepted, sent, dropped = { malformed, rateLimited, disabled,
unauthorized, noHandler, wrongDirection }, handlerErrors, handlerSeconds, maxHandlerSeconds }`.

Tests and sims use `Net.Loopback.new()` (`.server`, `:connect(player)`, `:disconnect(player)`,
`:injectFromClient(player, "Ns.Remote", ...)` to act as a modified client) with
`Net.newContext({ side, transport, task?, strikes?, validateOutgoing?, defaultRateLimit? })`,
passed as `Net.namespace(name, remotes, { context = ctx })`. Server-to-client payloads are
checked against their schema in Studio and tests (`validateOutgoing`). The Studio smoke place
checks the Roblox transport and the loopback's argument rules against real remotes; see
[Studio smoke test for Net](TOOLING.md#studio-smoke-test-for-net).

```luau
-- ReplicatedStorage/Stilts/Remotes.luau
local Net = Shared.Net
local S = Net.Schema
return Net.namespace("Stilts", {
	Lunge = Net.clientEvent(S.number({ min = 0, max = 1 }), { rateLimit = { rate = 4, burst = 6 } }),
	BuyItem = Net.clientFunction(S.string({ maxLength = 32 }), S.boolean()),
	Banner = Net.serverEvent(S.string({ maxLength = 120 })),
})

-- Server
Remotes.Lunge:connect(function(player, charge) end) -- charge is a validated number in [0, 1]
Remotes.BuyItem:handle(function(player, itemId)
	return Shop.buy(player, itemId)
end)

-- Client
local result = Remotes.BuyItem:invokeAsync("skin_neon")
if not result.ok then
	warn(result.error)
end
```

---

## Signal

A pure-Luau event with the same surface as `RBXScriptSignal`, usable under lune.

| API | Notes |
|---|---|
| `Signal.new() :: Signal.Signal<A, B>` | Type the arguments where you create it. |
| `:Connect(fn)`, `:Once(fn)` | Return a `Connection` with `.Connected` and `:Disconnect()`. |
| `:Fire(...)` | Handlers run in connection order, each on its own thread. An erroring handler is reported with its traceback and the others still run. Connecting or disconnecting during `Fire` is safe. |
| `:Wait()` | Yields until the next `Fire` and returns its arguments. |
| `:DisconnectAll()`, `:Destroy()` | After `Destroy`, `Connect` returns a dead connection. |

```luau
local Changed = Shared.Signal.new() :: Shared.Signal.Signal<Player, number>
local connection = Changed:Connect(function(player, value) end)
Changed:Fire(player, 10)
connection:Disconnect()
```

---

## Sim

Pure-Luau harness for balance and gameplay simulations. No services, no real time, no
`math.random`.

| Module | Key API |
|---|---|
| `Sim.Rng` | `Rng.new(seed)`, `:next()` [0,1), `:int(a,b)`, `:range(a,b)`, `:chance(p)`, `:pick(list)`, `:weighted({[k]=w})`, `:shuffle(list)`, `:normal(mean, sd)`, `:exponential(mean)`, `:jitter(v, frac)`, `:fork(label)`, `:clone()`. Deterministic everywhere; golden-tested. |
| `Sim.Scheduler` | `Scheduler.new(start?)`, `:at(t, fn)`, `:after(dt, fn)`, `:every(dt, fn, { start?, count?, untilTime? })`, `:runUntil(t)`, `:runAll()`, `handle:cancel()`; `Scheduler.fixedStep(dt, duration, fn)`. |
| `Sim.Population` | `generate(rng, count, opts?)` (40/40/20 casual/average/grinder; 3/12/40-min sessions by default), `sessionsForDay(player, day)`, `play(players, { days, onDayStart? }, onSession)`, `mark(player, milestone, session, elapsed)`, `milestoneReport(players, names)`. |
| `Sim.Recorder` | `:row(series, row)`, `:set(name, v)`, `:add(name, n?)`, `:csv(series)`, `:json(pretty?)`. |
| `Sim.Stats` | `mean`, `stddev`, `percentile`, `median`, `summarize`, `histogram`, `shares`, `groupBy`. |
| `Sim.Targets` | `:check(name, value, { min?, max?, note? })`, `:passed()`, `:markdown()`. |
| `Sim.Tune` | `solve({ name, min, max, current, evaluate, target, step? })` finds the smallest in-bounds change that meets a target or reports that it can't; `grid`, `describe`. |
| `Sim.Runner` | `define({ name, seed?, params?, environment?, run(ctx) })`, `run(def, opts?)`, `runAll(defs, opts?, filter?)`, `serialize(summary)`, `entryPoints(defs)` returns `{ studio, openCloud }`. |
| `Sim.Json` | `encode(value, pretty?)` with sorted keys; `object(t)` forces `{}` for empty tables. |

A sim file (`sims/<area>/<name>.sim.luau`):

```luau
local Sim = require("@shared/Sim") -- in a game: the RBLXShared package path
return Sim.Runner.define({
	name = "stilts.first_win",
	seed = "stilts-first-win-v1",
	run = function(ctx)
		local players = Sim.Population.generate(ctx.rng, 500)
		Sim.Population.play(players, { days = 1 }, function(player, session)
			-- game model here; Sim.Population.mark(player, "firstWin", session, t)
		end)
		local row = Sim.Population.milestoneReport(players, { "firstWin" })[1]
		ctx.targets:check("first win, p50 seconds", row.playMinutes and row.playMinutes.p50 * 60, { max = 60 })
	end,
})
```

Run: `lune run sims [filter]` (writes `sims/out/<name>/`). In Studio, a ModuleScript that
returns `Sim.Runner.entryPoints({ require(...), ... })` gives `.studio()` for the command bar
and `.openCloud()` as the return value of an Open Cloud Luau Execution task.

---

## Test

Test runner and fakes, for lune (CI) and Studio.

| API | Notes |
|---|---|
| `T.describe(name, fn)`, `T.it(name, fn)`, `T.skip`, `T.only` | Register at require time. A committed `T.only` fails CI. |
| `T.beforeEach / afterEach / beforeAll / afterAll` | `afterEach` always runs, innermost first. |
| `T.expect(v)` | `toBe`, `toEqual` (deep, reports the differing path), `toBeNear(x, eps?)`, `toBeTruthy`, `toBeFalsy`, `toBeNil`, `toBeType`, `toBeGreaterThan(OrEqual)`, `toBeLessThan(OrEqual)`, `toContain`, `toHaveLength`, `toMatch`, `toThrow(substring?)`; `.never` negates. |
| `T.run({ filter?, quiet?, onCase? })` | Returns `{ ok, passed, failed, skipped, failures, cases }`. The lune entry is `lune run tests [filter]`. |
| `T.Clock.new({ start? })` | Virtual time: `:now()` (unix s), `:clock()` (monotonic), `:advance(s)`, `:advanceTo(t)`, `:flush()`, `:pending()`, `.task` (`wait/spawn/defer/delay/cancel` emulating Roblox `task`), `:deps()` returns `{ now, clock, wait }`. |
| `T.Fakes.DataStoreService.new()` | `GetDataStore`, `GetOrderedDataStore` (sorted pages), `GetRequestBudgetForRequestType`. Values deep-copied and checked as serializable; errors as `"502: ..."`. `UpdateAsync` reruns `transform` when the key changes between read and commit (like Roblox). Controls: `failNext(method, { code?, times?, key?, store? })`, `setFailureRate(p, seed?)`, `setBeforeCommit(fn({ store, scope, key, attempt }))` (write the key from another "server" here to force a session-lock race), `enableBudgets({ players?, initial?, burstMinutes? })` / `setBudget(n)` (budgets spend per request type, refill with `setNow` time, and throw `30x` throttle errors at 0; unlimited until enabled), `setNow`, `newSetOptions`, `inspect`, `seed` (bypasses budgets and hooks), `versionOf`, `calls`, `reset`. |
| `T.Fakes.MarketplaceService.new()` | `ProcessReceipt` driving: `purchaseProduct(player, id, { purchaseId? })`, `replay(receipt)`, `retryPending()`, `pending()`; passes: `grantPass`, `revokePass`, `UserOwnsGamePassAsync`, `completeGamePassPrompt`, `failOwnershipChecks(n)`; `prompts()`, `grantedCount()`. Decision values in `.Decision`. |
| `T.Fakes.Players.new()` | `join(spec)` / `leave(player)` fire `PlayerAdded` / `PlayerRemoving`; fake players support `Kick` (removes from server), attributes with change signals. |
| `T.Signal.new()` | Synchronous signal (`Connect`, `Once`, `Fire`, `DisconnectAll`). |

Under lune, `game`, `task` and `Enum` do not exist and cannot be injected, so modules take
services, `task` and enum values as constructor dependencies (see CONTRIBUTING.md).


---

## Types

Shared Luau types, defined once in `src/Types/init.luau` (fields are documented there). Requiring
the module costs nothing. Changing a field is a breaking change.

| Types | Used by |
|---|---|
| `UserId`, `CurrencyId` | Everything |
| `Currency`, `CurrencyState`, `BoostState`, `Wallet`, `MultiplierSpec`, `LedgerEntry` | Economy; the wallet lives at `profile.data.wallet` |
| `SessionLock`, `ReceiptRecord`, `ProfileMeta`, `PlayerProfile<T>` | Data |
| `StageResult` | Produced by game systems; consumed by Progression and Leaderboards (v0.2) |
| `PurchaseReceipt` | `ProcessReceipt`'s `receiptInfo`, typed |
| `AssetKind`, `AssetStatus`, `AssetRef` | Assets |

```luau
type StageResult = Shared.Types.StageResult
```

---

## Util

Helpers the framework uses, exposed for games. Anything not listed here may change.

| API | Notes |
|---|---|
| `Util.Log.info / warn / error(scope, message)` | `error` shows red in Output without stopping the thread. Framework code reports here rather than swallowing errors. |
| `Util.Log.capture()` | Returns `(entries, restore)` so tests can assert on reports. |
| `Util.Log.setSink(fn?)` | Route reports elsewhere (nil restores normal output). |
| `Util.Deep.copy / freeze / equal / isArray` | Plain-data helpers. `copy` keeps cycles and drops metatables. |
| `Util.Roblox.isRoblox / isStudio / side / service / task / jobId / placeId / guid / bindToClose` | Lazy Roblox access, so modules stay requirable under lune. |

```luau
local template = Shared.Util.Deep.copy(Config.defaultData)
```

---

## World

Static geometry as plain data (brief §8). Hubs, worlds and stage chunks are `Spec` trees of
numbers, strings and booleans, so a layout is reproducible, diffable and testable under lune.
The same tree builds at runtime and as a byte-stable `.rbxmx` for Rojo's `Workspace`.

| API | Notes |
|---|---|
| `World.Spec` | `{ name, className?, size?, position?, rotation?, shape?, color?, material?, transparency?, reflectance?, anchored?, canCollide?, canTouch?, canQuery?, castShadow?, attributes?, tags?, properties?, primary?, children? }`. `className` defaults to `Part`; also `WedgePart`, `CornerWedgePart`, `TrussPart`, `SpawnLocation`, `Seat`, `Model`, `Folder`. Vectors are `{ x, y, z }`; `rotation` is degrees in Roblox's Orientation order (Y, X, Z). `color` is `#RRGGBB`, `material` an `Enum.Material` name, `shape` `Block`/`Ball`/`Cylinder`/`Wedge`/`CornerWedge`. Parts are anchored unless `anchored = false`, and every face is smooth. `primary` names a Model's PrimaryPart child. `properties` sets other simple properties (`SpawnLocation.Duration`). |
| `World.validate(spec)` | Every problem as `"Hub.Plinth3: size must be positive"`; empty when buildable. Sibling names must be unique. |
| `World.instantiate(spec, env?)` | Builds the tree; errors with every problem if invalid. `env` is `{ Instance, Vector3, CFrame, Color3, Enum }`, defaulting to the Roblox globals (read at call time). Attributes, properties and tags apply in sorted order. |
| `World.stats(spec)`, `World.countParts(spec)`, `World.extents(part)` | `{ parts, instances, min, max }`: counts for the §3.1 budgets and world-axis bounds with rotation included. |
| `World.group(name, children, extra?)`, `World.translate(spec, offset)`, `World.rotateY(spec, degrees, pivot?)`, `World.copy(spec)` | Composition; each returns a new tree. `rotateY` turns positions and orientation together, rounded to 1e-4 studs so layouts stay stable. |
| `World.each(spec, fn(node, path))`, `World.findTagged(spec, tag)` | Walk the tree; for layout tests ("8 plinths"). |

Generator tools (lune) write the model with `tools/lib/model.luau`; in a game repo require it
through an alias for `Packages/RBLXShared/tools`:

```luau
-- tools/build_hub.luau in a game repo: `lune run tools/build_hub [--check]`
local process = require("@lune/process")
local Model = require("@sharedtools/lib/model")
local HubLayout = require("@car/HubLayout")
Model.run(HubLayout.build(), "src/Workspace/Hub.rbxmx", process.args, "lune run tools/build_hub")
```

`Model.render(spec)` returns the XML, `Model.write(spec, path, { check? })` writes or compares,
`Model.run` prints PASS/FAIL with the part count and exits 1 on drift (for CI), and
`Model.env()` is the lune `env` for `World.instantiate`.
