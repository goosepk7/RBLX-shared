# RBLXShared API

`local Shared = require(ReplicatedStorage.Packages.RBLXShared)`. Each module is also reachable
as `Shared.<Module>`. Sections are added by the thread that owns the module; keep each one to
the public surface, with one example.

Version: 0.2.0 (semver; a breaking change bumps both games in the same change set).

---

## Admin

Owner-only tools (brief §3.3, §5.5): chat commands, a data inspector, the AntiExploit flag log,
the analytics feed, a sim launcher and an audit log. Everything runs on the server and checks the
caller's UserId; a non-owner calling the admin remotes is dropped with an `admin.unauthorized`
strike. Command replies are English (owner-only text, not localized).

| API | Notes |
|---|---|
| `Admin.Server.new({ owners, allowStudio?, store?, economy?, analytics?, antiExploit?, sims?, teleport?, players?, context?, chatCommands?, now?, isStudio? })` | `owners` is a list of UserIds. Studio test sessions are allowed unless `allowStudio = false`. `chatCommands` (default on in Roblox) adds the `/admin` TextChatCommand: alone it opens the panel, with text it runs a command and replies in a toast. |
| `admin:register({ name, description, args?, run })` | `args` is a list of `{ name, type, optional?, options? }` with type `player` (`me`, a UserId, an exact name or a unique prefix), `number`, `integer`, `string`, `currency`, `choice` or `rest`. `run(ctx, args)` returns `(ok, message?)`; errors are caught. |
| `admin:run(caller, line)`, `admin:isOwner(player)` | Every line, allowed or not, goes into the audit log (last 100); `admin.CommandRan` fires per line. |
| `admin:query(caller, view, arg?)`, `admin:getAudit(limit?)`, `admin:commands()` | Views (`Admin.VIEWS`): `players`, `inspect` (live profile, else the saved one), `diagnostics`, `flags`, `analytics`, `audit`, `commands`, `sims`. Results go through `Admin.snapshot` so they fit on the wire. |
| `Admin.Client.new({ screens, loc, area?, remotes?, context?, name? })` | Registers the `"Admin"` screen (tabs Players, Data, Flags, Analytics, Sims, Console) and opens it when the server says so. Returns `{ open, destroy }`. |
| `Admin.parse(line)`, `Admin.usage(command)`, `Admin.findPlayer(list, word, caller)`, `Admin.snapshot(value, maxDepth?, maxEntries?)`, `Admin.Panel.flatten(value, limit?)` | Pure helpers, tested under lune. |

Built-in commands: `help`, `grant <player> <currency> <amount>` (negative takes; never below 0;
reason `admin`), `reset <player> confirm` (erases the save and kicks), `kick <player> [reason]`,
`tp <player> <target>` (the game's `teleport` hook, else to another player), `sim <name>` and
`remote on|off` (the Net kill switch on this server).

```luau
local admin = Shared.Admin.Server.new({ owners = { 123456 }, store = Profiles, economy = economy, analytics = analytics })
admin:register({
    name = "flood", description = "Start the flood event",
    args = { { name = "minutes", type = "integer", optional = true } },
    run = function(ctx, args) Events.start("flood", args.minutes or 5) return true, "flood started" end,
})
```

---

## Analytics

Funnel and economy events for Roblox Analytics (brief §4), plus a ring buffer for the Admin
panel. Server only; calls never yield. Events queue and a background loop sends them every 5 s
within Roblox's budget (120 + 20 per player per minute). A full queue (1000) drops the oldest economy event first, then the oldest custom one, and funnel, onboarding and progression events last; a purchase granted by the release save is counted on the next load (from the profile's receipts);
send errors are counted in diagnostics and reported (first three, then every 100th).

| API | Notes |
|---|---|
| `Analytics.new({ sink?, enabled?, field?, bufferSize?, queueLimit?, flushInterval?, budgetBase?, budgetPerPlayer?, transactionTypes?, players?, task?, now?, clock? })` | `sink(player, event)` defaults to `Analytics.RobloxSink.new()` (AnalyticsService). `enabled = false` keeps the ring buffer but sends nothing. `field` is the profile key, default `"analytics"`. |
| `analytics:bindStore(store)` | Per profile: `join` (value = session number, field `new`), `session_length` (seconds, field `reason`) on release, and `purchase` (Robux spent, field `product`) plus `first_purchase` from `ReceiptGranted`, so a purchase is logged once even across a crash. Play time is written into the profile every flush and on leave. |
| `analytics:bindEconomy(economy)` | `Transaction` entries become economy events: delta > 0 is a source, < 0 a sink, the reason is the item SKU. Transaction types: `purchase` IAP, `earn` Gameplay, `spend` Shop, `grant` Gameplay; `adjust` reasons (admin, rebirth) are skipped unless mapped in `transactionTypes`. |
| `analytics:track(who, name, value?, fields?)` | A custom event. Names are 1-50 of `[%w_.-]`, so a typo can't open a new dashboard per stage. Up to 3 fields, sent in sorted key order as CustomField01..03. |
| `analytics:first(who, milestone, fields?)` | `first_<milestone>` once per player ever, value = seconds played so far (time to first win). Returns whether it logged. `hasFirst` checks. |
| `analytics:onboarding(who, step, stepName, fields?)` | Roblox's onboarding funnel; each step once per player, in increasing order (returns false otherwise). The tutorial calls it as steps complete. |
| `analytics:progression(who, path, "start" \| "complete" \| "fail", level, levelName?, fields?)` | Stage attempts and fails. |
| `analytics:funnel(who, funnel, step, stepName?, sessionId?, fields?)`, `analytics:economy(who, flow, currency, amount, balance, transactionType, sku?)` | The remaining AnalyticsService event kinds. |
| `analytics:getState(who)`, `:playSeconds(who)` | `{ firstJoinAt, sessions, playSeconds, onboardingStep, purchases, robuxSpent, firsts }` from the profile. |
| `analytics:getRecent(limit?, userId?)`, `:getDiagnostics()`, `analytics.Logged` | Newest first. Diagnostics: `enabled, queued, sent, failed, dropped, byKind, lastError, sessions, budgetPerMinute`. `Logged` fires per event. |
| `analytics:flush()`, `:setEnabled(on)`, `:destroy()` | `flush` sends what the budget allows now (release already does). |

```luau
local analytics = Shared.Analytics.new()
analytics:bindStore(Profiles)
analytics:bindEconomy(economy)

-- In the challenge system:
analytics:progression(player, "World1", "start", challenge.index, challenge.id)
if won then
	analytics:progression(player, "World1", "complete", challenge.index, challenge.id)
	analytics:first(player, "win")
end
```

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

## Audio

Client-side sound (brief §4, §5.7). Sounds are named definitions over manifest assets; each
category ("music", "sfx", "ui", "ambient") is a SoundGroup at category x master volume.

