# mdv

A fast terminal markdown viewer written in Zig.

[![CI](https://github.com/tawago/mdv/actions/workflows/ci.yml/badge.svg)](https://github.com/tawago/mdv/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/tawago/mdv)](https://github.com/tawago/mdv/releases)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

## Installation

### Homebrew

```bash
brew tap tawago/homebrew-mdv
brew install mdv
```

### Installer Script

```bash
curl -fsSL https://raw.githubusercontent.com/tawago/mdv/main/install.sh | bash
```

### Direct Download

Release archives are published at:

`https://github.com/tawago/mdv/releases`

### Build From Source

Requires Zig 0.15.1+.

```bash
zig build -Doptimize=ReleaseFast
# Binary at ./zig-out/bin/mdv
```

## Features

- **CLI mode**: Render markdown with syntax highlighting to stdout
- **TUI mode**: Interactive pager with vim-style navigation
- **Editor integration**: Press `e` to edit in $EDITOR, auto-reloads on return
- **Themes**: Dark, light, and auto (terminal background detection)
- **Pager support**: Pipe through $PAGER or `less -R`
- **Stdin support**: `cat file.md | mdv -`
- **GFM support**: Tables, task lists, fenced code blocks, strikethrough

## Usage

```bash
# TUI mode
mdv -t README.md           # View file in TUI
mdv -t .                   # Browse directory (WIP)

# CLI mode
mdv README.md              # Render to stdout
mdv -p README.md           # Pipe through pager
mdv -w 80 README.md        # Fixed width
mdv --style dark README.md # Force dark theme
cat file.md | mdv -        # Read from stdin

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

Config file: `~/.config/mdv/config.toml`

```toml
[general]
editor = "vim"
pager = "less -R"

[display]
theme = "auto"       # auto, dark, light
width = 0            # 0 = terminal width
heading_markers = true

[files]
extensions = ["md", "markdown", "mdown", "mkd"]
```

Environment overrides: `MDV_THEME`, `MDV_WIDTH`

## Status

**In Progress**: Mermaid ASCII diagram rendering.

**Planned**: more TUI features, in-document search, file watching.

## Development

```bash
zig build
zig build test
```

The public repository keeps contributor-facing tests. Maintainers may also run additional internal validation before releases.
