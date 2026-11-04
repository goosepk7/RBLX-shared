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
| `Assets.image(name, { size?, props? })` | `GuiObject` | `ImageLabel`, or a colored placeholder card showing the name while pending. |
| `Assets.applyImage(imageLabel, name, size?)` | | Sets `Image`, or overlays the placeholder card. |
| `Assets.sound(name, props?)` | `Sound` | Silent while pending (warns once). Errors if the asset isn't audio. |
| `Assets.has / isPlaceholder / list / pending` | | Introspection for admin panels and checks. |
| `Assets.setStrict(bool)` | | Unknown names throw instead of warning once. |

```luau
Assets.register(require(ReplicatedStorage.Stilts.AssetIds), "stilts")
local icon = Assets.image("icon_wins", { size = 64, props = { Size = UDim2.fromOffset(32, 32) } })
```

Generated module: `tools/gen_asset_ids.luau` writes `AssetIds.luau` from `assets/manifest.json`
(path per repo in `assets/config.json`). See [TOOLING.md](TOOLING.md) for the manifest format.

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
checked against their schema in Studio and tests (`validateOutgoing`).

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
| `Currency`, `CurrencyState`, `BoostState`, `Wallet` | Economy; the wallet lives at `profile.data.wallet` |
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
| `Util.Roblox.isRoblox / isStudio / side / service / task / jobId / placeId` | Lazy Roblox access, so modules stay requirable under lune. |

```luau
local template = Shared.Util.Deep.copy(Config.defaultData)
```
