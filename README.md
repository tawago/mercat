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
- **Themes**: Seven built-in presets (dark, light, ansi, dracula, tokyo-night,
  pink, markview) plus `auto`, extendable/overridable user theme files
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
mercat --style dracula README.md # Select a theme preset (or user theme name)
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
# Built-in presets: auto, dark, light, ansi, dracula, tokyo-night, pink,
# markview — or a user theme name (~/.config/mercat/themes/<name>.toml).
theme = "auto"
width = 0            # 0 = terminal width
heading_markers = true
# YAML front matter display: panel (default), dim, compact, raw, hidden
frontmatter = "panel"

[files]
extensions = ["md", "markdown", "mdown", "mkd"]
```

Environment overrides: `MERCAT_THEME`, `MERCAT_WIDTH`, `MERCAT_FRONTMATTER`

## Themes

To see every themable element live — with the `[theme.<slot>]` key named next
to the element it styles — open the self-demonstrating guide:

```sh
mercat --style dracula theme-guide.md
```

Select a theme by name with `--style <name>`, the config `theme = "<name>"`
key, or `MERCAT_THEME`. Built-in presets:

| Preset | Notes |
|--------|-------|
| `dark` / `light` / `auto` | Default xterm-256 palettes (`auto` picks dark). |
| `ansi` | Uses the terminal's own 16-color palette (SGR 30–37/90–97). |
| `dracula`, `tokyo-night` | Popular truecolor palettes. |
| `pink` | Bar-prefixed headings, chrome-light code. |
| `markview` | Structural marks/glyphs, full-line heading tints, rounded tables (widely-supported Unicode only — no Nerd-font glyphs). |

**User theme files** live at `~/.config/mercat/themes/<name>.toml` and use the
same `[theme.<slot>]` schema as inline config overrides. Built-in preset names
take precedence over user files of the same name.

**Start your own theme** by dumping any theme to editable TOML with
`--dump-theme <name>`, saving it under your themes directory, and selecting it:

```sh
mercat --dump-theme dark > ~/.config/mercat/themes/mine.toml
# edit mine.toml, then:
mercat --style mine README.md
```

The dump is a faithful, ready-to-edit snapshot: every slot color/attr, the
`base_bg`/`base_fg`/`canvas` top-level keys, and the glyph/code-frame/token
tables — so a freshly dumped preset resolves with zero diagnostics and renders
identically to the original. `extends` is intentionally omitted (the dump is
already flattened); add it back yourself if you want your theme to track a base.

**Overriding and extending.** Inline `[theme.<slot>]` tables in `config.toml`
override the selected theme per slot. A theme can build on another with
`extends`; resolution folds the base palette → the `extends` chain → your inline
overrides. Absent keys inherit; an explicit empty string `""` clears an
inherited value.

```toml
[theme]
extends = "dracula"
[theme.heading1]
fg = "#ff79c6"   # hex, xterm-256 index, ANSI color name, or "default"
prefix = "» "
bold = true
```

Truecolor (`#rrggbb`) values downgrade to the nearest xterm-256 color when the
terminal does not advertise `COLORTERM`. Theme problems (unknown name, bad
color, missing/cyclic `extends`, unreadable file) are reported non-fatally: in
the TUI they appear in the status bar; on the CLI they print as dim `# mercat:`
comment lines on stderr when stdout is piped, so pipelines stay clean.

## Status

**In Progress**: Mermaid ASCII diagram rendering.

**Planned**: more TUI features, in-document search, file watching.

## Development

```bash
zig build
zig build test
```

The public repository keeps contributor-facing tests. Maintainers may also run additional internal validation before releases.