| API | Notes |
|---|---|
| `Audio.new({ parent?, sounds?, volumes?, createInstance?, task?, random?, assets?, fadeStep? })` | `parent` defaults to SoundService. `sounds` is merged over `Audio.DEFAULT_SOUNDS`. Default volumes: master 1, music 0.6, sfx 0.8, ui 0.8, ambient 0.7. |
| `audio:define(name, { asset, category?, volume?, variants?, pitchJitter?, maxInstances?, looped? })` | `variants = n` plays `<asset>_1` .. `_n` at random, never the same one twice in a row. `maxInstances` (default 4) pooled copies may overlap; past that the oldest restarts. |
| `audio:play(name, { volume?, pitch? }?)` | 2D, pooled. Returns the Sound, or nil while the asset is pending upload (counted as `silent`) or the name is unknown (warns once). |
| `audio:playAt(name, partOrAttachment, options?)` | Positional one-shot parented to the target; destroys itself when it ends (10 s fallback). |
| `audio:playMusic(name, { fade?, volume? }?)`, `:stopMusic(fade?)`, `:currentMusic()` | Crossfade between two decks (default 1.5 s). A music name with no definition plays that manifest asset, looped, at 0.5. The same track again is a no-op. |
| `audio:setVolume(name, 0..1)`, `:getVolume(name)` | `name` is a category or `"master"`. Settings drives these. |
| `audio:bindKit()` | Registers with `UI.Hooks`, so kit events play `ui.<sound>`. Returns an unbind function. |
| `audio:getDiagnostics()`, `:destroy()` | `{ pools, instances, plays, silent, stolen, music, volumes }`. |

Default definitions (assets from `tools/sfx_gen.py`): `ui.click` (4 variations), `ui.hover` (3),
`ui.open`, `ui.close`, `ui.tab`, `ui.toast`, `ui.pop` (3), `ui.success`, `ui.fail`, `ui.thump`,
and the feedback set `fx.purchase`, `fx.win`, `fx.checkpoint`, `fx.unlock`, `fx.fail`.

```luau
local audio = Shared.Audio.new()
audio:bindKit()
audio:define("stilts.footfall_wood", { asset = "sfx_stilts_wood", variants = 4, pitchJitter = 0.06 })
audio:playAt("stilts.footfall_wood", foot)
audio:playMusic("music_world1")
```

---

## Badges

Award-once badges with deferred Roblox delivery (brief §4, §5.5). Server only. Each player's
state lives at `profile.data.badges` (`{ earned, awarded }`, key -> os.time()).

| API | Notes |
|---|---|
| `Badges.new({ badges, field?, retries?, retryDelay?, badgeService?, players?, task?, now? })` | `badges` are `{ key, id, nameKey?, descriptionKey?, icon?, announce? }`. `id = 0` means not created on Roblox yet. |
| `badges:bindStore(store)`, `:attach(who, data)`, `:detach(who)`, `:isAttached(who)` | Same contract as Economy. Attaching retries delivery of anything earned but not yet awarded. |
| `badges:award(who, key)` | `true` only the first time. Fires `Earned`, then delivers in the background. |
| `badges:has(who, key)`, `:badge(key)`, `:badges()`, `:deliverAsync(player)` | `deliverAsync` calls `AwardBadge` (3 tries), falling back to `UserHasBadgeAsync`; a badge whose id is still 0 waits for a later join. |
| `badges.Earned`, `badges.Delivered` | `(player?, userId, def)`. |
| `badges:bindNet(context?)` | Remotes `SharedBadges`: `Earned` to the player `{ key }`, `Announced` to everyone `{ key, userId, name }` when `announce` is set. |

