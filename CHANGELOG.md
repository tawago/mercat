# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Markdown

- **Blocks inside list items render.** Code blocks, quotes, tables, extra
  paragraphs and HTML inside a list or task item now render in order, indented
  under the item's text. A fenced block under `1. Install:` used to fail with
  `error: DisallowedControl` and print nothing.
- **HTML blocks.** Comments are hidden; `<p>`, `<div>`, `<details>` and
  `<center>` wrappers are dropped but their text is kept; `<summary>X</summary>`
  shows as `▸ X`; `<br>` breaks the line; `<img>` and `<a href>` render like
  markdown images and links. Multi-line HTML blocks no longer crash.
- **Emphasis before a link.** `**bold** [link](url)` keeps its bold text instead
  of printing the literal `**`. The fix is a patch to the bundled koino parser,
  now vendored in `vendor/koino` (see `vendor/koino/PIN.md`).
- **One bad block no longer fails the document.** A block that cannot be
  rendered (an unexpected internal error) is shown as dimmed raw source, with bad
  bytes replaced by `�` (or as a placeholder when no source is available), and
  mercat prints one warning and exits 0. Previously
  the whole run failed with `error: InvalidUtf8` or `error: DisallowedControl`.
- **Invalid UTF-8 is decoded, not fatal.** Input is decoded before parsing:
  each invalid sequence becomes `�` (U+FFFD, one per maximal subpart), so the
  document renders as normal markdown (headings stay headings, table rows stay
  in their table), with one warning such as
  `mercat: warning: notes.md: invalid UTF-8 at line 3, column 7 (2 bytes
  replaced with U+FFFD)`. The `pcre_exec: -10` noise is gone. Files that start
  with a UTF-16 byte order mark are transcoded to UTF-8.
- **Invisible and control characters no longer hide text.** A soft hyphen,
  zero-width space, bidi control or other invisible format character is
  dropped; C0/C1 controls such as BEL and ESC are shown as `�`. Before, a
  paragraph containing one rendered as `[block could not be rendered]`.
  Escape sequences in text, code, link URLs, tables, front matter or character
  references (`&#27;`) never reach the terminal.
- Links with an empty URL (`[text]()`, `<a href="">text</a>`) no longer show a
  stray `<>`; an empty `<a href=""></a>` shows nothing.
- Block quotes have one space after the bar in every theme (was three before
  plain text), and the extra blank line after each quote is gone.

### CLI

- **Clear errors and exit codes.** Every message on stderr reads
  `mercat: error|warning|note: …`, with file names and plain-language reasons
  instead of Zig error names. Unknown options suggest the closest match
  (`unknown option '--colr' (did you mean '--color'?)`), and invalid values list
  the valid ones. Exit status is 0 on success, 1 on a runtime or I/O failure,
  and 2 on a usage error (including running with no input on a terminal).
- **Broken pipes are quiet.** `mercat big.md | head -1` exits 0 with no error.
- **Argument syntax.** `--opt=value`, `-w80`, bundled short flags (`-pw 40`) and
  `--` all work.
- **`--theme`** is the main name for theme selection; `--style` remains as an
  alias. **`--list-themes`** prints built-in and user themes, one per line.
- **`--color auto|always|never`** and `[display] color`. Piped output has no
  escape codes by default; `NO_COLOR`, `CLICOLOR_FORCE`, `FORCE_COLOR` and
  `TERM=dumb` are honored. `--color=always`, `CLICOLOR_FORCE` and
  `FORCE_COLOR` force color on stdout only: diagnostics follow stderr's own
  terminal, `NO_COLOR` and `TERM` state, and `--color=never` or
  `[display] color = "never"` applies to usage errors too.
- **A bad config never stops a run.** Unknown keys and sections and invalid
  values are reported as `config.toml:LINE: …` warnings with a suggestion, and
  the default is kept. Invalid `MERCAT_*` environment values warn the same way.
- `--width` accepts 0 (auto) or 20..1000.
- `-t` checks its input before reading stdin: a piped stdin or stdout, or a
  directory, is a usage error instead of a hang, and the message names the
  cause (`stdin is a pipe; run without the pipe or drop -t`). Bare `-t` opens
  `./README.md`.
- Empty input produces empty output. A pager that cannot start is reported
  once and the output is written directly; a pager that exits non-zero no
  longer causes the document to be printed twice.
- `--help` gains Environment and Exit status sections and shows the config
  file path.
- Did-you-mean prefers a unique prefix (`--out` suggests `--output`), and a
  single-dash long option (`-width 80`) is reported as such with a
  `did you mean '--width'?` note instead of a misleading `-w` error. Unknown
  themes suggest the closest name (`drakula` → `dracula`); every enum error
  reads `expected one of: …`.
- Output write failures read `cannot write to stdout: …` or
  `cannot write '<path>': …`; a closed stdout is `bad file descriptor`. An
  empty `-o` value and `--monochrome` without `--format png` are usage errors.
- Config lines mercat cannot parse (`[section` without `]`, no `=`, an
  unterminated string) warn `path:N: cannot parse line` and no longer shift
  later keys into the previous section; string keys given a non-string value
  (`pager = 5`) warn and are ignored.

### TUI

- **Key bindings follow less and vim.** `Ctrl-E` / `Ctrl-N` and `Ctrl-Y` /
  `Ctrl-P` move a line; `f` / `Ctrl-F` page down and `b` page up; `d` / `u`
  and `Ctrl-D` / `Ctrl-U` move half a page; `<` / `>` jump to the top and
  bottom; `F1` opens help. One key table drives key handling, the help overlay
  and the README table, so they cannot drift apart.
