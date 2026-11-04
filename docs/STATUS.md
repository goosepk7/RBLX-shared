# RBLX-shared status

**Phase:** 3, Shared v0.2 (v0.1 is merged and signed off)
**Version:** 0.2.0 in progress

## Owner to-do
- Before the games wire up Net: open `NetSmoke.rbxl` in Studio and press Play. It should print `NET SMOKE: PASS (48 checks)`; if it doesn't, paste the `FAIL` lines into the project. Where to get the file: [Studio smoke test for Net](TOOLING.md#studio-smoke-test-for-net).
- After publish: create an Open Cloud key and run the upload command in docs/TOOLING.md.
- After publish: create a second Open Cloud key with the data store list and read scopes, add it to each game repo as the `ROBLOX_API_KEY` secret (and the experience id as the `ROBLOX_UNIVERSE_ID` variable), and add the daily backup workflow from docs/TOOLING.md.

## Blockers
- None.

## Known weak spots (tooling)
- Decal → Image id resolution is unverified until a real key exists (mock-tested only). Images that fail it stay `unresolved` with a Studio fallback (`tools/resolve_decals --studio-script`). First real upload: spot-check one icon in Studio.
- The custom lint is pattern-based, not a parser; it can miss multi-line calls. Selene and the type checker cover the rest.
- Since 2026-11-04 the agents' sandbox can download the luau-lsp 1.70.0 release, so the strict type check runs locally too; Selene's Roblox std still can't be generated there.

