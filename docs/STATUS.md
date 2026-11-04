# RBLX-shared status

**Phase:** 1, Shared v0.1 (Net, Data, Types, Economy, UI theme + kit + gallery, Assets, Test/Sim harness, CI)
**Version:** 0.1.0 (unreleased)

## Owner to-do
- Nothing right now.

## Blockers
- None.

## Tooling, CI, harness (`shared/tooling`)
- [x] Repo skeleton: Rojo projects, wally.toml, rokit toolchain pins, StyLua, Selene, `.luaurc`, pre-commit
- [x] GitHub Actions CI: StyLua check, Selene, luau-lsp analyze, lune tests, Rojo build artifact
- [x] Test harness: describe/it runner, matchers, virtual clock + `task` emulation
- [x] Fakes: DataStoreService (failure injection, metadata, ordered stores), MarketplaceService (receipts, replay, retry), Players
- [x] Sim harness: deterministic RNG, scheduler, synthetic players, recorder + CSV/JSON, targets, tuning helpers, Studio/Open Cloud runner shell (`lune run sims`)
- [ ] Assets: manifest-backed lookup with visible placeholders, `AssetIds.luau` generation
- [ ] Tools: `upload_assets`, `verify_assets`, custom lint (§9.4)
- [ ] docs/API.md sections for Test, Sim, Assets

## Core (`shared/core`)
- [ ] Types, Net, Data, Economy

## UI kit (`shared/ui`)
- [ ] Theme tokens, kit components, gallery, icons
