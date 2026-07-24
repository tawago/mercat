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
- **Themes**: Dark and light
- **Pager support**: Pipe through $PAGER or `less -R`
- **Stdin support**: `cat file.md | mercat -`
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
mercat --style dark README.md # Force dark theme
cat file.md | mercat -        # Read from stdin

```

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
theme = "dark"       # dark, light
width = 0            # 0 = terminal width
heading_markers = true

# Structural glyphs (a trailing space is appended after markers automatically)
quote_bar = "▎"
bullet_glyphs = ["•", "◦", "‣"]   # cycled by nesting depth
hr_glyph = "─"
task_checked = "[x]"
task_todo = "[ ]"
table_border_set = "light"        # light, heavy, double, ascii
heading_prefix = "#"

[files]
extensions = ["md", "markdown", "mdown", "mkd"]

# Per-element color overrides (xterm-256 fg/bg indices; all keys optional:
# fg, bg, bold, italic, underline, strikethrough). Use any of the following
# 35 slots as [theme.<slot>]:
#   heading1, heading2, heading3, heading4, heading5, heading6,
#   body, muted, emphasis, strong, strong_emphasis,
#   code, code_block, code_block_keyword, code_block_string,
#   code_block_number, code_block_comment,
#   code_keyword, code_string, code_number, code_comment,
#   quote, link, strikethrough, image_alt, superscript, subscript, highlight,
#   list_marker, table_border, table_header,
#   task_checkbox_done, task_checkbox_todo, hr, code_fence_banner
[theme.heading1]
fg = 81
bold = true
```

Environment overrides: `MERCAT_THEME`, `MERCAT_WIDTH`

## Status

**In Progress**: Mermaid ASCII diagram rendering.

**Planned**: more TUI features, in-document search, file watching.

## Development

```bash
zig build
zig build test
```

The public repository keeps contributor-facing tests. Maintainers may also run additional internal validation before releases.