```luau
local badges = Shared.Badges.new({ badges = { { key = "Rebirth1", id = 0, icon = "icon_rebirth", announce = true } } })
badges:bindStore(Profiles)
badges:bindNet()
rebirth.Rebirthed:Connect(function(player, _, summary)
	if summary.count == 1 then badges:award(player, "Rebirth1") end
end)

---

## Codes

Redeemable codes from config or added at runtime (Admin), with start/expiry, a global use
limit, one redemption per player and wrong-guess lockout (brief §4, §11). Server only.
Redemptions are saved at `profile.data.codes`.

| API | Notes |
|---|---|
| `Codes.new({ economy, shop?, codes?, reason?, field?, storeName?, key?, refreshInterval?, missRefreshAge?, maxFailures?, failureWindow?, lockoutSeconds?, dataStoreService?, messagingService?, task?, now?, clock?, players? })` | `codes` are `{ code, reward, startsAt?, expiresAt?, maxUses?, requires?(who) -> (ok, failure?), disabled?, note? }`. Defaults: reason `"code"` (declare it as a grant), refresh 120 s, lockout after 8 wrong tries in 600 s for 300 s. `dataStoreService = false` turns runtime codes and use limits off. Invalid config throws. |
| `codes:bindStore(store)`, `:attach`, `:detach`, `:isAttached` | As Economy. |
| `codes:start()` | Loads runtime codes, refreshes on a timer and on a MessagingService ping (`RBLXShared.Codes`). |
| `codes:redeemAsync(who, text)` | `(ok, failure?, Rewards.Applied?)`. Failures: `invalid`, `unknown`, `expired`, `redeemed`, `exhausted`, `requirements` (or the code's own reason), `tooManyAttempts`, `busy`, `unavailable`, `notLoaded`. Uses are claimed with `UpdateAsync` before the reward is paid. |
| `codes:createAsync(def)`, `:disableAsync(code)`, `:listAsync()`, `:usesAsync(code)`, `:refreshAsync()` | The Admin panel's surface. Runtime codes can't reuse a config code. |
| `codes:lookup(code)`, `:hasRedeemed(who, code)`, `Codes.normalize(text)`, `Codes.validate(def, target?)` | `normalize` trims and upper-cases; nil if not 3-24 of `[A-Z0-9_]`. |
| `codes.Redeemed`, `codes:bindNet(context?)` | `(player?, userId, code, applied)`. Remotes `SharedCodes.Redeem(text)` (1/s, burst 3). |

```luau
local codes = Shared.Codes.new({ economy = economy, shop = shop, codes = Config.Codes })
codes:bindStore(Profiles)
codes:start()
codes:bindNet()
```

---

## Daily

The login-streak strip (brief §5.5, §6.6): one claim per UTC day (shifted by `resetHourUtc`),
consecutive days walk the strip, a missed day starts again at day 1. Server only; saved at
`profile.data.daily`.

| API | Notes |
|---|---|
| `Daily.new({ economy, shop?, days, reason?, field?, resetHourUtc?, graceDays?, repeatFrom?, analytics?, now?, players? })` | `days` is a list of `Types.Reward`. `reason` defaults to `"daily"`. After the last day the strip repeats from `repeatFrom` (1). |
| `daily:status(who)` | `{ canClaim, day, streak, broken, nextAt, days }` or nil before load. |
| `daily:claim(who)` | `(ok, failure?, Rewards.Applied?)`; failures `claimed`, `notLoaded`. Reports `analytics:progression(player, "daily", "complete", day)`. |
| `Daily.position(streak, length, repeatFrom?)`, `daily:dayIndex(time?)` | The pure strip math. |
| `daily.Claimed`, `daily.Attached` | `(player?, userId, day, applied)`; `(player?, userId, state)` when the profile loads. |
| `daily:bindNet(context?)` | Remotes `SharedDaily`: `Status`, `Claim`, and `Available` (status) pushed on load when a claim is open. |

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
| `store.Loaded`, `store.Released`, `store.ReceiptGranted` | `(player, profile)`, `(player?, profile, reason)`, `(player?, profile, receipt)`. `ReceiptGranted` fires once per purchase, from whichever save stores the grant (its own, Roblox's retry, an autosave or the release). Confirm purchases to the client and log them to analytics from it. |
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
| `Economy.new({ currencies, reasons?, multiplyWithin?, maxMultiplier?, walletField?, ledgerSize?, tickInterval?, ... })` | `currencies` are `Types.Currency` (whole numbers unless `integer = false`, optional `max`, `starting`, `leaderstat`, `icon`). `reasons` maps a name to its kind: `"earn"` (multiplied, counts toward lifetime), `"grant"` (exact and whole, never multiplied, no lifetime unless `{ kind = "grant", lifetime = true }`), `"spend"` or `"adjust"`. Defaults: `purchase`, `code`, `refund` are grants; `admin`, `rebirth` are adjustments. `maxMultiplier` 100, `ledgerSize` 50 per player, `tickInterval` 5 s. Two `leaderstat` currencies can't share a `displayName`, since it names the leaderstats value. Injectable: `task`, `now`, `clock`, `players`, `createLeaderstat`. |
| `economy:bindStore(store)` | Attaches each profile as Data loads it, detaches it on release, and forgets a player's multipliers when they leave. `attach(who, data)` / `detach(who)` do it by hand (`who` is a Player or a UserId everywhere). |
| `economy:earn(who, currency, amount, reason)` | `(granted, failure?)`: what reached the balance after multipliers, the carried fraction and the cap. Integer currencies carry fractions to the next earn, so 2 Wins at 1.25x pays 2, then 3. At the cap the balance stops but `lifetime` and `allTime` still count the whole earning. A balance already over a lowered `max` is kept; earning adds nothing to it until spending brings it under. A capped earn returns `0` with no failure, so receipts check `failure == nil`. |
| `economy:spend(who, currency, amount, reason)`, `:spendMany(who, { [currency] = amount }, reason)`, `:canAfford(...)` | `(ok, failure?)`. Never below zero. `spendMany` takes every cost or none, and its signals fire after all of them. |
| `economy:reasonKind(reason)` | The kind a reason was declared with (built-ins included), or nil. v0.2 modules use it at `new` to refuse an undeclared reason, which would otherwise make every earn pay 0. |
| `economy:set(who, currency, value, reason, { lifetime? })` | An `adjust`: rebirth resets (`set(p, "Wins", 0, "rebirth", { lifetime = 0 })`) and admin tools. |
| `economy:balance(who, currency)`, `:lifetime(...)`, `:allTime(...)` | `lifetime` is since the last reset (gates, Stilts height); spending never lowers it. `allTime` never resets. |
| `economy:setMultiplier(who, id, spec?)`, `:clearMultipliers(who)`, `:setGlobalMultiplier(id, spec?)` | A `Types.MultiplierSpec`: `{ group, factor, currencies?, reasons?, expiresAt? }`. Sources in a group add their bonuses (2x and +25% make 2.25x); groups multiply (rebirth x pass x event x boost); groups in `multiplyWithin` multiply their own sources. Per-player sources can be set before the wallet loads. `nil` removes one. |
| `economy:multiplier(who, currency, reason)`, `:multiplierBreakdown(...)` | The total, and `(total, { [group] = factor })` for "2.25x from passes" UI. |
| `economy:addBoost(who, id, factor, seconds, currencies?)`, `:removeBoost(who, id)`, `:getBoosts(who)` | Boosts are saved in the wallet, sit in the `boost` group, and count down only while the player is in a server. Buying the same id again adds time. |
| `economy:getLedger(who, limit?)`, `:getTotals()`, `:getDiagnostics()` | The newest ledger entries (`Types.LedgerEntry`), server-wide sums per currency and reason, and the Admin panel view. |
| `economy.Changed`, `economy.Transaction`, `economy.BoostsChanged` | `(player?, userId, currency, balance, delta, reason)`, a copy of each ledger entry (for Analytics), `(player?, userId)`. `Transaction` fires as the change is made, before the profile saves: a server that stops before saving loses the grant, and the next server grants it and fires `Transaction` again. Count purchases from the store's `ReceiptGranted`, which fires once, after the grant is saved. |
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
		local _, failure = economy:earn(profile.userId, "Wins", 500, "purchase")
		return failure == nil -- a pack that hits the cap still counts as delivered
	end)
end
```

---

## Events

Server-wide timed events (brief §4, §6.4): `lobby` (opt-in, on a clock-aligned cadence, so all
servers agree) or `ambient` (everyone, on a random gap, with a warning phase). Server only.

| API | Notes |
|---|---|
| `Events.new({ events, mode?, every?, between?, lobbySeconds?, warningSeconds?, resultsSeconds?, rotation?, seed?, economy?, shop?, rewardReason?, analytics?, players?, task?, now? })` | `events` are `{ id, nameKey?, durationSeconds, minPlayers?, maxPlayers?, rewards?{ participation?, placements? }, reward?(player, outcome, place?), run?(ctx), weight? }`. Defaults: lobby 90 s, warning 10 s, results 8 s, sequence rotation, reason `"event"`. |
| `events:start()`, `:stop()`, `:trigger(eventId?)` | `trigger` opens an event now when idle (`busy` otherwise). |
| `events:state()` | `{ phase, eventId?, endsAt?, participants, minPlayers, maxPlayers?, placements?, nextEventId? }`. Phases: idle, lobby or warning, running, results. |
| `events:join(player)`, `:leave(player)`, `:isParticipant(player)` | Lobby mode only. Failures `notOptIn`, `closed`, `full`, `notJoined`. |
| `events:upcoming()`, `:event(id)`, `Events.sequencePick(defs, slot)`, `Events.randomPick(defs, slot, seed)` | The next event and when it opens; the deterministic pickers. |
| `events.StateChanged`, `.Started`, `.Finished`, `.Membership` | `(state)`, `(eventId, participants)`, `(outcome)` with `{ id, participants, placements, rewards, data, cancelled }`, `(player, joined)`. |
| `events:bindNet(context?)` | Remotes `SharedEvents`: `GetState`, `Join`, `Leave` (answers carry the state with `joined`), `State` (everyone), `Joined` (the player), `Finished` (everyone). |

