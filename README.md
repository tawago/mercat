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
- **Themes**: Dark, light, and auto (terminal background detection)
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
theme = "auto"       # auto, dark, light
width = 0            # 0 = terminal width
heading_markers = true
# YAML front matter display: panel (default), dim, compact, raw, hidden
frontmatter = "panel"

[files]
extensions = ["md", "markdown", "mdown", "mkd"]
```

Environment overrides: `MERCAT_THEME`, `MERCAT_WIDTH`, `MERCAT_FRONTMATTER`

## Status

**In Progress**: Mermaid ASCII diagram rendering.

**Planned**: more TUI features, in-document search, file watching.

## Development

```bash
zig build
zig build test
```

The public repository keeps contributor-facing tests. Maintainers may also run additional internal validation before releases.
