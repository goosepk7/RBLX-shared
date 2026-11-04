# RBLXShared.UI

The shared UI kit for both games: theme tokens, components, screen manager,
safe area, feedback hooks, the `/uigallery`, and the core icon set. Built to
brief §5 ("Arcade Workshop"). Game code builds every screen from this kit and
never styles Instances directly.

```luau
local Shared = require(ReplicatedStorage.Packages.RBLXShared)
local UI = Shared.UI

UI.Theme.setGame("stilts") -- or "car"; do this before building any UI

local area = UI.SafeArea.new({ Name = "HUD" })
local screens = UI.ScreenManager.new(area)

UI.Kit.CurrencyPill.new({
	Icon = "icon_wins", -- asset name; pending icons show the placeholder card
	Value = profile.wins,
	OnPlus = function() screens:push("Shop", { tab = "Boosts" }) end,
	Parent = area.anchors.TopLeft,
})
```

## Modules

| Module | What it is | Headless (lune) |
|---|---|---|
| `Tokens` | Every color, size, radius, edge, type size, motion timing, layer. The only place a color literal may appear. | yes |
| `Theme` | Token accessors: `color(name)`, `hex`, `font(role)`, `textSize`, `variant(v)`, `setGame`, `onGameChanged`, and the colorblind palettes: `setPalette("off" | "deuteranopia" | "protanopia" | "tritanopia")`, `getPalette`, `onPaletteChanged` (overrides from `Tokens.colorblind`; only the status colors change). | yes (pure parts) |
| `Color` | Hex parsing, mixing, WCAG contrast. | yes |
| `Layout` | Viewport scale, safe-zone rects, input-mode mapping, grid columns, drawer style. | yes |
| `Format` | `compact` (1.2K), `grouped` (1,234), `delta` (+12), `isBigGain`. The kit shows numbers with `showCompact`/`showGrouped`/`showDelta`, which follow the locale after `loc:bindKit()` (1,2K in pt-br). | yes |
| `Create` | Instance builder + styling primitives (`corner`, `stroke`, `textStroke`, `padding`, `list`, `text`). | no |
| `Motion` | Tweens with the kit's easing vocabulary; `countUp` for animated numbers. | no |
| `Hooks` | `sound(name)` and `haptic(kind)` events. Shared Audio's `bindKit` calls `Hooks.setSoundHandler`. | yes |
| `SafeArea` | Root ScreenGui with `CoreUISafeInsets`, viewport `UIScale`, HUD anchors, banner and toast lanes. | no |
| `ScreenManager` | One screen at a time, push/pop/replace, 2-modal cap, input mode, console focus, cinematic mode. | no |
| `Kit` | Components (below). | `Variants` lists only |
| `Gallery` | `/uigallery`: every component and variant, with a Stilts/Car accent toggle. | stories list only |

## Components (`UI.Kit`)

Each component module has `Variants` (the list the gallery and tests check)
and a constructor. `Icon` props take an asset name from a registered manifest
(`"icon_wins"`), not a content id; the kit resolves it with
`Assets.applyImage`, so an icon that is still pending upload shows its
placeholder card instead of a blank square. Constructors return `(root, handle)`; handles expose
`setDisabled`, `setLoading` where meaningful, and `destroy`.

| Component | Variants | Notes |
|---|---|---|
| `Button` | Primary, Secondary, Success, Danger, Gold, Ghost | 6 px edge; press scales to 0.96 and collapses the edge to 2 px in 0.08 s, springs back in 0.18 s; PC hover lifts 2 px; disabled = 55% opacity, no edge. `Size = "Small"` for rows. |
| `IconButton` | Secondary, Primary, Gold, Danger | 52 px circle for the right rail and top-right; count badge; label tooltip on hover or long-press. |
| `Chip` | Secondary, Primary, Success, Danger, Warning, Info, Gold | 4 px edge; `KeyHint` keycap for prompts ("E Enter Pit"). Interactive when `OnActivated` is set. |
| `Card` | Plain, Elevated, Accent, Inset | 14 px radius, 2 px Line border; Elevated/Accent add the 6 px edge. |
| `Panel` | Primary, Secondary, Danger, Gold | Gradient header strip accent to accent-dark, H2 title, 52 px close; `body` and `footer` slots. |
| `Modal` | Center, Fullscreen | 55% Ink backdrop, pop-in 0.9 to 1 with back-out. Open through `ScreenManager:showModal`. |
| `Drawer` | Sheet, Side | Bottom sheet on touch/portrait, side panel on PC/console. |
| `Confirm` | Default, Destructive, Purchase | Modal + Panel; Destructive is the big red Rebirth confirm. |
| `Tabs` | Primary, Secondary | Pill tabs with a sliding indicator. |
| `ProgressBar` | Primary, Secondary, Success, Danger, Warning, Info, Gold | Two-tone animated fill, optional segment ticks and label. |
| `Stat` | Default, Accent, Gold | Icon + caption + stroked number; counts up on change. |
| `CurrencyPill` | Default, Gold, Accent | Icon + count-up number + "+" (opens shop); spawns a NumberPop on change. |
| `ListRow` | Default, Pinned, Gold, Silver, Bronze | Rank disc, icon, title/subtitle, trailing value or action. Pinned = "your rank". |
| `Grid` | Scroll, Static | Auto-cell grid; columns follow width. |
| `Tooltip` | Ink, Accent | `Tooltip.attach(target, text)`. |
| `TextInput` | Default, Success, Danger | Single-line inset field, 48 px tall: Paper-2 at rest, Info border while focused, Success/Danger border plus a helper line (`setVariant(v, message)`) for results. `MaxLength` counts characters (default 64), `Transform` rewrites typed text (`string.upper` for codes), `OnSubmit` fires on Enter/Done unless Disabled or Loading. Typing again clears a stale result. |
| `Toggle` | Primary, Success | Pill switch with the kit edge in a 52 x 48 hit box; off is Line-dark, on is the accent or Success, and the knob springs over with a click. `OnChanged(value)`; `setValue(v, silent)` for updates from outside. |
| `Slider` | Primary, Secondary | 12 px two-tone track, 32 px knob, 48 px hit box across the whole width. Drag with touch or mouse; D-pad and arrow keys step it. `OnChanged` while moving, `OnCommitted` on release. `Slider.snap` and `Slider.valueAt` are the tested math. |
| `Toast` | Success, Danger, Info, Warning, Gold, Badge | Lane under the banner lane, max 3 visible, auto-dismiss. Use `area.toasts.show`. |
| `Banner` | Primary, Warning, Danger, Success, Info, Gold | Top-center strip, queued, slides in, auto-dismiss. Use `area.banners.show`. |
| `NumberPop` | Gain, Loss, Gold | "+N" rises 56 px with jitter and a scale punch over 0.7 s; gains of 10% or more add confetti and "thump". |
| `Confetti` | Burst, Shower | Token-colored bits; used by NumberPop and win moments. |

