# PORT PLAN — PR #22 theme-presets onto #17's theming architecture

Target worktree: `/Users/takahiro_ogawa/dev/mercat.themes-on-styles`, branch
`feature/themes-on-style-map` (based on `main` = #17). PR #22 lives on branch
`theme-presets`; read any file with
`git -C /Users/takahiro_ogawa/dev/mercat.themes-on-styles show theme-presets:<path>`.

Build: `cd /Users/takahiro_ogawa/dev/mercat.themes-on-styles && zig build`
Test:  `cd /Users/takahiro_ogawa/dev/mercat.themes-on-styles && zig build test`
zig 0.15.1.

---

## 0. Strategy in one paragraph

PR #22 is not a bolt-on; it is a rewrite of the *same* files #17 owns (`theme.zig`,
`render/types.zig`, `config.zig`, `args.zig`, `main.zig`, `render/blocks.zig`,
`render/table.zig`, `lib/ansi.zig`, `export/layout.zig`, `tui/*`) plus eight new
modules under `src/core/theme/` and `src/core/render/decor.zig`. So the port is:
**adopt #22's engine (registry + `Color` union + sparse spec + `Decor` + diagnostics)
as the target, lift its concrete preset/glyph data verbatim, then re-widen the
slot set and variant surface back to #17's superset** — namely the four structural
color slots #22 dropped, the four `table_border_set` weights it dropped, and the
`syntax_theme=classic` variant it stopped threading. #17's default (un-themed)
output must stay byte-identical, guarded by the ported `decor.legacy` +
`neutralDark/Light` + resolve-side identity tests.

The tree need not compile until the final renderer/config/main/tui slices. Each
slice below lists the files it touches and exactly what data to lift from where.

### The reconciled slot set (the single most important design decision)

`SpanStyle` / `spec.Slot` / `theme.Palette` field lists must all agree (the bake
loop and `token()` are exhaustive/comptime over them). The final set is the
**union** of both branches:

Adopt #22's improved marker taxonomy (its presets and renderers already use it):
`bullet`, `ordered`, `task_on`, `task_off`, `list_item` — these *replace* #17's
`list_marker`, `task_checkbox_done`, `task_checkbox_todo`.

Re-add the four structural **color** slots #22 dropped (its presets even note the
loss — e.g. dracula can't color its hr): `table_border`, `table_header`, `hr`,
`code_fence_banner`. Bake defaults them to `muted` (`table_header`→`body`),
reproducing #17's borrowed-token behavior, but now a preset *may* set them.

Final ordered slot list (40 slots): the 32 shared semantic/frontmatter slots
`heading1..heading6, body, muted, emphasis, strong, strong_emphasis, code,
code_block, code_block_keyword, code_block_string, code_block_number,
code_block_comment, code_keyword, code_string, code_number, code_comment, quote,
link, strikethrough, image_alt, superscript, subscript, highlight,
frontmatter_key, frontmatter_value, frontmatter_cap`, then #22's markers
`bullet, ordered, task_on, task_off, list_item`, then the re-added structural
color slots `table_border, table_header, hr, code_fence_banner`.

### "8 presets" note

