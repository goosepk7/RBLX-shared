# Decisions

Defaults chosen where the brief is silent. Newest last.

| Date | Area | Decision | Why |
|---|---|---|---|
| 2026-11-04 | Repo | `main` created with an initial commit; all work lands by PR. | The repo was empty; PRs need a base branch. |
| 2026-11-04 | Layout | `src/` is the `RBLXShared` ModuleScript (`src/init.luau`); one folder per module. | Same tree whether consumed by Wally or the `Packages/RBLXShared` submodule, so import paths never change. |
| 2026-11-04 | Requires | Inside `src/`, only relative require-by-string (`./X`, `../X`, `@self/X`). | Works identically in Roblox and lune, so every module is unit-testable headlessly. Verified on lune 0.11.1. |
| 2026-11-04 | Purity | No service access or side effects at require time; services, `task`, and `Enum` values are injected with lazy Roblox defaults. | Lune has no `game`, `task`, or `Enum`, and globals cannot be injected into required modules. |
| 2026-11-04 | Tests | Spec files are `tests/**/*.spec.luau`, registered at require time; `lune run tests [filter]`. A committed `T.only` fails CI. | Familiar describe/it shape; filter for quick local loops. |
| 2026-11-04 | Toolchain | rokit (`rokit.toml`) pins rojo 7.7.1, lune 0.11.1, StyLua 2.6.0, Selene 0.31.0, luau-lsp 1.70.0, wally 0.3.2. | Node-free, one install command, same versions locally and in CI. |
| 2026-11-04 | Tools | Lune tools use `.luau` (`lune run tools/upload_assets --all`). | Lune resolves the extension; keeps one source extension in the repo. |
| 2026-11-04 | Wally | `registry` points at `goosepk7/wally-index` (to be created); games use the submodule until then. | Brief §1.2 / §13.3 default. |
| 2026-11-04 | Sim | RNG is xoshiro128** seeded by FNV-1a + splitmix32 in pure 32-bit integer math; golden values pinned in tests. | Identical streams in lune, Studio and live servers; `math.random`/`Random` are not portable. |
| 2026-11-04 | Sim | `rng:fork(label)` derives from the seed, not the stream position. | Adding draws to one player's stream never shifts another's, so sims stay comparable across edits. |
| 2026-11-04 | Sim | Populations use exact quotas (largest remainder), not random sampling, for the 40/40/20 mix. | Removes sampling noise from balance comparisons. |
| 2026-11-04 | Sim | Sims are `sims/**/*.sim.luau` returning a `Sim.Runner` definition; outputs go to `sims/out/` (gitignored, uploaded as a CI artifact). | One definition runs under lune, in Studio, and as an Open Cloud Luau Execution task. |