## Known weak spots (core)
- `Net.RobloxTransport` (the RemoteEvent wiring) can't run under lune; every test goes through the loopback transport, which mirrors Roblox's documented argument rules. The Studio smoke place (`studio/`, attached to every CI run as `NetSmoke.rbxl`) checks the transport over real remotes and compares eight of those rules with the loopback. So far it has only been dry-run against emulated remotes, so the first Play in Studio is its real test.
- Data runs against fakes of DataStoreService and MessagingService. The fakes follow Roblox's documented behavior (transform reruns on conflict, request budgets, error codes), but the real services haven't been exercised yet. First Studio session: join, leave, rejoin, a teleport between two servers, and check `Data.getDiagnostics()`.
- Data, known limit: when three or more servers want the same player's lock at once, their release requests keep replacing each other, so each waits out its deadline and gives up with "locked" (the player is kicked to retry; the data is untouched). Safe, and rare enough to leave.
- Data: a player rejoining right after a server crash waits up to 90 s, because a crashed server's lock looks alive until the release wait runs out.
- Economy: the default leaderstats (IntValue/NumberValue in `player.leaderstats`) only run inside Roblox; specs inject a stand-in. First Studio session: check the player list and the `Currency_*` attributes.
- Economy: boost time can run up to 5 s long per session (the countdown ticks every 5 s and the leave refresh may land after the final save snapshot).
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
- [x] Net Studio smoke place (`studio/`): real remotes end to end, plus Roblox's argument rules against the loopback's; CI builds `NetSmoke.rbxl`
- [x] Data: session-locked profiles, autosave every 60 s and on leave, retries with backoff, migrations, BindToClose flush, idempotent receipts, refusal to write unstorable data, diagnostics API (`getDiagnostics`) for the Admin panel's DataDiagnostics view
- [x] `tools/backup_profiles`: daily backups and one-player restores through Open Cloud; the scheduled workflow for game repos is in docs/TOOLING.md
- [x] DataDiagnostics panel UI (the Admin panel's Data tab)
- [x] Economy: currencies, earn/spend/grant/adjust with declared reasons, grouped multipliers (rebirth x pass x event x boost), play-time boosts saved in the wallet, fraction carry and balance caps, player attributes and leaderstats, ledger and per-reason totals, `bindStore` wiring to Data
- [x] docs/API.md sections for AntiExploit, Data, Economy, Net, Signal, Types, UI (a pointer to UI.md), Util; every name in these sections checked against the code for v0.1

## Loc (early, for the game foundations)
- [x] Loc: per-locale string tables, `{name}` placeholders with number formats, CLDR plurals for en/pt-BR/es, source fallback, `validate` for specs, Roblox localization CSV export
- [x] Kit numbers follow the locale (`loc:bindKit()`: 1,2K in pt-br and es)
- [x] Language override in Settings (`language`: auto, en, pt-br, es)

## Shared v0.2: Analytics, Loc, Audio, VFX, Settings, Admin
- [x] `UI.Kit.TextInput` (Codes screen, Admin console) with gallery story (#15)
- [x] Analytics: join, session length, onboarding steps, first milestones (time to first win), purchases from `ReceiptGranted`, stage progression, economy sources/sinks; batched within Roblox's budget; ring buffer for Admin
- [x] `Shared.Strings` (en, pt-br, es) and `Loc.merge`, checked complete by a spec
- [x] Audio: named sounds with variations and pooling, music crossfade, category volumes, kit sounds through `UI.Hooks`
- [x] 22 base SFX (UI set plus purchase, win, checkpoint, unlock, fail) from `tools/sfx_gen.py`, in the manifest, pending upload
- [x] VFX: 8 particle presets on theme colors, highlights (capped), camera shake (capped, scalable to off), screen flash (can be turned off)
- [x] Kit Toggle and Slider, with gallery stories
- [x] Kit `HoldButton` (hold-to-confirm and charged thumb actions), vertical `Slider` and two-way `ProgressBar`, with gallery stories (from the Stilts rig: Lunge, Dismount, the length slider and the balance meter)
- [x] Settings: per-player settings saved in the profile (music, sfx, shake, flashes, haptics, colorblind palette, control scheme, language), server-validated, Settings screen
- [x] Admin: owner whitelist, chat commands (grant, reset, teleport, kick, sim-run), data inspector with DataDiagnostics, flags, analytics feed, Admin panel
- Weak spots, honestly: none of the SFX have been heard on a device yet (synthesized and checked for level and length only). VFX uses engine particle sprites, so splash and confetti look like sparkles until custom sprites exist. Roblox Analytics only shows data from a published place, so the dashboards are unverified until launch.
- Weak spots, Settings and Admin: neither screen has been opened in Studio yet (built from the kit, layout unverified on a device). The colorblind palettes were picked from published colorblind-safe sets but not checked in a simulator. A palette change rebuilds the Settings screen only; other open kit screens keep their colors until they're rebuilt. Admin's `tp` without a game hook moves to another player only. The `/admin` chat command needs TextChatService (the default chat).
- First Studio session, v0.2 checks: `TextChatCommand.Triggered` fires on the server for the server-made `/admin`; AnalyticsService accepts `session_length` flushed during PlayerRemoving and BindToClose; SoundGroup volumes follow live Settings changes; camera shake on a Scriptable camera doesn't drift (the undo relies on reading back the exact CFrame it set).

## World (`car/foundation`, used by both games)
- [x] `World`: layout specs, validation with paths, rotation-aware stats for part budgets, composition helpers, `instantiate` for Roblox and lune
- [x] `tools/lib/model.luau`: deterministic `.rbxmx` writer with a `--check` mode for game CI

## UI kit (`shared/ui`)
- [x] Theme tokens (base palette + Stilts/Car accents), fonts, type scale, shapes, motion (`src/UI/Tokens.luau`)
- [x] Kit: Button, IconButton, Chip, Card, Panel, Modal, Drawer, Confirm, Tabs, ProgressBar, Stat, CurrencyPill, ListRow, Grid, Tooltip, Toast, Banner, NumberPop, Confetti
- [x] SafeArea (notch + topbar insets, viewport UIScale, HUD anchors) and ScreenManager (push/pop, 2-modal cap, input mode, console focus, cinematic mode)
- [x] `/uigallery`: every component and variant, Stilts/Car accent toggle
- [x] 16 core icons (SVG source + 256/64 PNG) and `tools/rasterize.py`
- [x] Icon entries in `assets/manifest.json` (32: 256 px + `_64`, pending upload); kit `Icon` props take asset names and show the placeholder card until uploaded
- [ ] Upload the core icons (`tools/upload_assets`, needs the Open Cloud key)
- [x] Wire `Hooks.setSoundHandler` from shared Audio (`audio:bindKit()`)
- Weak spots, honestly: the kit has not been seen in Studio yet. Layout and press feel are written to spec but unverified on a device until the owner opens `/uigallery`. Haptics on phones depend on Roblox's touch motor support, which is limited.
