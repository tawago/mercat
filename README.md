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
mercat -t README.md           # View a file in the TUI
mercat -t                     # Same, opening ./README.md

# CLI mode
mercat README.md              # Render to stdout
mercat -p README.md           # Pipe through a pager ($PAGER, config pager, or less -R)
mercat -w 80 README.md        # Fixed width (0 = terminal width, else 20..1000)
mercat --theme dracula README.md   # Pick a built-in preset or user theme (alias: --style)
mercat --list-themes          # Built-in and user themes, one per line
mercat --dump-theme dark      # Print a theme as editable TOML
mercat --format plain README.md > README.txt   # Plain text, no escapes
mercat --color=always README.md | less -R      # Keep color through a pipe
cat file.md | mercat          # Read from stdin (no `-` needed)
cat file.md | mercat -        # Explicit stdin
mercat -- -notes.md           # `--` ends options

# Mermaid
mercat diagram.mmd            # .mmd / .mermaid files render as one diagram
printf 'flowchart LR\n  A-->B\n' | mercat   # bare diagram source, no fence
```

Options that take a value accept `--opt value`, `--opt=value`, and for short
options `-w80`. Run `mercat --help` for the full list.

With no file argument, mercat reads stdin whenever it is a pipe or redirect;
when stdin is an interactive terminal it prints the usage text and exits 2.

Piped input is sniffed: if it carries no ```` ```mermaid ```` fence and its
first non-blank, non-`%%` line begins at column 0 with a diagram keyword
(`sequenceDiagram`, `classDiagram`, `erDiagram`, `stateDiagram[-v2]`, or
`flowchart`/`graph` followed by a direction such as `TD`/`LR`), the whole
input is rendered as a single Mermaid diagram. An indented first line stays
markdown, since indentation there means "code block".

**Color.** `--color auto|always|never` (default `auto`). Without the flag,
`NO_COLOR` (non-empty) turns color off, `CLICOLOR_FORCE` / `FORCE_COLOR`
(non-empty, not `0`) turn it on, then the `[display] color` config key
applies, `TERM=dumb` turns it off, and otherwise color is used only when
stdout is a terminal, so piped output is plain text. `never` keeps the layout
but emits no escape sequences. OSC 8 hyperlinks are emitted only when color is
on and stdout is a terminal.

**TUI mode** needs an interactive terminal and a file: `-t` refuses to start
when stdout is not a terminal, when stdin is a pipe and no file is given, or
when given a directory (directory browsing is not available yet).

**Diagnostics and exit status.** Errors and warnings go to stderr as
`mercat: error: …` / `mercat: warning: …`. Exit status is `0` on success, `1`
on a runtime failure (unreadable input, write error, export failure) and `2`
on a usage error (unknown option, bad value, conflicting options). Writing to
a closed pipe (`mercat big.md | head -1`) exits 0 silently.

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

Config file: `$XDG_CONFIG_HOME/mercat/config.toml`, else
`~/.config/mercat/config.toml` (`mercat --help` prints the resolved path).
Every key is optional. Command-line flags win over environment variables,
which win over the config file. A bad value, unknown key or unknown section
never stops a run: mercat prints a warning with `path:line` (with a
did-you-mean when one is close) and keeps the default.

```toml
[general]
editor = "vim"       # editor command for the TUI's `e` key
pager = "less -R"    # used by -p when $PAGER is unset

[display]
theme = "dark"       # dark, light, ansi, dracula,
                     # tokyo-night, pink, markview, or a user theme name
width = 0            # 0 = terminal width, else 20..1000
heading_markers = true
color = "auto"       # auto, always, never (see Color above)
# YAML front matter display: panel (default), dim, compact, raw, hidden
frontmatter = "panel"

[mermaid]
# How an edge crossing a subgraph border is drawn: bridge (default), cross
subgraph_edges = "bridge"
```

### Theming

mercat resolves colors and glyphs through a single theme system. Pick a theme
with `theme = "<name>"` in `[display]`, the `--theme <name>` flag, or the
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
element change, e.g. `mercat --theme dracula theme-guide.md`.

**User theme files.** Drop `<name>.toml` in `~/.config/mercat/themes/`
(or `$XDG_CONFIG_HOME/mercat/themes/`) and select it by its filename stem. A
theme can start from any built-in with `extends = "dark"` and override only the
slots it wants. Generate an editable starting point with:

```bash
mercat --dump-theme dark > ~/.config/mercat/themes/mine.toml
mercat --theme mine README.md
```

Environment overrides: `MERCAT_THEME`, `MERCAT_WIDTH`, `MERCAT_FRONTMATTER`,
`MERCAT_SUBGRAPH_EDGES` (and the deprecated `MERCAT_SYNTAX_THEME`). An invalid
value is reported as a warning and ignored. `mercat --list-themes` shows every
theme name mercat can find.

## Status

**In Progress**: Mermaid ASCII diagram rendering.

**Planned**: more TUI features, in-document search, file watching.

## Development

```bash
zig build
zig build test
```

The public repository keeps contributor-facing tests. Maintainers may also run additional internal validation before releases.