## HUD anchors (§5.4)

`SafeArea.anchors` gives every HUD zone a frame with the right layout so
games never place HUD elements by hand: `TopLeft` (stacked currency pills),
`TopCenter` (banner lane lives here), `TopRight` (gear and bag), `RightRail`
(52 px buttons, 8 px gap), `BottomRight` (primary actions in the thumb arc),
`BottomCenter` (prompt chip), `Center`. There is deliberately no bottom-left
anchor: that is the thumbstick zone (`Layout.thumbstickZone`, matching
DynamicThumbstick's left 40% x bottom two-thirds in landscape).

Anchor geometry comes from `Layout.anchors`, and `tests/UI/Layout.spec.luau`
checks every input-sinking anchor against the thumbstick zone at four
viewports, with and without notch insets. `BottomCenter` spans exactly the gap
between the thumbstick zone and the thumb arc (about 170 px on a 6.1" phone),
so prompt chips placed there must pass `MaxWidth` (the anchor's width at
reference scale); longer translations truncate instead of growing into the
stick. The top-left currency pills may overlap the stick zone on phones; that
is safe only because the pill body is not `Active` (see `CurrencyPill`).

Modals and drawers render their content in `area.modalLayer` (safe area, above
the HUD) and their dim/scrim in `area.backdropLayer` (full screen, no insets),
so the 55% dim also covers the notch bands.

`ScreenManager:setCinematic(true)` hides every anchor except the banner lane,
plus screens, modals and toasts, for world unlock, rebirth and Iron Build moments.

## Scale and tap targets

Token sizes are authored for a 6.1" phone in landscape (shorter edge 390 pt).
`SafeArea` applies `UIScale = clamp(shortEdge / 390, 0.92, 1.6)`. The 0.92
floor is chosen so the smallest tappable control (48 px) never renders under
44 px; `tests/UI/Layout.spec.luau` enforces this for every tappable size.

## Feedback hooks

The kit raises `Hooks.sound("click" | "hover" | "open" | "close" | "success" |
"fail" | "thump" | "pop" | "tab" | "toast")`. `audio:bindKit()` (shared Audio)
registers with `Hooks.setSoundHandler` and plays `ui.<name>`, the generated set in
`assets/sfx/`; without it the kit is silent.
`Hooks.haptic("light" | "medium" | "heavy")` pulses gamepad and supported touch
motors; Settings turns it off with `Hooks.setHapticsEnabled(false)`.

## Gallery

```luau
UI.Gallery.bindChatCommand({
	allowedUserIds = { OWNER_USER_ID }, -- Studio is always allowed
})
```

Type `/uigallery` in chat. Every component and variant renders on one
scrolling panel at the device's real UI scale; the tabs at the top switch
between the +1 Stilts and Evolve a Car accents. Transient components (modal,
drawer, confirm, number pop, confetti) have a button that plays them.

## Icons

16 core icons (§5.6) live in `assets/icons/svg/` and are generated by
`tools/icons/build_icons.py` from one style function: solid fills, 2.5 px
outline in Ink at 85%, darker lower third, one 18% white highlight. PNGs are
rasterized by `python3 tools/rasterize.py` (cairosvg) to `assets/icons/png/256`
and `assets/icons/png/64`, and are committed so the uploader can run without
Python. Both sizes are in `assets/manifest.json` (`icon_wins`, `icon_wins_64`).

`icon_wins`, `icon_height`, `icon_cash`, `icon_part`, `icon_rebirth`,
`icon_codes`, `icon_leaderboard`, `icon_shop`, `icon_settings`, `icon_event`,
`icon_star`, `icon_star_empty`, `icon_weight`, `icon_lock`, `icon_check`,
`icon_warning`.

Part-category, material and world/biome emblem icons are game content and
are made in the games' asset threads with the same generator.

## Rules for game code (§5.8)

- No `Color3` literals, no `Enum.Font`, no raw `TextLabel` styling: use
  `Theme.color`, `Create.text`, and kit components.
  `tests/UI/AntiPatterns.spec.luau` enforces this inside `src/UI`; the games'
  custom lint (§9.4) should apply the same rules to game code.
- One primary action per panel: put it in `panel.footer`.
- Never open a modal directly; `ScreenManager:showModal` enforces the cap of 2.
- All strings arrive already localized; the kit never builds player-facing text.
