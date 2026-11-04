# RBLXShared API

`local Shared = require(ReplicatedStorage.Packages.RBLXShared)`. Each module is also reachable
as `Shared.<Module>`. Sections are added by the thread that owns the module; keep each one to
the public surface, with one example.

Version: 0.1.0 (semver; a breaking change bumps both games in the same change set).

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
