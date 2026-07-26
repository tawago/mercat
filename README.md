# mercat — cat for markdown, with mermaids

A fast terminal markdown viewer with best-in-class mermaid diagram rendering, written in Zig.

[![CI](https://github.com/tawago/mercat/actions/workflows/ci.yml/badge.svg)](https://github.com/tawago/mercat/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/tawago/mercat)](https://github.com/tawago/mercat/releases)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

## Installation

### Homebrew

```bash
brew install tawago/tap/mercat
```

Works on both macOS and Linux.

### Debian/Ubuntu and Fedora/RHEL

`.deb` and `.rpm` packages are attached to each
[release](https://github.com/tawago/mercat/releases):

```bash
sudo apt install ./mercat_<version>_amd64.deb   # Debian/Ubuntu
sudo dnf install ./mercat-<version>.x86_64.rpm  # Fedora/RHEL
```

### Installer Script

```bash
curl -fsSL https://raw.githubusercontent.com/tawago/mercat/main/install.sh | bash
```

### Direct Download

Release archives are published at:

`https://github.com/tawago/mercat/releases`

### Build From Source

Requires Zig 0.15.1+.

```bash
zig build -Doptimize=ReleaseFast
# Binary at ./zig-out/bin/mercat
```

## Features

- **CLI mode**: Render markdown with syntax highlighting to stdout
- **TUI mode**: Interactive pager with vim-style navigation
- **Editor integration**: Press `e` to edit in $EDITOR, auto-reloads on return
- **Themes**: Seven built-in presets (`dark`, `light`, `ansi`, `dracula`, `tokyo-night`, `pink`, `markview`) plus user theme files with per-slot color and glyph control
- **Pager support**: Pipe through $PAGER or `less -R`
- **Stdin support**: `cat file.md | mercat` (implicit; `-` still works)
- **Bare Mermaid**: pipe raw diagram source with no ```` ```mermaid ```` fence
- **GFM support**: Tables, task lists, fenced code blocks, strikethrough

## Usage

```bash
# TUI mode
mercat -t README.md           # View file in TUI
mercat -t .                   # Browse directory (WIP)

# CLI mode
mercat README.md              # Render to stdout
mercat -p README.md           # Pipe through pager
mercat -w 80 README.md        # Fixed width
mercat --style dracula README.md   # Pick a built-in preset or user theme
mercat --dump-theme dark      # Print a theme as editable TOML
cat file.md | mercat          # Read from stdin (no `-` needed)
cat file.md | mercat -        # Explicit stdin

# Mermaid
mercat diagram.mmd            # .mmd / .mermaid files render as one diagram
printf 'flowchart LR\n  A-->B\n' | mercat   # bare diagram source, no fence
```

With no file argument, mercat reads stdin whenever it is a pipe or redirect;
when stdin is an interactive terminal it prints the usage text and exits 1.

Piped input is sniffed: if it carries no ```` ```mermaid ```` fence and its
first non-blank, non-`%%` line begins at column 0 with a diagram keyword
(`sequenceDiagram`, `classDiagram`, `erDiagram`, `stateDiagram[-v2]`, or
`flowchart`/`graph` followed by a direction such as `TD`/`LR`), the whole
input is rendered as a single Mermaid diagram. An indented first line stays
markdown, since indentation there means "code block".

## TUI Key Bindings

| Key | Action |
|-----|--------|
| `j` / `k` | Scroll down / up |
| `g` / `G` | Go to top / bottom |
| `Space` / `b` | Page down / up |
| `e` | Open in $EDITOR |
| `r` | Reload file |
| `?` or `h` | Toggle help |
| `q` | Quit |

## Configuration

Config file: `~/.config/mercat/config.toml`

```toml
[general]
editor = "vim"
pager = "less -R"

[display]
theme = "dark"       # dark, light, ansi, dracula,
                     # tokyo-night, pink, markview, or a user theme name
width = 0            # 0 = terminal width
heading_markers = true
# YAML front matter display: panel (default), dim, compact, raw, hidden
frontmatter = "panel"

[files]
extensions = ["md", "markdown", "mdown", "mkd"]
```

### Theming

mercat resolves colors and glyphs through a single theme system. Pick a theme
with `theme = "<name>"` in `[display]`, the `--style <name>` flag, or the
`MERCAT_THEME` environment variable. Built-in names are `dark`, `light`,
`ansi`, `dracula`, `tokyo-night`, `pink`, and `markview`.

Every themable element is a **slot**. Override any slot inline in
`config.toml`, or in a standalone theme file. Colors accept an xterm-256 index,
an ANSI-16 name, or a `#rrggbb` truecolor value; every key is optional:

```toml
[theme.heading1]
fg = 81
bold = true
underline_row = true      # draw a full-width rule under the heading
underline_glyph = "═"

[theme.glyphs]
quote_bar = "▎"
bullets = ["•", "◦", "‣"]        # cycled by nesting depth
hr_glyph = "─"
task_ticked = "[x]"
task_unticked = "[ ]"
table_style = "grid"             # grid, heavy, double, ascii, rounded
```

The full slot list (40 slots) and per-element documentation live in
[`theme-guide.md`](theme-guide.md); open it under different styles to see each
element change, e.g. `mercat --style dracula theme-guide.md`.

**User theme files.** Drop `<name>.toml` in `~/.config/mercat/themes/`
(or `$XDG_CONFIG_HOME/mercat/themes/`) and select it by its filename stem. A
theme can start from any built-in with `extends = "dark"` and override only the
slots it wants. Generate an editable starting point with:

```bash
mercat --dump-theme dark > ~/.config/mercat/themes/mine.toml
mercat --style mine README.md
```

Environment overrides: `MERCAT_THEME`, `MERCAT_WIDTH`, `MERCAT_SYNTAX_THEME`,
`MERCAT_FRONTMATTER`.

## Status

**In Progress**: Mermaid ASCII diagram rendering.

**Planned**: more TUI features, in-document search, file watching.

## Development

```bash
zig build
zig build test
```

The public repository keeps contributor-facing tests. Maintainers may also run additional internal validation before releases.