PR #22 ships **7** preset specs (`dark, light, ansi, dracula, tokyo-night, pink,
markview`) plus the **`auto`** pseudo-name, which `main.zig` statically maps to
`dark` (no real terminal-background detection exists in #22 — leave a seam but do
not invent it). Those are the 8 user-facing names in the help text and
`default_config.toml`. Treat "all 8 presets' data" as: port the 7 spec tables +
wire `auto`→`dark`. If a literal 8th *spec* is ever wanted it is a one-line add to
`presets.ALL`.

---

## Slice S1 — Color model: `Color` union + `StyleToken` widening

**Goal:** replace `StyleToken.fg_index:u8` / `bg_index:?u8` with `fg:Color` /
`bg:?Color`, and make every consumer read the union.

**Files:**
- NEW `src/core/theme/color.zig` — lift verbatim from
  `theme-presets:src/core/theme/color.zig` (370 lines). Provides
  `Color = union(enum){ default, index:u8, ansi16:Ansi16, rgb:Rgb }`, `idx`,
  `rgb`, `parseColor`, `to256`/`rgbToNearest256`/`nearestCubeLevel`, `toSrgb`,
  `xterm256ToSrgb` (committed table: `cube_levels={0,95,135,175,215,255}`,
  `system_colors[16]`), and the package-level truecolor flag
  (`detectTruecolorFromValue`, `initTruecolor`, `truecolorEnabled`,
  `setTruecolor`).
- `src/core/theme.zig` — change `StyleToken` to `{ fg: Color, bold, italic,
  underline, strikethrough, bg: ?Color = null }`. Add `pub const color =
  @import("theme/color.zig"); pub const Color = color.Color; pub const idx =
  color.idx;` (matches #22's header).
- `src/lib/ansi.zig` — lift #22's `writeColorSgr(writer, c, layer)` and route
  `writeTokenPrefix`/`writeTokenStyled`/`writeHyperlink` through it: `rgb` emits
  `38;2;r;g;b` / `48;2;r;g;b` when `color.truecolorEnabled()` else
  `writeIndexed(color.to256(c))`; `ansi16`→30-37/90-97 (fg), 40-47/100-107 (bg);
  `index`→`38;5;n`; `default`→39/49. Diff against
  `theme-presets:src/lib/ansi.zig`.
- `src/export/layout.zig` — replace `xterm256ToSrgb(style.fg_index)` with
  `color.toSrgb(style.fg) orelse <fallback>` (reuses the same table #22 lifted
  into `color.zig`); do the same for bg. Diff against
  `theme-presets:src/export/layout.zig`.
- `src/core/theme.zig` `vaxisStyle` — map via a `toVaxisColor(c)` helper:
  `default`→`.default`, `index`→`.{.index=n}`, `ansi16`→`.{.index=@intFromEnum}`,
  `rgb`→`.{.rgb=.{r,g,b}}`. Lift #22's version.

**Detail:** this slice breaks every `StyleToken{ .fg_index = N }` literal, but
those literals are about to move into `presets.zig` (S3), so leave the base-palette
constructors temporarily broken — they are rewritten in S3. Keep `toastStyle`/
`metadataPanelStyle` compiling by stubbing (finalized in S12).

---

## Slice S2 — Finalize the reconciled slot set

**Goal:** land the 40-slot union in the three lockstep declarations *before*
porting presets/bake, so the exhaustive/comptime loops cover every slot.

**Files:**
- `src/core/render/types.zig` `SpanStyle` — start from
  `theme-presets:src/core/render/types.zig`'s enum (which already has
  `bullet, ordered, task_on, task_off, list_item` and drops `list_marker`/
  `task_checkbox_*`), then **append** `table_border, table_header, hr,
  code_fence_banner`. Keep #22's doc comments on marker fallback.
- `src/core/theme/spec.zig` `Slot` enum (NEW file, see S3) — mirror the same
  names in the same order; `slot_count` and `fromSpanStyle` follow automatically.
- `src/core/theme.zig` `Palette` struct — mirror the same field names in order.

**Detail:** #22's `Slot.fromSpanStyle` is `stringToEnum(Slot, @tagName(style)).?`
— so `SpanStyle` and `Slot` must be name-for-name identical or it panics at
runtime for the new slots. Verify the four re-added names exist in both.

---

## Slice S3 — Sparse spec + presets data + neutral palettes + `token()`/`palette()`

**Goal:** land the sparse schema and all preset color/glyph data; re-derive the
neutral palettes at comptime; keep the legacy `palette()`/`token()` API.

**Files:**
- NEW `src/core/theme/spec.zig` — lift from `theme-presets:src/core/theme/spec.zig`
  (229 lines): `SlotSpec` (sparse fg,bg,full_line_bg,bold,italic,underline,strike,
  prefix,suffix,shift,blank_wrap,icon,underline_row,underline_glyph), `SlotMap`,
  `GlyphSet`, `CodeFrameSpec{kind,border_glyph,border_cap,pad,language_label,
  rule_color}`, `TokenColors{keyword,string,number,comment,function}`, `ThemeSpec`,
  enums `HrMode{full,fixed}`, `TableStyle`, `CodeFrameKind{panel,rule,block,plain}`,
  `PaletteMode{truecolor_or_256,ansi16}`, plus the `Slot` enum from S2. **Widen
  `TableStyle` here** to `{grid, heavy, double, ascii, rounded}` (S4 uses it).
- NEW `src/core/theme/presets.zig` — lift from
  `theme-presets:src/core/theme/presets.zig` (547 lines) **verbatim**, including
  helpers `a16()`, `ix()`/`idx()`, `withHeadingPrefixes()`, `mergePrefix()`,
  `legacy_glyphs = {quote_bar="\u{258E}"}`, `darkSlots()/lightSlots()` +
  `darkClassic()/lightClassic()` deltas, and `pub const ALL` (dark, light, ansi,
  dracula, tokyo-night, pink, markview). This is the concrete data the whole port
  exists to deliver — do not paraphrase the color tables. Preset anchors to spot-
  check after lift: dark `body.fg=idx(254)`, `code_block_keyword.fg=idx(141)`
  default / `idx(81)` classic; light `body.fg=idx(234)`,
  `code_block_keyword.fg=idx(92)`/`idx(25)` classic; dracula `base_bg=#282a36`
  `heading*=#bd93f9 bold`; tokyo-night `base_bg=#1a1b26` `heading*=#bb9af7`;
  pink accent `#ff87ff`; markview `base_bg=#1e1e2e` with per-heading banded
  `full_line_bg` + `◉◈◇▪▫·` prefixes and `table_style=.rounded`, `bullets=&{"●"}`.
  After lifting, presets set only the 36 slots #22 knew; the four re-added slots
  (`table_border/table_header/hr/code_fence_banner`) stay unset in every preset
  (bake defaults them — see S5). Optionally set dracula/markview `hr` fg later,
  but not required for the port.
