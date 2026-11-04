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
| 2026-11-04 | Assets | Manifest entries are one file each; size variants are separate entries with a `_<px>` suffix (`icon_wins_64`), resolved by `Assets.variant`. `source` means origin (generated/creator-store/manual); the editable file is `sourceFile`. | Flat list maps 1:1 to uploads; §10 uses `source: "creator-store"`. |
| 2026-11-04 | Assets | Pending assets render as a colored card with the asset name; unknown names warn once (throw in strict mode); `lint` fails CI on unknown literal names. | Brief §1.5: nothing silently breaks. |
| 2026-11-04 | Tools | One Open Cloud client (`tools/lib/opencloud.luau`) for uploads, backups and Luau Execution. Idempotent methods retry 429 (Retry-After), 5xx and network errors; POST/PATCH/multipart retry only 429 and network errors. Keys only from env, never sent to signed CDN URLs. | One place to get auth and retries right; a 5xx on a create may still have created the asset, so retrying it could upload duplicates. |
| 2026-11-04 | Tools | Images upload as Open Cloud `Decal`; the returned id is kept as `decalId` and the wrapped Image id is resolved before `status = "uploaded"`. Failed resolution saves `unresolved` (renders as pending); `tools/resolve_decals` finishes it without re-uploading. Animations are listed for manual Studio upload. | ImageLabels need the Image id, not the Decal id; the Assets API has no animation type. |
| 2026-11-04 | Assets | `Assets.get` returns `""` while an asset is pending or unresolved; the visible placeholder card comes only from `Assets.image` / `Assets.applyImage`. | A content-id property can't hold a placeholder, and `""` renders blank rather than as a broken or wrong image; UI code that wants a visible stand-in uses the image helpers. |
| 2026-11-04 | UI | Token sizes are authored for a 390 pt short edge; `UIScale = clamp(short/390, 0.92, 1.6)`. | 0.92 keeps the smallest tappable control (48 px) at or above the 44 px minimum on small Androids; 1.6 stops tablets/PC turning the HUD into billboards. |
| 2026-11-04 | UI | White label text on saturated fills gets a 1.5 px stroke in the fill's edge color; Warning and Gold fills use Ink text. | The brief's white-on-orange/green fails contrast on its own (about 2:1); the stroke keeps the look and makes it readable. |
| 2026-11-04 | UI | Disabled dimming walks descendants and blends transparency instead of using CanvasGroup. | A CanvasGroup per button is a render target each; too much texture memory on mid-range phones. |
| 2026-11-04 | UI | Kit sounds go through `UI.Hooks`; Audio registers a handler in v0.2. | UI ships in v0.1 before Audio; avoids a circular dependency. |
| 2026-11-04 | UI | `SecondaryEdge` accents (`#4A3DB8` Stilts, `#C77606` Car) and `inkSoft`/`lineDark` were added to the tokens. | The brief gives no edge for secondary fills or Paper buttons; derived by darkening ~22% toward Ink. |
| 2026-11-04 | UI | Icon PNGs are committed next to their SVG sources. | The uploader and owner can work without Python; SVGs stay the source of truth. |
| 2026-11-04 | UI | Gallery stories live in `src/UI/Gallery/Stories.luau` (not `tests/ui_stories.lua`). | `/uigallery` must run in the shipped game; `tests/UI/Stories.spec.luau` checks every variant has a story. |