- **Changed keys.** The subgraph-edge toggle moved from `b` to `B` (`b` now
  pages up, as in less). `f` pages down; `Enter` still follows footnote links.
  The `l` layout key is gone: it changed nothing on screen (#83). `h` no
  longer opens help.
- **Home / End work in tmux, GNU screen and the Linux console**, which send
  `ESC [1~` / `ESC [4~`; these keys were ignored before.
- **Help overlay.** A bordered card titled `mercat <version> — keys`, grouped
  into Move, Search, File, View and Other, drawn over the dimmed document. It
  fits at 80x24 in two columns; on smaller screens it scrolls with
  `j`/`k`/`PgUp`/`PgDn` and shows `↓ more`. `Esc`, `q`, `?` or `F1` closes it.
  Before, it silently cut off its last entries on a 24-row terminal.
- **Status line.** It spans the full width: the file name and any message on
  the left, the position on the right (`L 30-58/897 6%`, or `Top` / `Bot` /
  `All`). Messages disappear after 2.5 seconds (5 seconds for
  warnings such as invalid UTF-8 at startup or reload, and copy failures) and
  never hide the position. Text is clipped by display width at character boundaries, so
  wide (CJK) names no longer misalign the bar. A long search query shows its
  end (`…tail`) with the cursor right after it.
- **Search.** `/` opens an incremental, smart-case search prompt in the status
  line (`Enter` confirms, `Esc` or `Ctrl-C` cancels); `n` / `N` step through
  matches with wraparound. All matches are highlighted and the current one
  uses the theme accent; the status line shows `[3/17] /mermaid` or
  `Pattern not found: foo`. Matches are recomputed on resize and reload.
  `Esc` clears the selection first, then the search highlights; an empty
  search (`/` then `Enter`) clears them too. `Ctrl-C` in the prompt cancels
  instead of quitting, and `Ctrl-Z` cancels the prompt and suspends.
- **Honest copy messages.** `Copied "…"` appears only when the clipboard tool
  or OSC 52 delivered the text; otherwise the status line says
  `Copy failed: …` with the fix (selection too large for OSC 52, no
  `wl-copy` / `xclip` / `xsel`, or `tmux set -s set-clipboard on`). Under tmux
  mercat sends plain OSC 52 instead of a passthrough wrapper that tmux drops
  by default; GNU screen gets a screen-style passthrough (the old wrapper was
  tmux-only).
- **Editor resolution.** `e` uses `[general] editor` when set, else `$VISUAL`,
  `$EDITOR`, or the first of nvim/vim/vi/nano on `PATH`. Editor commands may
  carry arguments (`code --wait`). The default config no longer hard-codes
  `vim`.
- **No more crashes on edit/reload failures.** A missing editor or a deleted
  file used to exit with `error: FileNotFound`; the TUI now keeps the current
  document and says what went wrong in the status line.
- **Terminal restore.** SIGTERM, SIGHUP, SIGINT and SIGQUIT, panics and fatal
  signals (SIGSEGV/SIGBUS/SIGILL/SIGFPE) restore the terminal (alt screen,
  mouse, cursor, tty mode) before exiting; crashes print where to report them.
  `Ctrl-Z` (and `kill -TSTP`) suspends cleanly and redraws on `fg`.

### Diagrams

- Minimal reproduction files for the open Mermaid issues (#57-#85, tracked in
  #86) live in `tests/repro/mermaid/`.

### Known issues

- The TUI can hang on quit (`q`, `Ctrl-C`) or when starting the editor (`e`)
  if the terminal never answers the startup device-status query (#87). A
  reproduction lives in `tests/repro/tui/dsr-hang/`.

## [0.3.1]

### Diagrams

- **One fit ladder.** Sequence, class, ER and state diagrams now share one
  in-order fit ladder. When a diagram does not fit the width, mercat prints
  `warning: mermaid: <kind> diagram not drawn: width N > budget M` on stderr
  instead of silently showing the source.
- **Sequence diagrams wrap long message labels** to fit narrower terminals.
  Lines break only at spaces or between CJK characters, never inside a word; a
  diagram that needed 102 columns now draws at 61.
- Wrapped sequence text draws accents, combining marks, flags and emoji
  (including ZWJ sequences) whole.

## [0.3.0]

### Flowcharts

- **New flowchart renderer.** Fans share one rail instead of a tangle of parallel
  strokes, edges that cross subgraph borders route around existing ink, and
  arrowheads always sit on a straight run into their node.
- **Edge labels stay on their own edge** and keep clear of other edges' ink.
- **Shorter diagrams.** Gaps between ranks hold only the rows their ink needs,
  so tall empty gaps are gone.
- Emoji, CJK, combining marks and other wide or zero-width characters in labels
  are measured by display width, so boxes and rows no longer skew.

### Text and Unicode

- **Unicode 17.0.0** is now the width and grapheme authority for markdown,
  export, the TUI and diagrams.
- Malformed UTF-8 is rejected with `error: InvalidUtf8` instead of being passed
  through byte by byte.
- Documents containing invisible control characters (soft hyphen, zero-width
  space, LRM/RLM, word joiner) are rejected with `error: DisallowedControl`.
- Table cells collapse runs of spaces; links and images with multibyte URLs are
  measured in columns, so such tables come out narrower.
- Tabs in front matter expand to four-column stops in every style.
- Sequence, class, ER and state diagrams drop a label whose characters are not
  all single code points (emoji with variation selector, flags, ZWJ sequences,
  combining marks, tabs).

### CLI

- `mercat --version` prints the built version and returns at once; it no
  longer contacts GitHub.
- Input is capped at 256 MB.
- Mermaid warnings on stderr are prefixed `mermaid` (was `mermaid_v2`).

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