- `src/core/theme.zig` — lift #22's `neutralDark = bakeSlots(presets.dark.slots,
  null)`, `neutralLight = bakeSlots(presets.light.slots, null)`, `applySlotToken`,
  `bakeSlots`. In `bakeSlots`, after the `inline for (SpanStyle)` overlay, add the
  #17-parity stamping for the four re-added slots so their neutral defaults borrow
  the same tokens #17 used: `p.table_border = p.muted; p.hr = p.muted;
  p.code_fence_banner = p.muted; p.table_header = p.body;` (only when the preset
  left them unset). Keep `list_item`→`body` fallback (already in #22's `bakeSlots`).
- `src/core/theme.zig` `palette(theme, syntax_theme)` — lift #22's version:
  `switch(theme){ .light => bakeSlots(presets.light.slots, if(classic)
  presets.lightClassicDelta else null), else => bakeSlots(presets.dark.slots,
  ...) }`. This restores `syntax_theme=classic` for the legacy API (S5 threads it
  through resolve too). Note: signature drops #17's `overrides` param (the sparse
  fold replaces the typed merge).
- `src/core/theme.zig` `token()` — extend #22's exhaustive switch with arms for
  the four re-added slots mapping to the identically named `Palette` field.

**Detail:** delete #17's `darkPalette`/`lightPalette` hand-written switches and the
old `ThemeOverrides` comptime-merge loop from `theme.zig` — both are superseded by
`bakeSlots` + the resolver's `applySlot`.

---

## Slice S4 — Resolved decor + restore `table_border_set` weights

**Goal:** land the concrete decor vocabulary and re-add #17's four table weights.

**Files:**
- NEW `src/core/render/decor.zig` — lift from
  `theme-presets:src/core/render/decor.zig` (123 lines): `SlotDecor`,
  `ResolvedGlyphSet` (defaults `bullets=default_bullets={"•","◦","‣"}`,
  `task_ticked="[x]"`, `task_unticked="[ ]"`, `hr_glyph="─"`, `hr_mode=.full`,
  `table_style=.grid`, `code_frame={kind=.panel}`; `bulletAt(depth)` clamps),
  `Decor{slots[slot_count], glyphs}` with `slot()/slotPtr()/headingSlot()`, and
  crucially `pub const legacy: Decor` reproducing #17's `# `..`###### ` heading
  prefixes + `\u{258E}` quote bar. `Options.decor` defaults to `&legacy`.
