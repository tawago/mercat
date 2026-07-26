# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.2.1]

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

### Front matter

- **YAML front matter renders as metadata** instead of leaking into the document
  as fake headings and horizontal rules. The offset-0 fence is peeled off before
  markdown parsing and carried as a dedicated block.
- Display styles via `[display] frontmatter`, the `--frontmatter` flag, or
  `MERCAT_FRONTMATTER`: `panel` (default), `dim`, `compact`, `raw`, `hidden`.
- TUI: `m` toggles a top-right metadata overlay listing the front matter entries.

### Input

- **Implicit stdin.** With no file argument, mercat reads stdin whenever it is a
  pipe or redirect; `-` still works. An interactive terminal prints usage and
  exits 1.
- **Bare Mermaid sources.** `.mmd`/`.mermaid` files render as a single diagram,
  and piped input whose first meaningful line starts at column 0 with a diagram
  keyword is rendered as a diagram with no ```` ```mermaid ```` fence needed.

### Packaging

- Releases now attach `.deb` and `.rpm` packages alongside the tarballs.

### Fixed

- v2 lexer rejected tight inline edge labels such as `-.text.->`.

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
