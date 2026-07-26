# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Themes

- **New theme system.** Colors and glyphs now resolve through a single slot-based
  theme engine. Seven built-in presets ship: `dark`, `light`, `ansi`, `dracula`,
  `tokyo-night`, `pink`, and `markview`.
- **`--style <name>`** selects any preset or user theme at the command line;
  `[display] theme` and `MERCAT_THEME` accept the same free-form names (default
  `"dark"`).
- **`--dump-theme <name>`** prints a resolved theme as editable TOML.
- **User theme files.** Drop `<name>.toml` in `~/.config/mercat/themes/`
  (or `$XDG_CONFIG_HOME/mercat/themes/`) and select it by filename. Themes may
  `extends = "<preset>"` and override only the slots they want.
- Any of the 40 slots is overridable inline via `[theme.<slot>]`; structural
  glyphs live under `[theme.glyphs]` (`quote_bar`, `bullets`, `hr_glyph`,
  `task_ticked`/`task_unticked`, `table_style`). Colors accept xterm-256 indices,
  ANSI-16 names, or `#rrggbb` truecolor values.

### Breaking

- **The flat `[display]` glyph keys have been removed:** `quote_bar`,
  `bullet_glyphs`, `hr_glyph`, `task_checked`, `task_todo`, `table_border_set`,
  and `heading_prefix`. Move them under `[theme.glyphs]` (and per-heading
  `prefix` keys). See the migration table in the README. `table_border_set`
  becomes `table_style`, which accepts `grid` (formerly `light`), `heavy`,
  `double`, `ascii`, and the new `rounded`.

## [0.2.0]

- **Complete rewrite of the flowchart renderer** (`mermaid_v2`): new parse → semantic graph → sketch → raster → paint pipeline with width-budget candidate selection
- Project renamed from `mdv` to `mercat`; the installed binary is now `mercat`
- Config path moved to `~/.config/mercat/config.toml` (the old `~/.config/mdv/` location is no longer read)
- Environment variables renamed `MDV_*` → `MERCAT_*` (e.g. `MERCAT_THEME`, `MERCAT_WIDTH`, `MERCAT_SYNTAX_THEME`)

## [0.1.2]

- Automate Homebrew tap updates after successful tagged releases
- Improve README install ordering and add project badges

## [0.1.1]

- Fix CI and release workflows for published binaries
- Keep installer and release automation aligned with the public GitHub repository
- Support maintainer-only internal validation from a sibling checkout

## [0.1.0]

- Initial planned public release
- CLI markdown rendering with syntax highlighting
- TUI pager with vim-style navigation
- Theme selection, pager support, config loading, and stdin support