- `src/core/render/decor.zig` `ResolvedGlyphSet` — since S3 widened `TableStyle`
  to include `heavy/double/ascii`, no new field is needed; the table renderer (S8)
  maps the enum variant to the concrete (horizontal, vertical, cross) triple. Lift
  #17's triples from `config.TableBorderSet.glyphs()` into a small
  `tableTriple(style: TableStyle) Triple` helper in `render/table.zig` (S8),
  covering `light→grid(─│┼)`, `heavy(━┃╋)`, `double(═║╬)`, `ascii(-|+)`,
  and `rounded(─│ + ╭╮╰╯)` from #22's `renderRounded`.

**Detail:** the `legacy` decor is the byte-parity anchor. Do not modify it — the
resolve-side field-by-field test (ported in S14) pins `resolve("dark").decor`
against expectations; if #22's `presets.dark` decor legitimately differs from
`legacy` (e.g. heading1 `underline_row`), that difference is #22's tested intent —
see Risks.

---

## Slice S5 — Registry, fold, bake + thread `syntax_theme=classic`

**Goal:** land the resolver and re-enable the `classic` variant end-to-end.

**Files:**
- NEW `src/core/theme/resolve.zig` — lift from
  `theme-presets:src/core/theme/resolve.zig` (987 lines): `DiagKind`,
  `Diagnostic`, `Collector`, `ResolvedTheme{ palette, decor, mode, accent,
  base_bg, canvas, canvasBg() }`, `Registry{ init, deinit, insertUserSpec,
  lookup, resolve, foldedSpec, buildChain }`, `foldSpecs`, `mergeInto`,
  `mergeSlot`, `mergeGlyphs`, `bake`, `bakeDecor`, `applySlot`, `applyTokens`,
  `builtinResolved`, and re-exports (`ThemeSpec`, `SlotSpec`, `Slot`,
  `PaletteMode`, `RawThemeTables`, `Decor`, `Palette`, `StyleToken`,
  `specFromRaw`). `max_chain=16`, built-ins win name clashes, soft failures never
  fatal (dark fallback).
- `src/core/theme/resolve.zig` `bake` — it already stamps the 36 #22 slots via
  `inline for (SpanStyle)`; because S2 added the four re-added slots to `SpanStyle`
  and S3 added them to `Palette`, `bake`'s loop covers them automatically. Add the
  #17-parity default stamping (mirror of S3's `bakeSlots`): after the overlay,
  `if (folded.slots.get(.table_border)==null) palette.table_border =
  palette.muted;` and likewise `hr`→muted, `code_fence_banner`→muted,
  `table_header`→body. Keep #22's `list_item`→body fallback and `applyTokens`.
- **classic threading (Q5.3):** change `Registry.resolve` (and `bake`) to accept a
  `syntax_theme: config.SyntaxTheme`. When `syntax_theme == .classic` **and** the
  chain root is `dark`/`light`, fold that preset's classic delta
  (`presets.darkClassicDelta`/`lightClassicDelta`, already in `presets.zig`) as an
  extra layer in `foldSpecs` *before* inline overrides. `main`/tui pass
  `loaded_config.display.syntax_theme`. This restores a real #17 feature #22
  silently dropped.