`run(ctx)` gets `{ id, def, participants, startedAt, endsAt, finish(result), isParticipant(player) }`;
`finish({ placements = { userId, ... }, data? })`. A `run` that errors is logged and the event
still ends.

---

## History

Undo and redo over snapshots, for editors (the car builder). Each entry is the whole state after
a step, so undo can't drift from what the player saw. States are opaque; pass values you won't
mutate afterwards (a copy, or frozen).

| API | Notes |
|---|---|
| `History.new({ limit?, equals? })` | `limit` undo steps kept (default 100; the oldest go first). `equals(a, b)` makes a push equal to the current state a no-op. |
| `history:reset(state)` | The starting state; clears both stacks. Required before `push`. |
| `history:push(state, label?)` | After a change. Drops the redo branch. Returns false when `equals` skipped it. |
| `history:undo()`, `history:redo()` | `(state, label)` to restore, or nil when there's nothing. The label is the step undone or redone. |
| `history:canUndo()`, `:canRedo()`, `:undoLabel()`, `:redoLabel()`, `:current()`, `:size()` | For enabling buttons and "Undo add wheel" tooltips. |

```luau
local history = Shared.History.new({ limit = 100 })
history:reset(design:snapshot())
design:addMember(a, b, "member_wood_beam")
history:push(design:snapshot(), "add member")
local state = history:undo()
if state then
	design:restore(state)
end
```

---

## Leaderboards

OrderedDataStore boards with batched writes, a cached top list, rank lookup, and daily or
weekly boards (brief §4, §6.8, §7.8). Server only; reads and writes run in background threads.

