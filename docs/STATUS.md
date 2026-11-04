# RBLX-shared status

**Phase:** 1, Shared v0.1 (Net, Data, Types, Economy, UI theme + kit + gallery, Assets, Test/Sim harness, CI)
**Version:** 0.1.0 (unreleased)

## Owner to-do
- Nothing right now.
- After publish: create an Open Cloud key and run the upload command in docs/TOOLING.md.
- After publish: create a second Open Cloud key with the data store list and read scopes, add it to each game repo as the `ROBLOX_API_KEY` secret (and the experience id as the `ROBLOX_UNIVERSE_ID` variable), and add the daily backup workflow from docs/TOOLING.md.

## Blockers
- None.

## Known weak spots (tooling)
- Decal → Image id resolution is unverified until a real key exists (mock-tested only). Images that fail it stay `unresolved` with a Studio fallback (`tools/resolve_decals --studio-script`). First real upload: spot-check one icon in Studio.
- The custom lint is pattern-based, not a parser; it can miss multi-line calls. Selene and the type checker cover the rest.
- Since 2026-11-04 the agents' sandbox can download the luau-lsp 1.70.0 release, so the strict type check runs locally too; Selene's Roblox std still can't be generated there.

## Known weak spots (core)
- `Net.RobloxTransport` (the RemoteEvent wiring) can't run under lune; every test goes through the loopback transport, which mirrors Roblox's documented argument rules. A one-click Studio smoke script lands before the games wire Net up.
- Data runs against fakes of DataStoreService and MessagingService. The fakes follow Roblox's documented behavior (transform reruns on conflict, request budgets, error codes), but the real services haven't been exercised yet. First Studio session: join, leave, rejoin, and check `Data.getDiagnostics()`.
- `tools/backup_profiles` is tested against a mock of the Open Cloud data stores v2 API; the real endpoint's response shape is an assumption until the first keyed run. The tool fails loudly, rather than backing up nothing, if the list response looks different.

## Tooling, CI, harness (`shared/tooling`)
- [x] Repo skeleton: Rojo projects, wally.toml, rokit toolchain pins, StyLua, Selene, `.luaurc`, pre-commit
- [x] GitHub Actions CI: StyLua check, Selene, luau-lsp analyze, lune tests, Rojo build artifact
- [x] Test harness: describe/it runner, matchers, virtual clock + `task` emulation
- [x] Fakes: DataStoreService (failure injection, metadata, ordered stores, UpdateAsync conflict reruns + beforeCommit race hook, real request budgets), MarketplaceService (receipts, replay, retry), Players
- [x] Sim harness: deterministic RNG, scheduler, synthetic players, recorder + CSV/JSON, targets, tuning helpers (band targets fixed), Studio/Open Cloud runner shell (`lune run sims`)
- [x] Assets: manifest-backed lookup with visible placeholders, `AssetIds.luau` generation
- [x] Tools: `upload_assets` (Open Cloud, end-to-end tested against a mock, resolves Decal → Image ids), `resolve_decals`, `verify_assets`, `gen_asset_ids`, custom lint (§9.4), shared Open Cloud client
- [x] docs/API.md sections for Test, Sim, Assets; docs/TOOLING.md

## Core (`shared/core`)
- [x] Types: shared Luau types for economy, data, progression, monetization and assets
- [x] Signal and Util (Log, Deep, Roblox helpers)
- [x] AntiExploit: strike registry, three strikes flags, flag log for the Admin panel
- [x] Net: typed remotes, schema validation, rate limits, strikes for malformed traffic, local and cross-server kill switch, metrics, loopback transport for tests
- [x] Data: session-locked profiles, autosave every 60 s and on leave, retries with backoff, migrations, BindToClose flush, idempotent receipts, refusal to write unstorable data, diagnostics API (`getDiagnostics`) for the Admin panel's DataDiagnostics view
- [x] `tools/backup_profiles`: daily backups and one-player restores through Open Cloud; the scheduled workflow for game repos is in docs/TOOLING.md
- [ ] DataDiagnostics panel UI (with Admin v0.2)
- [ ] Economy: currencies, earn and spend, multipliers, boosts, leaderstats
- [x] docs/API.md sections for AntiExploit, Data, Net, Signal, Types, Util (Economy lands with its module)

## UI kit (`shared/ui`)
- [x] Theme tokens (base palette + Stilts/Car accents), fonts, type scale, shapes, motion (`src/UI/Tokens.luau`)
- [x] Kit: Button, IconButton, Chip, Card, Panel, Modal, Drawer, Confirm, Tabs, ProgressBar, Stat, CurrencyPill, ListRow, Grid, Tooltip, Toast, Banner, NumberPop, Confetti
- [x] SafeArea (notch + topbar insets, viewport UIScale, HUD anchors) and ScreenManager (push/pop, 2-modal cap, input mode, console focus, cinematic mode)
- [x] `/uigallery`: every component and variant, Stilts/Car accent toggle
- [x] 16 core icons (SVG source + 256/64 PNG) and `tools/rasterize.py`
- [ ] Icon entries in `assets/manifest.json` (after the Assets PR lands)
- [ ] Wire `Hooks.setSoundHandler` from shared Audio (v0.2)
- Weak spots, honestly: the kit has not been seen in Studio yet. Layout and press feel are written to spec but unverified on a device until the owner opens `/uigallery`. Haptics on phones depend on Roblox's touch motor support, which is limited.