**Detail:** `resolve(name, syntax_theme, inline_overrides, diag)` is the single
entry the whole app calls. `foldedSpec` (used by `--dump-theme`) stays classic-
agnostic (dump is about the named theme's own data).

---

## Slice S6 — Raw TOML theme parsing + user-file discovery

**Goal:** land the one typed parse path and `~/.config/mercat/themes/` discovery.

**Files:**
- NEW `src/core/theme/fromraw.zig` — lift from
  `theme-presets:src/core/theme/fromraw.zig` (241 lines): `specFromRaw(alloc,
  RawThemeTables, diag) ThemeSpec`, plus the PUA guard `safeGlyph`/`containsPua`/
  `isPua` (ranges E000–F8FF, F0000–FFFFD, 100000–10FFFD) that `?`-substitutes
  Nerd-font PUA codepoints and reports `glyph_fallback`.
- NEW `src/core/theme/loadfile.zig` — lift from
  `theme-presets:src/core/theme/loadfile.zig` (409 lines): `RawThemeTables`,
  `RawThemeBuilder` (`set` last-wins), `assignThemeValue`, `parseThemeTables`,
  `splitSection` (split on first `.`), `resolveThemeDir(alloc)`
  (`$XDG_CONFIG_HOME/mercat/themes` → `$HOME/.config/mercat/themes`),
  `readThemeFile(alloc, dir, name)` (1 MiB cap, null on FileNotFound). Note a bare
  top-of-file `extends="..."` lands in the top table; a non-theme header
  (`[display]`) turns collection off.

**Detail:** the four re-added slots must be parseable from `[theme.table_border]`
etc. — confirm `fromraw.specFromRaw` iterates all `Slot` names (it uses
`Slot.fromSpanStyle`/`stringToEnum` over the `Slot` enum, so the four new names
are covered for free). Same for restoring `table_border_set` weights: the
`[theme.glyphs] table_style = "heavy"` key must parse the widened enum — extend
the `table_style` value parser in `fromraw`/`loadfile` to accept
`grid|heavy|double|ascii|rounded`.

---

## Slice S7 — `--dump-theme`

**Files:**
- NEW `src/core/theme/dump.zig` — lift from
  `theme-presets:src/core/theme/dump.zig` (260 lines): `write(w, name, folded)`
  emitting only what `specFromRaw` round-trips (header comments, top-level
  `base_bg/base_fg/canvas/palette`, `[theme.<slot>]` in `Slot` order,
  `[theme.glyphs]`, `[theme.code_frame]`, `[theme.tokens]`); `extends` never
  emitted; custom `bullets` arrays don't round-trip (documented limitation).
- `src/core/theme/dump.zig` — extend the `[theme.<slot>]` emission loop to include
  the four re-added slots (they iterate `Slot` order, so free) and extend
  `table_style` serialization to the widened enum.

**Detail:** wiring of the CLI flag and `runDumpTheme` is in S10/S11.

---

## Slice S8 — Renderer migration: `Glyphs` → `Decor`

**Goal:** the bulk of consumption. Replace `Options.glyphs: Glyphs` with
`Options.decor: *const Decor = &legacy` and migrate every emit site. Also emit the
four re-added SpanStyles.

**Files:**
- `src/core/render/types.zig` — replace the `Glyphs` struct + `Options.glyphs`
  with `Options.decor: *const decor.Decor = &decor.legacy` and
  `Options.truecolor: bool = false` (threaded to backends). Delete
  `Glyphs`/`fromDisplay`. Diff against `theme-presets:src/core/render/types.zig`.
- `src/core/render/blocks.zig` — lift #22's version wholesale
  (`theme-presets:src/core/render/blocks.zig`). It already reads
  `options.decor.slot(...)` / `options.decor.glyphs.*`, uses `bullet/ordered/
  task_on/task_off/list_item`, heading `prefix`/`shift`/`blank_wrap`/
  `underline_row`, hr via `glyphs.hr_glyph`/`hr_mode`/`hr_count`/`hr_center`, and
  the `CodeFrameSpec` flavors (panel/rule/block/plain + `language_label`).
  **Then re-add** the structural color SpanStyles: emit `.hr` (not `.muted`) for
  the rule, `.code_fence_banner` for the fence banner. Grep #22's `blocks.zig` for
  where it currently uses `.muted`/`.code` for those and switch to the re-added
  slots (they still default to muted via bake, so byte-parity holds).
- `src/core/render/table.zig` — lift #22's version
  (`theme-presets:src/core/render/table.zig`: `renderGrid`/`renderRounded`
  switched on `decor.glyphs.table_style`). **Then:** (a) add `tableTriple(style)`
  mapping the widened `TableStyle` to #17's (h,v,cross) triples so `heavy/double/
  ascii` render again; (b) replace the hardcoded `.muted` border spans with
  `.table_border` and header cells `.body`→`.table_header` (both default to the
  same tokens, preserving parity, but now themable).
- `src/core/render/inline.zig` — lift #22's version for link/image `icon`,
  `prefix`/`suffix` on `code`, etc. Diff against
  `theme-presets:src/core/render/inline.zig`.
- `src/core/render_model.zig`, `src/core/render/frontmatter.zig`,
  `src/core/render/builder.zig`, `src/core/render/wrap.zig` — diff against
  theme-presets; adopt any signature changes (`decor` threading, `doc_margin`).

**Detail:** trailing space after bullet/checkbox markers stays a renderer concern
(#22 keeps it there). The `legacy` default guarantees existing goldens hold for
the un-themed path.

---

## Slice S9 — Config surface + `default_config.toml`

**Files:**
- `src/core/config.zig` — adopt `theme-presets:src/core/config.zig`:
  - `Theme = enum { auto, dark, light }` (internal base-palette selector only;
    kept for the legacy `palette()` API + export/renderer test call sites).
  - `SyntaxTheme = enum { default, classic }` — **keep** (S5 threads `classic`).
  - `Display.theme: []const u8 = "auto"` (owned, free-form name); `deinit` frees
    it. Remove #17's flat `[display]` glyph keys (`quote_bar`, `bullet_glyphs`,
    `hr_glyph`, `task_checked`, `task_todo`, `table_border_set`, `heading_prefix`)
    and their deinit frees — they are superseded by `[theme.*]`/`[theme.glyphs]`.
  - `raw_theme: RawThemeBuilder = .{}` on `Config`; route dotted `[theme.<slot>]`
    parsing to `loadfile.assignThemeValue` (replaces #17's typed
    `ThemeOverrides`/`assignThemeOverride`). Delete `StyleOverride`/
    `ThemeOverrides`.
  - `FrontmatterStyle{panel,dim,compact,raw,hidden}` unchanged.
  - Env: `MERCAT_THEME` (free-form → `replaceString`), `MERCAT_WIDTH`,
    `MERCAT_SYNTAX_THEME`, `MERCAT_FRONTMATTER`, `MERCAT_SUBGRAPH_EDGES` (adopt
    #22's `applyEnvOverrides`).
- `src/core/default_config.toml` — replace with
  `theme-presets:src/core/default_config.toml` (documents `theme="auto"`, the
  preset list, and the inline `[theme.*]`/`extends` mechanism). **Amend the
  comment block** to also document (a) `table_style` now accepts
  `grid|heavy|double|ascii|rounded` (restored weights) and (b) that the old flat
  `[display]` glyph keys are removed — point migrating users at `[theme.glyphs]`.
- `config/default.toml` — mirror the sparse variant from theme-presets
  (`theme="auto"`).

**Detail:** `TableBorderSet` enum in config.zig may be deleted (its triples move
into `render/table.zig`'s `tableTriple`), or kept purely as the triple source that
`tableTriple` imports — prefer the latter to avoid duplicating the box-drawing
literals.

---

## Slice S10 — CLI args

**Files:**
- `src/cli/args.zig` — adopt `theme-presets:src/cli/args.zig`:
  `style: ?[]const u8` (`--style <name>`, free-form), `dump_theme: ?[]const u8`
  (`--dump-theme <name>`), `effectiveTheme(config_theme) []const u8 = style
  orelse config_theme`. Keep `monochrome`. Update help text to list
  `auto, dark, light, ansi, dracula, tokyo-night, pink, markview, or a user theme
  name`. Delete #17's `ThemeOverride` enum + enum-mapping `effectiveTheme`.

---

## Slice S11 — main.zig wiring

**Files:**
- `src/main.zig` — adopt `theme-presets:src/main.zig`'s theme section:
  1. `theme_color.initTruecolor(allocator)` once (reads `$COLORTERM`).
  2. `--dump-theme` branch → `runDumpTheme(allocator, name)` (builds registry incl.
     user themes, `foldedSpec` fails hard with `unknown_theme` + `exit(1)`, writes
     TOML to stdout, diagnostics to stderr).
  3. Build `Registry`, `loadUserThemes(arena, &registry, &diag)` (process-lifetime
     arena; iterate theme dir, `specFromRaw` each `<stem>.toml`, filename wins
     identity, `insertUserSpec`).
  4. `theme_name = effectiveTheme(display.theme)`; `if eql "auto" → "dark"`.
  5. Build `inline_overrides` from `loaded_config.raw_theme`.
  6. `resolved = registry.resolve(theme_name, display.syntax_theme,
     inline_overrides, &diag)` — **note the added `syntax_theme` arg (S5)**.
  7. Thread a single `&resolved: *ResolvedTheme` into `tui.run`, the CLI render
     `Options{ .decor = &resolved.decor, .truecolor =
     theme_color.truecolorEnabled(), ... }`, `renderer.serialize(..,
     resolved.palette)` with `renderer.Canvas` from `resolved.canvasBg()`, and
     `export_layout.Options{ .palette = resolved.palette, .canvas_bg =
     resolved.canvasBg(), .color_mode = monochrome ? .monochrome : .theme }`.
  8. Emit `themeWarning(&diag)` to stderr as dim comment lines.

**Detail:** this collapses #17's `(active_theme, syntax_theme, theme_overrides,
Glyphs.fromDisplay)` arg quartet into one `*ResolvedTheme` — a net simplification.

---

## Slice S12 — TUI threading + overlay panel styling

**Files:**
- `src/tui/app.zig` — `App.init` / `run()` take `resolved: *const ResolvedTheme`
  instead of #17's four theme args; `toVaxisSegments(alloc, line, palette)` reads
  `resolved.palette`; row painting/canvas fill uses `resolved.canvasBg()`. Diff
  against `theme-presets:src/tui/app.zig`.
- `src/tui/views/pager.zig` — `PagerView` stores `*const ResolvedTheme` (drop the
  separate `palette`/`glyphs`/`theme_overrides` fields); `reflow` passes
  `.decor = &resolved.decor`, `.truecolor = ...` into `renderDocument`. Diff
  against `theme-presets:src/tui/views/pager.zig`.
- `src/core/theme.zig` `toastStyle`/`metadataPanelStyle` — replace with #22's
  `panelStyle(accent, base_bg, bold)` deriving from `ResolvedTheme.accent`/
  `base_bg`, so all 7 presets get matching overlays (not just dark/light). Update
  the `metadata`/`help`/`statusbar` call sites accordingly.

---

## Slice S13 — Docs

**Files:**
- `theme-guide.md` (repo root) — lift from `theme-presets:theme-guide.md`: a
  single demo doc with a section per themeable element, meant to be viewed under
  different `--style` values (headings incl. `underline_row`/`underline_glyph`,
  inline, blockquote `quote_bar`/`quote_indent`, lists incl. `list_item`→body
  fallback note, table incl. rounded, hr full/fixed, code block tokens +
  code_frame flavors, canvas, closing full slot list). **Amend** the closing slot
  list to include the four re-added slots (`table_border, table_header, hr,
  code_fence_banner`) and document the restored `table_style` weights
  (`heavy/double/ascii`).
- `README.md` / `CHANGELOG.md` — port the theme-system section + a migration note:
  flat `[display]` glyph keys removed → use `[theme.glyphs]`; `--style` /
  `--dump-theme` / user theme files under `~/.config/mercat/themes/`.

---

## Slice S14 — Tests (final slice; tree must compile & pass here)

**Files & work:**
- **Base-palette call sites (~30):** every `theme.palette(.dark, .default, .{})`
  drops the third arg → `theme.palette(.dark, .default)`. Grep all of `src/` and
  `src/export/export_test.zig`. #17's `overrides`-carrying calls disappear.
- **`theme.zig` tests:** delete #17's "structural slot defaults equal legacy
  borrowed tokens" and "palette override changes only the targeted slot" (the
  override path moved to resolve). Port #22's `theme.zig` tests. Add a test that
  the four re-added slots bake to `muted`/`body` by default (byte-parity for the
  un-themed path).
- **`resolve.zig` tests:** port #22's guard suite — `resolve("dark"/"light")`
  equals the historical 35-slot palette (now 40-slot; extend the expected table),
  every preset resolves with **zero diagnostics**, `decor.legacy` field-by-field
  equality, extends-chain fold, cycle/missing-extends diagnostics. Add a new test:
  `resolve("dark", .classic, ...)` changes `code_block_keyword` to the classic
  index (proves S5's classic threading).
- **`dump.zig` tests:** port #22's round-trip proofs (dark/light/dracula/
  tokyo-night/pink round-trip through the real `loadfile` parser, zero
  diagnostics, byte-identical palettes). Ensure the four re-added slots and the
  widened `table_style` serialize/parse.
- **`config.zig` tests:** replace #17's `[theme.<slot>]`-into-`ThemeOverrides`
  tests with raw-builder tests (`raw_theme` captures the tables); update
  `[display]` tests (glyph keys removed); `theme` default is now `"auto"` string;
  `MERCAT_THEME` free-form.
- **`fromraw`/`loadfile` tests:** port PUA `assertNoPua` + `glyph_fallback`
  substitution tests; user-file discovery; `table_style` widened-enum parse.
- **`color.zig` tests:** port the cube-anchor round-trip (`to256`/`toSrgb`) and
  `detectTruecolorFromValue` tests.
- **Goldens:** un-themed goldens must be unchanged (legacy decor + neutral
  palettes). If any golden shifts, it means the `legacy`/neutral parity is broken
  — fix the port, do not re-bless. See Risks re: `auto`→dark default.

---

## Cross-cutting invariants to hold (all have #22 guard tests — keep them)

1. Un-themed output byte-identical: `Options.decor = &decor.legacy`,
   `neutralDark/Light` derived from `presets.dark/light.slots`, serialize
   coalescing of equal tokens.
2. `resolve("dark"/"light")` == historical palette across all slots (extend the
   expected table to the 40-slot union; the four re-added slots default to
   muted/body).
3. Every built-in preset resolves with zero diagnostics.
4. `--dump-theme` round-trips through the real parser for the round-trippable
   presets.
5. `syntax_theme=classic` again changes `code_block*` colors end-to-end (S5).
6. The four `table_border_set` weights render again via the widened `TableStyle`
   (S4/S8).

---

## Risks

- **`auto`→dark default vs #17's `dark` default with `underline_row`.** #22's
  `presets.dark` sets `heading1.underline_row=true, underline_glyph="‾"`, but
  #17's `decor.legacy` (the un-themed default) has no underline row. Since #22's
  shipped default is `theme="auto"`→resolve("dark")→`presets.dark.decor`, selecting
  the default may add an underline row that #17's current default output lacks.
  Decide explicitly: either (a) accept #22's richer dark heading as the new default
  (re-bless goldens once, consciously), or (b) strip `underline_row` from
  `presets.dark`/`light` so resolved-dark == `legacy`. Recommend (b) to preserve
  strict byte-parity with #17's current default, and let users opt into underline
  rows via `[theme.heading1] underline_row=true`. Confirm against #22's own
  legacy-parity test to see which #22 actually chose.
- **PNG path is the sharpest color-model edge.** `export/layout.zig` and
  `png_encode` must go through `color.toSrgb`; a missed `fg_index` read will
  mis-color or crash. Mitigated by the shared xterm256→sRGB table.
- **`Slot`/`SpanStyle`/`Palette` name drift.** `fromSpanStyle` panics (`.?`) if a
  `SpanStyle` name has no matching `Slot`. The four re-added slots must be added to
  all three in the same slice (S2/S3) before any bake runs.
- **Dropped compatibility (flat `[display]` glyph keys).** Removing
  `quote_bar`/`bullet_glyphs`/`hr_glyph`/`task_checked`/`task_todo`/
  `table_border_set`/`heading_prefix` from `[display]` is a config-format break for
  existing #17 users. It is expressible via `[theme.glyphs]`, but must be called
  out in the migration note (S13) — this is a deliberate compatibility decision,
  not an accident.
- **`syntax_theme` deprecation vs re-enable tension.** #22 marks `syntax_theme`
  deprecated; S5 re-enables `classic`. Keep it working but documented as a legacy
  variant selector layered under the theme system, to avoid a confusing
  half-deprecated surface.
- **`table_border_set` restoration touches #22's `renderRounded` assumptions.**
  #22 hardcodes rounded box glyphs; folding four more weights into one `TableStyle`
  switch + a triple map must not regress rounded. Cover all five variants in a
  table test.