| API | Notes |
|---|---|
| `Leaderboards.new({ boards, prefix?, refreshInterval?, writeInterval?, dataStoreService?, userService?, players?, task?, now? })` | `boards` are `{ id, mode?, period?, scale?, value?(who), size?, nameKey?, icon?, format? }`. `mode` `"max"` (default), `"min"` (best times) or `"set"`; `period` `"all"`, `"daily"`, `"weekly"` (weeks start Monday 00:00 UTC); values stored as `round(value x scale)`; `size` up to 100. Writes every 60 s and on leave; tops refresh every 120 s. |
| `boards:start()` | Loads joining players' stored values, flushes on leave, runs the write and refresh loops. |
| `boards:submit(who, boardId, value)` | Kept only if better than what's known (`set` always replaces). Boards with `value` are sampled at each write instead. |
| `boards:get(boardId)` | `{ id, entries = { { rank, userId, name, displayName, value } }, updatedAt, endsAt? }` from cache. |
| `boards:rankOf(who, boardId)`, `:valueOf(who, boardId)`, `:storeName(boardId, time?)`, `:periodEndsAt(boardId, time?)` | `rankOf` is nil past the cached top. Store names: `LB_<id>`, plus `_D<day>` or `_W<week>`. |
| `boards:flushAsync(who?)`, `:refreshAsync(boardId?)`, `:loadPlayerAsync(player)`, `:removeAsync(boardId, userId)` | Manual control (tests, Admin). A failed write stays queued. |
| `Leaderboards.better(mode, a, b)`, `.period(period, time)`, `.encode(def, v)`, `.decode(def, n)` | The pure rules. |
| `boards.Updated`, `boards:bindNet(context?)` | `(boardId, snapshot)` after a refresh. Remotes `SharedLeaderboards`: `Get(boardId)` answers `{ board, you = { rank, value } }`; `Updated(boardId)` to everyone. |

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
| `Loc.merge(...tables)` | One table set from several (`Shared.Strings` plus the game's). A key defined twice for a locale is an error naming both tables. |
| `loc:bindKit()` | The kit's numbers (pills, stats, badges, number pops) follow this Loc's locale: `1.2K` in en, `1,2K` in pt-br and es. Returns an unbind function. |
| `Shared.Strings` | The framework's own strings in en, pt-br and es, one module per area under `src/Strings/` with a key prefix per area (`common.`, `settings.`, `admin.`, ...). `tests/Loc/Strings.spec.luau` requires every locale complete. |
| `Loc.toCsv(tables, source?)` | Roblox localization-table CSV (Key, Source, Context, Example, one column per locale) for importing into the experience's cloud table. |

```luau
local loc = Shared.Loc.new({ tables = Shared.Loc.merge(Shared.Strings, require(ReplicatedStorage.Stilts.Strings)) })
loc:setLocale(Players.LocalPlayer.LocaleId)
loc:bindKit()
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
passed as `Net.namespace(name, remotes, { context = ctx })`. `Net.getDefaultContext()` is the
Roblox context for this side, built on first use (it errors outside Roblox); every namespace
without a `context`, the kill switch and `Net.getMetrics()` use it. `Net.setDefaultContext(ctx?)`
replaces it for a whole test or sim, and `nil` resets it. Server-to-client payloads are
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

## Progression

Stages, server-measured attempts, records, awards (stars or medals), unlock gates and daily
featured stages (brief §4, §6.4, §6.6, §7.7). Server only; nothing yields. State lives at
`profile.data.progression` (`{ records, unlocked, featured? }`). The module header has a full
example.

| API | Notes |
|---|---|
| `Progression.new({ stages, gates?, economy?, rewardReason?, rebirths?, featured?, strikes?, analytics?, field?, now?, clock?, players? })` | `stages` are `{ id, group?, order?, par?, minSeconds?, awards?, reward?, gate?, featured?, meta? }`; `reward` is `{ currency, amount, firstClearMultiplier?, speedBonus?, speedBonusAt?, awardBonus? }`. `gates` are `{ id, requires?{ lifetime?, awards?, clears?, gates? }, fastTrack?{ factor, rebirths? } }`. `rewardReason` defaults to `"stage"`. |
| `progression:begin(who, stageId)`, `:finish(who, attemptId, { completed, flags?, awards?, durationSeconds? })`, `:abandon(who)`, `:current(who)` | Duration is measured between begin and finish; a game-reported `durationSeconds` is used only if shorter. A clear under `minSeconds` fails `implausible` and strikes `progression.tooFast`. |
| `progression:submit(who, result)` | Records a result the game measured itself. Prefer begin/finish. |
| Outcome | `{ result, record, firstClear, newBest, previousBest?, newAwards, rewards, payout, speedBonus, featured, unlocked }`. Failures: `notLoaded`, `unknownStage`, `locked`, `noAttempt`, `implausible`, `invalid`. |
| `progression:record(who, stageId)`, `:count(who, { group?, award? }?)`, `:cleared(who, group?)` | `StageRecord` is `{ clears, attempts, bestTime?, awards, firstClearAt?, lastAt? }`. |
| `progression:isUnlocked`, `:gateProgress(who, gateId)`, `:checkGates(who)`, `:unlock(who, gateId, reason)`, `:resetGates(who, keep?)` | `gateProgress` is `(0..1, parts)`, the least-complete requirement. Gates are rechecked on every Economy change. `fastTrack.factor` scales requirements after `rebirths` (1) rebirths. |
| `progression:featured(who)`, `:isFeatured(who, stageId)` | Featured stages (default 3, x2 reward) rotate per period (24 h) from a seed, the same on every server. |
| `Progression.speedBonus`, `.payout`, `.awardsFor`, `.newState`, `.repair` | The pure rules for sims. |
| `progression.Started`, `.Finished`, `.Unlocked`, `.Changed` | `(player?, userId, attempt)`, `(player?, userId, outcome)`, `(player?, userId, gateId, reason)`, `(player?, userId)`. Sets the `Progression_Awards` attribute. Analytics: `sink:progression(player, stageId, status, attempt)`. |
| `progression:bindNet(context?)` | Remotes `SharedProgression`: `GetState` (`{ records, unlocked, gates = { [id] = { unlocked, progress } }, featured, featuredEndsAt }`) and `State` on every change. |

---

## Rebirth

Reset-with-bonus (brief §4, §6.6, §7.7): requirements, what resets, bonus curves applied as
Economy multipliers, milestone rewards, and a preview for the confirm screen. Server only;
saved at `profile.data.rebirth` (`{ count, lastAt? }`).

| API | Notes |
|---|---|
| `Rebirth.new({ economy, progression?, shop?, requires?, resets?, bonuses?, milestones?, rewardReason?, maxRebirths?, onRebirth?, analytics?, now?, players?, task? })` | `requires` `{ lifetime?{ currency, amount }, gates?, awards?, custom? }`; `resets` `{ currencies?, gates?{ keep? } }`; `bonuses` name -> curve `{ perRebirth, linearUntil?, decay?, max?, currencies?, reasons? }`; `milestones` count -> `Types.Reward` (reason `"rebirthReward"`). |
| Curve | `perRebirth` per rebirth up to `linearUntil`, then each further one adds `decay` times the last, capped at `max`; factor = 1 + bonus. 0.25 / 10 / 0.85 gives 3.5x at 10, 3.71x at 11, limit 4.92x. A curve with `currencies` or `reasons` becomes multiplier `rebirth.<name>` in group `rebirth`. |
| `rebirth:count(who)`, `:factor(who, name, count?)`, `:progress(who)`, `:canRebirth(who)` | `progress` is `(0..1, parts)` with parts `{ kind, have, need, currency? }`. |
| `rebirth:preview(who)` | `{ count, progress, parts, canRebirth, failure?, bonuses = { [name] = { before, after } }, resetsCurrencies, resetsGates, keepsGates, milestone? }`. |
| `rebirth:perform(who, { force?, reason? }?)` | `(ok, failure?, summary?)`. Resets currencies with `economy:set(..., "rebirth", { lifetime = 0 })`, relocks gates, pays the milestone, calls `onRebirth(who, count, data)`, saves. Failures `notLoaded`, `requirements`, `maxed`. Summary `{ count, reason, bonuses, reset, milestone? }`. |
| `Rebirth.bonus(curve, n)`, `Rebirth.factor(curve, n)` | The pure curve. |
| `rebirth.Rebirthed`, `rebirth:bindNet(context?)` | `(player?, userId, summary)`. Sets the `Rebirths` attribute. Remotes `SharedRebirth`: `Preview`, `Rebirth` (answers `{ ok, failure?, summary? }`), `Rebirthed` to everyone `{ userId, name, count }`. |

---

## Remotes

The Net definitions for the v0.2 modules, one namespace each (`SharedProgression`,
`SharedRebirth`, `SharedDaily`, `SharedShop`, `SharedCodes`, `SharedLeaderboards`,
`SharedBadges`, `SharedEvents`, `SharedTutorial`), so server and client always agree. Requests
are validated (ids are `[%w_:.-]`, 1-64 chars) and rate limited; answers are plain tables
(`{ ok, failure?, ... }` for actions). Nothing a client sends decides an outcome.

| API | Notes |
|---|---|
| `module:bindNet(context?)` | Server, once per module at startup. Same as `Remotes.serve(name, module, context?)`. |
| `Remotes.client(name, context?)` | Client: the module's remotes, bound once per context and cached. The shared screens use this. |
| `Remotes.bind(name, context?)`, `Remotes.NAMESPACES`, `Remotes.shop()` (one factory per module) | Fresh definitions, for custom wiring and tests. |

```luau
-- Server
shop:bindNet()
-- Client
local shopRemotes = Shared.Remotes.client("Shop")
local answer = shopRemotes.Buy:invokeAsync("skin_neon") -- { ok = true, value = { ok = false, failure = "insufficient" } }

---

## Rewards

One shape (`Types.Reward`: `{ currencies?, items?, boosts?, ifOwned? }`) applied the same way by
Codes, Daily, Events and milestones.

| API | Notes |
|---|---|
| `Rewards.apply({ economy, shop? }, who, reward, reason)` | `Applied` `{ ok, failure?, currencies, items, duplicates, boosts }`. Currencies go through `economy:earn` with `reason` (its kind decides multiplied or exact); an owned item pays `ifOwned` instead, and with no `ifOwned` a duplicate pays nothing. Failures (nothing applied): `notLoaded`, `noEconomy`, `noShop`, `unknownReason` (the reason isn't an earn or grant). |
| `Rewards.requireReason(economy?, reason, owner, kinds?)` | Errors unless `reason` is declared with one of `kinds` (default earn or grant). Daily, Codes, Events, Progression, Rebirth and Shop call it in `new` for their reasons (`daily`, `code`, `event`, `stage`, `rebirthReward`, `shop`, `purchase`), but only when they would pay with it. |
| `Rewards.validate(reward, target?)` | A list of problems (unknown currency or item, missing shop); empty when fine. Modules validate their config at `new`. |
| `Rewards.isEmpty`, `Rewards.entries(reward)`, `Rewards.merge(a, b)` | Helpers for UI lines and combined payouts. |

---

## Screens

The shared screens from brief §5.5, built from the UI kit and driven by Remotes. Client only.
What each screen shows is decided by `Screens.Models` (pure and tested); the builders only lay
it out. Their strings are in `Shared.Strings` (areas `shop`, `rebirth`, `codes`, `leaderboards`,
`daily`, `events`, `badges`, `tutorial`, `rewards`, `time`, `errors`, plus `common`).

| API | Notes |
|---|---|
| Content strings | The game's tables name its content: `currency.<Id>`, `item.<id>`, `pass.<key>`, `product.<key>`, `board.<id>`, `event.<id>`, `badge.<key>` (and `.description`), `boost.<id>`, `bonus.<name>` (rebirth bonuses), `fail.<reason>` (a game's own refusal reasons), or a def's `nameKey`. Tutorial step text uses the game's own keys. |
| `Screens.install({ loc, manager, area, catalog?, boards?, events?, badges?, balances?, context?, userId?, now?, autoOpenDaily?, toasts? })` | Registers `Shop`, `Rebirth`, `Codes`, `Leaderboards`, `Daily`, `EventLobby` on the ScreenManager and wires badge toasts, the rebirth banner, purchase confirmations and auto-opening Daily. Returns the `Env` the helpers below take. `catalog` is `{ items, passes, products, currencyIcons }` from the same config the server used. |
| `manager:push("Shop", { tab = "boosts" \| "cosmetics" \| "passes" })`, `push("Leaderboards", { board = id })` | Boosts = developer products (crates show odds) plus items in category `Boosts`; Cosmetics = other items; Passes = game passes. Ids of 0 are hidden. |
| `Screens.Purchase.request(env, "product" \| "pass", key)` | The prompt wrapper every Robux purchase goes through. Crates show their odds first. Failures become toasts; the success toast follows `Shop.Confirmed`. |
| `Screens.Tutorial.start(env, steps, onFinished?)` | Coachmarks: `steps` `{ id, textKey, target?() -> GuiObject?, waits? }`, same ids and order as the server's `Tutorial`. Returns `{ complete(stepId), current(), stop() }`. Resumes where the server says; never shows again once done. |
| `Screens.EventLobby.chip(env, parent, maxWidth?)` | The HUD countdown chip; tap opens the lobby. Returns a remover. |
| `Screens.Leaderboards.surface(env, part, boardId)` | A board on a SurfaceGui (lobby wall). Returns a remover. |
| `Screens.Models.*` | `shop`, `rebirth`, `daily`, `leaderboard`, `event`, `codeResult`, `badgeToast`, `purchaseConfirmed`, `tutorialStep`, plus `duration`, `percent`, `decimal`, `rewardLines`, `failure`, `answer`. |

```luau
local loc = Shared.Loc.new({ tables = Shared.Loc.merge(Shared.Strings, require(Strings)) })
local area = Shared.UI.SafeArea.new()
local screens = Shared.UI.ScreenManager.new(area)
local env = Shared.Screens.install({
	loc = loc, manager = screens, area = area,
	catalog = { items = Config.Items, passes = Config.Passes, products = Config.Products, currencyIcons = { Wins = "icon_wins" } },
	boards = Config.Boards,
})
Shared.Screens.EventLobby.chip(env, area.anchors.BottomCenter)
```

---

## Settings

Per-player settings (brief §4, §5.5), saved in the profile under `settings`. The server owns the
values and validates every change; the client applies a change the moment the player makes it
and sends it once the value has been still for 0.4 s.

| API | Notes |
|---|---|
| `Settings.DEFINITIONS`, `Settings.SECTIONS` | `musicVolume`, `sfxVolume`, `uiSounds` (audio); `cameraShake` (0 to 1 in quarters), `flashes`, `haptics` (comfort); `colorblind` (`off`, `deuteranopia`, `protanopia`, `tritanopia`); `controls` (games add options); `language` (`auto`, `en`, `pt-br`, `es`). |
| `Settings.schema({ add?, override?, remove? })` | A game's schema: add its own definitions (section `game`), change defaults or options (`override = { controls = { options = { "auto", "tap", "hold" } } }`), or drop some. Returns `{ list, byId, ids, defaults, validate, normalize }`. |
| `Settings.remotes(schema, { context? })` | Namespace `RBLXSettings`: `Set` (a map of every change since the last send, so a reset is one message), `Request` (client) and `Snapshot` (server). Server and client must build it from the same schema. |
| `Settings.Server.new({ store, schema?, field?, remotes?, context?, players? })` | `get`, `getAll`, `set(player, id, value)` and `Changed(player, id, value)`. Sends a snapshot on load and on request; a refused value resends the snapshot so the client snaps back. |
| `Settings.Client.new({ schema?, remotes?, audio?, vfx?, loc?, localeId?, appliers?, sendDelay? })` | `get`, `set`, `reset(section?)`, `flush`, `apply`, `isReady`, `Changed`, `Ready`. Applies built-ins to Audio (volumes, UI sounds), VFX (shake scale, flashes), `UI.Hooks` (haptics), `UI.Theme` (palette) and Loc (language); `appliers[id]` handles game settings. |
| `Settings.Screen.register(screens, { client, loc, name? })`, `Settings.Screen.build(options)` | The Settings screen from the kit: a header per section, Toggle/Slider/cycle button per row, Restore defaults and Done. It rebuilds itself on a language or palette change. |

```luau
-- Server
local schema = Shared.Settings.schema({ override = { controls = { options = { "auto", "tap", "hold" } } } })
Shared.Settings.Server.new({ store = Profiles, schema = schema })
-- Client
local settings = Shared.Settings.Client.new({ schema = schema, audio = audio, vfx = vfx, loc = loc,
    localeId = Players.LocalPlayer.LocaleId })
Shared.Settings.Screen.register(screens, { client = settings, loc = loc })
```

---

## Shop

Game passes, developer products (rewards, crates, custom grants) and the soft-currency catalog
with equip slots (brief §4, §6.7, §7.9). Server only. State lives at `profile.data.shop`
(`{ owned, equipped, passes, robuxSpent, purchases }`). The module header has a full example.

| API | Notes |
|---|---|
| `Shop.new({ economy, passes?, products?, items?, categories?, featured?, field?, spendReason?, purchaseReason?, autoEquip?, analytics?, marketplace?, policy?, players?, task?, now?, ownershipRetries?, ownershipRetryDelay?, policyRetryDelay? })` | Passes `{ key, id, price, nameKey?, descriptionKey?, icon?, multipliers?, onOwned? }`. Products `{ key, id, price, ..., reward \| crate \| grant(ctx), canPurchase?, random? }` (exactly one of reward, crate, grant). Items `{ id, category, slot?, price? \| levels?, available?, nameKey?, icon?, featured?, rarity?, default?, order? }`. Reasons default `"shop"` (spend) and `"purchase"` (grant). |
| `shop:bindStore(store, { processReceipt? })` | Attaches profiles and, unless `processReceipt = false`, sets `MarketplaceService.ProcessReceipt` (idempotent through Data; unknown product ids stay `NotProcessedYet` and log an error). |
| `shop:buy(who, itemId)`, `:equip(who, itemId)`, `:unequip(who, slot)`, `:grantItem(who, itemId, reason)`, `:revokeItem(who, itemId)` | Failures: `notLoaded`, `unknown`, `notForSale`, `owned`, `maxed`, `unavailable` (or the item's own reason), `insufficient`, `notEquippable`, `notOwned`. |
| `shop:prompt(player, "product" \| "pass", key)`, `:canPurchase(who, productKey)` | Refuses `notCreated` (id 0), `restricted` (paid random items not allowed: PolicyService, restricted until known; a failed lookup is retried once after `policyRetryDelay`, 5 s), or the product's own `canPurchase` reason. |
| `shop:processReceipt(receipt)`, `:odds(productKey)`, `Shop.oddsOf(crate)`, `Shop.rollCrate(crate, draw)` | Crates roll from the PurchaseId, so a retried receipt rolls the same item; owned results pay `ifOwned`. A crate without `ifOwned` pays nothing for a duplicate, so give every crate one unless duplicates can't happen. |
| `shop:hasItem`, `:level`, `:priceOf`, `:equipped(who, slot)`, `:ownsPass`, `:refreshPassesAsync(player)`, `:featured(time?)`, `:randomItemsAllowed(who)` | Featured picks (default 3 every 6 h) are the same on every server. Pass ownership is checked on load (3 tries) and cached in the profile. |
| `shop:snapshot(who)` | `{ owned, equipped, passes, blocked, unavailable, featured, featuredEndsAt, randomItemsAllowed }` for the screen. |
| `shop.Purchased`, `.ItemGranted`, `.Equipped`, `.PassOwned`, `.Confirmed`, `.Changed` | `Confirmed(player?, userId, kind, key, details)` fires after the grant is saved. Attributes `Pass_<key>` and `Equipped_<slot>`. |
| `shop:bindNet(context?)` | Remotes `SharedShop`: `GetState`, `Buy(itemId)`, `Equip(itemId)`, `Unequip(slot)`, `Prompt({ kind, key })`, `State` and `Confirmed` to the player. |

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
| `T.Fakes.Instances.new()` | `.create(className)` for modules with an injected `createInstance` (Audio, VFX). Fakes take any property and implement `Play/Stop/Pause/Resume`, `finish()` (fires `Ended`), `Emit`, `Destroy`, `GetChildren`, `FindFirstChild`, attributes and `Clone`; `:count(className, alive?)`, `:all(className)`. |
| `T.Fakes.Players.new()` | `join(spec)` / `leave(player)` fire `PlayerAdded` / `PlayerRemoving`; fake players support `Kick` (removes from server), attributes with change signals. |
| `T.Signal.new()` | Synchronous signal (`Connect`, `Once`, `Fire`, `DisconnectAll`). |

Under lune, `game`, `task` and `Enum` do not exist and cannot be injected, so modules take
services, `task` and enum values as constructor dependencies (see CONTRIBUTING.md).


---

## TextFilter

Player-typed text that other players see goes through Roblox's filter before it is stored or
shown (brief §3.4). Server only; `TextService` is used when a call is made, so requiring the
module is free.

| API | Notes |
|---|---|
| `TextFilter.clean(text, maxChars?)` | Run first. Drops invalid UTF-8, control and invisible characters (zero-width, direction marks, BOM), turns whitespace runs into one space, trims, and keeps at most `maxChars` characters (codepoints, not bytes). |
| `TextFilter.new({ backend?, retries?, retryDelay?, cacheSeconds?, cacheSize?, wait?, now? })` | Default backend: `TextService:FilterStringAsync(text, userId, PublicChat):GetNonChatStringForBroadcastAsync()`, the strictest result, fit for names everyone sees. Defaults: 2 retries 0.5 s apart, results cached 300 s, at most 256 cached. Tests pass a `backend(text, userId) -> string` that may error. |
| `filter:broadcast(text, fromUserId)` | `(filtered, nil)`, or `(nil, "unavailable")` when every try failed: it fails closed, so keep the old text or refuse the change and never store the raw input. `fromUserId` is whoever typed the text, or pasted a code carrying it. Compare the result with the cleaned input to see whether anything was replaced with `#`. Empty text returns `""` without a call. |

```luau
local filter = Shared.TextFilter.new()
local name = Shared.TextFilter.clean(raw, 20)
local filtered, failure = filter:broadcast(name, player.UserId)
if filtered == nil then
	return { ok = false, failure = "filterUnavailable" }
elseif filtered ~= name then
	return { ok = false, failure = "nameNotAllowed" }
end

---

## Tutorial

The server side of the onboarding coachmarks (brief §5.5, §8): which step each player reached,
saved at `profile.data.tutorial`, and every first-time step sent to analytics for the funnel.

| API | Notes |
|---|---|
| `Tutorial.new({ steps, analytics?, field?, now?, players? })` | `steps` is the ordered list of step ids. |
| `tutorial:complete(who, stepId)` | Completes the step and every one before it; each is reported once ever as `analytics:onboarding(player, index, stepId)`. `(ok, failure?)`: `unknown`, `notLoaded`. |
| `tutorial:skip(who)`, `:reset(who)`, `:status(who)`, `:steps()` | A skip reports nothing more (it shows as drop-off). `status` is `{ step, total, done, skipped, next? }`. A reset never re-reports. |
| `tutorial.Advanced`, `tutorial.Finished`, `tutorial:bindNet(context?)` | `(player?, userId, index, stepId)`, `(player?, userId, skipped)`. Remotes `SharedTutorial`: `GetState`, `Step(stepId)`, `Skip`. |

---

## Types

Shared Luau types, defined once in `src/Types/init.luau` (fields are documented there). Requiring
the module costs nothing. Changing a field is a breaking change.

| Types | Used by |
|---|---|
| `UserId`, `CurrencyId` | Everything |
| `Currency`, `CurrencyState`, `BoostState`, `Wallet`, `MultiplierSpec`, `LedgerEntry` | Economy; the wallet lives at `profile.data.wallet` |
| `SessionLock`, `ReceiptRecord`, `ProfileMeta`, `PlayerProfile<T>` | Data |
| `StageResult` | Produced by game systems; consumed by Progression and Leaderboards |
| `StageRecord` | Progression's per-stage record (clears, attempts, best time, awards) |
| `Reward`, `BoostReward` | Rewards: Codes, Daily, Events, Rebirth milestones, crate fallbacks |
| `PurchaseReceipt` | `ProcessReceipt`'s `receiptInfo`, typed |
| `AssetKind`, `AssetStatus`, `AssetRef` | Assets |

```luau
type StageResult = Shared.Types.StageResult
```

---

## UI

The shared UI kit (brief §5): theme tokens, components, screen manager and safe area. Game code
builds every screen from it and never styles Instances directly. Full reference, including every
component and variant: [UI.md](UI.md).

| Entry point | Notes |
|---|---|
| `UI.Tokens`, `UI.Theme` | Tokens hold every color, size, radius, type size, timing and layer. `Theme.setGame("stilts" \| "car")` picks the accent (call it before building UI); `Theme.color(name)`, `hex`, `font(role)`, `textSize`, `variant(v)`, `onGameChanged(fn)`. |
| `UI.Kit` | Components such as `Button`, `IconButton`, `HoldButton` (hold-to-confirm and charged thumb actions), `Panel`, `Modal`, `Tabs`, `ProgressBar` (also two-way), `Slider` (also vertical), `CurrencyPill` and `ListRow`. Each has a `Variants` list; most build with `new(props)`, which returns `(root, handle)`, while one-shot pieces use `Confirm.show`, `NumberPop.spawn`, `Confetti.burst` or `Tooltip.attach`, and toasts and banners go through `area.toasts.show` and `area.banners.show`. `Icon` props take an asset name, not a content id. |
| `UI.SafeArea.new(props?)` | The root ScreenGui inside the safe insets, scaled to the viewport, with HUD `anchors` (no bottom-left: that is the thumbstick), `banners` and `toasts` lanes, and modal layers. |
| `UI.ScreenManager.new(area)` | `register(name, factory)`, `push`, `pop`, `replace`, `showModal` (two at most), input mode and console focus, `setCinematic(on)`. |
| `UI.Layout` | The pure geometry behind those: viewport scale, safe-zone and thumbstick rects, anchor rects, input-mode mapping, grid columns, drawer style. |
| `UI.Gestures.new({ slop?, longPress? })` | Pure recognizer for 3D editors: feed `down/move/up(id, x, y, now)` per finger (or the mouse) and `update(now)` each frame; each call returns events: `tap`, `longPress`, `dragStart`/`drag`/`dragEnd`/`dragCancel` (one finger, `held` after a long press), `pinchStart`/`pinch`/`pinchEnd` (two fingers: `scale`, `rotation`, midpoint `dx`/`dy`). `cancel()` ends whatever is in progress. |

`UI.Format.showCompact / showGrouped / showDelta` are what the kit displays; they follow the
locale once `loc:bindKit()` has run. Also `UI.Color`, `Format`, `Create`, `Motion`, `Hooks` (sound and haptic events) and `Gallery`
(the `/uigallery` chat command); see [UI.md](UI.md).

```luau
local UI = Shared.UI
UI.Theme.setGame("stilts")

local area = UI.SafeArea.new({ Name = "HUD" })
local screens = UI.ScreenManager.new(area)
local _, wins = UI.Kit.CurrencyPill.new({
	Icon = "icon_wins", -- an icon still pending upload shows its placeholder card
	Value = 0,
	OnPlus = function()
		screens:push("Shop", { tab = "Boosts" })
	end,
	Parent = area.anchors.TopLeft,
})
local shown = false
Shared.Economy.observe(Players.LocalPlayer, "Wins", function(balance)
	wins.setValue(balance, shown) -- counts up; no "+N" pop for the first value
	shown = true
end)
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
| `Util.Bytes.writer(capacity?)` | Binary writer for save formats and share codes: `byte`, `u32` (big-endian), `uint` (LEB128 varint, up to 2^32 - 1), `int` (zigzag varint), `str` (varint length + bytes), `raw`, `length`, `toString`. Out-of-range values error (an encoder bug). |
| `Util.Bytes.reader(data)` | The matching reader: `byte`, `u32`, `uint(max?)`, `int(min?, max?)`, `str(maxLength)`, `raw(n)`, `remaining`, `position`, `failed`, `fail`. Bad input never errors: reads return 0 or "" and set `failed()`, so a decoder reads a record and checks once. |
| `Util.Base64.encode(data, { url?, pad? }?)`, `Util.Base64.decode(text, { url? }?)` | RFC 4648. `url = true` uses `-` and `_` and drops padding by default (codes players paste into chat). `decode` returns nil for any character outside the alphabet, an impossible length or non-canonical trailing bits; padding is optional. |
| `Util.Hash.fnv1a32(data, seed?)`, `Util.Hash.fnv1a64(data)`, `Util.Hash.hex32(n)` | FNV-1a, exact in doubles so lune and Roblox agree. `fnv1a64` returns 16 hex characters. For change detection and checksums, not security. |

```luau
local template = Shared.Util.Deep.copy(Config.defaultData)

local w = Shared.Util.Bytes.writer()
w:uint(#nodes)
local code = Shared.Util.Base64.encode(w:toString(), { url = true })
```

---

## VFX

Client-side effects (brief §4, §5.7). Particle colors are UI token names, so effects share the
UI palette and the game's accent; textures are engine particle sprites (no upload).

| API | Notes |
|---|---|
| `VFX.new({ createInstance?, camera?, runService?, playerGui?, terrain?, task?, tweenService?, shake?, maxHighlights? })` | `shake` is `{ maxAngle? 2.5, maxOffset? 0.35, decay? 1.6, frequency? 18 }`; the maxima are hard-capped at 4 degrees and 0.6 studs. |
| `vfx:emit(preset, partOrAttachment, count?)`, `vfx:emitAt(preset, position, count?)` | Emitters are cached per target; `emitAt` uses a temporary attachment on Terrain. Presets: `sparkle`, `confetti`, `dust`, `splash`, `embers`, `burst`, `snow`, `stars`. |
| `VFX.definePreset(name, preset)`, `VFX.Presets.validate(name, preset)` | Game presets, namespaced (`"car.mudSpray"`). A preset with several `colors` builds one emitter per color. |
| `vfx:highlight(target, { color?, fill?, fillTransparency?, outlineTransparency?, duration?, alwaysOnTop?, fadeIn? })` | Returns `{ instance, remove(fade?) }`. At most 24 at once (Roblox renders 31); past that the oldest goes. |
| `vfx:shake(trauma)`, `vfx:setShakeScale(0..1)` | Trauma model (`VFX.Shake`): offset scales with trauma squared and decays; applied after the camera each frame; on a camera nothing rewrites each frame (Scriptable), last frame's offset is taken off first, so it doesn't drift. Scale 0 (the player's setting) turns it off. |
| `vfx:flash(color?, { peak?, duration? })`, `vfx:setFlashesEnabled(on)` | Full-screen fade, peak opacity at most 0.85. Players can turn flashes off. |
| `VFX.Shake.new(options).step(dt)` | The pure model, for sims and tests. |

```luau
local vfx = Shared.VFX.new()
vfx:emit("sparkle", character.HumanoidRootPart)
vfx:shake(0.35)
vfx:flash("white", { peak = 0.4 })
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
