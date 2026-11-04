# RBLX-shared status

**Phase:** 1, Shared v0.1 (Net, Data, Types, Economy, UI theme + kit + gallery, Assets, Test/Sim harness, CI)
**Version:** 0.1.0 (unreleased)

## Owner to-do
- Nothing right now. After publish: create an Open Cloud key and run the upload command in docs/TOOLING.md.

## Blockers
- None.

## Known weak spots (tooling)
- Image upload type is unverified until a real key exists: images go up as `Decal`, and `verify_assets --remote` will flag it if Roblox returns a non-Image id.
- The custom lint is pattern-based, not a parser; it can miss multi-line calls. Selene and the type checker cover the rest.
- luau-lsp cannot be built in the agents' sandbox, so strict type errors only surface in CI.

## Tooling, CI, harness (`shared/tooling`)
- [x] Repo skeleton: Rojo projects, wally.toml, rokit toolchain pins, StyLua, Selene, `.luaurc`, pre-commit
- [x] GitHub Actions CI: StyLua check, Selene, luau-lsp analyze, lune tests, Rojo build artifact
- [x] Test harness: describe/it runner, matchers, virtual clock + `task` emulation
- [x] Fakes: DataStoreService (failure injection, metadata, ordered stores), MarketplaceService (receipts, replay, retry), Players
- [x] Sim harness: deterministic RNG, scheduler, synthetic players, recorder + CSV/JSON, targets, tuning helpers, Studio/Open Cloud runner shell (`lune run sims`)
- [x] Assets: manifest-backed lookup with visible placeholders, `AssetIds.luau` generation
- [x] Tools: `upload_assets` (Open Cloud, end-to-end tested against a mock), `verify_assets`, `gen_asset_ids`, custom lint (§9.4), shared Open Cloud client
- [x] docs/API.md sections for Test, Sim, Assets; docs/TOOLING.md

## Core (`shared/core`)
- [ ] Types, Net, Data, Economy

## UI kit (`shared/ui`)
- [ ] Theme tokens, kit components, gallery, icons
