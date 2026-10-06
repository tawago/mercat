//! `--help` and usage text. The config path line is appended at runtime so
//! help shows the file mercat actually reads.

pub const usage_text =
    \\Usage:
    \\  mercat [options] <file>        Render a file to stdout
    \\  cat file.md | mercat           Render piped stdin (no "-" needed)
    \\  mercat -t <file>               Open a file in the interactive TUI viewer
    \\
;

pub const help_text =
    \\mercat - Mermaid & Markdown Viewer on Terminal.
    \\
    \\Usage:
    \\  mercat [options] <file>        Render a file to stdout
    \\  cat file.md | mercat           Render piped stdin (no "-" needed)
    \\  mercat [options] -             Read stdin explicitly
    \\  mercat -t <file>               Open a file in the interactive TUI viewer
    \\
    \\Input:
    \\  A .mmd/.mermaid file, or piped input whose first non-blank, non-"%%"
    \\  line begins at a diagram keyword (eg: flowchart/graph plus a
    \\  direction like TD/LR), is rendered as one bare Mermaid diagram;
    \\  anything else is rendered as Markdown. Use "--" to end options, so a
    \\  file named "-x.md" opens with: mercat -- -x.md
    \\
    \\Output:
    \\  Writes to stdout. Color and OSC 8 hyperlinks follow --color: by default
    \\  they are emitted only when stdout is a terminal, so piped or redirected
    \\  output is plain text. When stdout is not a terminal, -p is ignored and
    \\  -t refuses to start.
    \\
    \\Options:
    \\  -h, --help           Show this help and exit
    \\  -v, -V, --version    Show version and exit
    \\  -w, --width <n>      Wrap width in columns: 0 (auto) or 20..1000. 0 means
    \\                       the terminal width; plain/png use 120
    \\      --theme <name>   Theme: dark, light, ansi, dracula, tokyo-night, pink,
    \\                       markview, or a user theme (alias: --style)
    \\      --list-themes    List built-in and user themes, one per line, and exit
    \\      --dump-theme <name>
    \\                       Print a theme as editable TOML to stdout and exit
    \\      --color <when>   Color and hyperlinks: auto (default), always, never
    \\      --heading-markers / --no-heading-markers
    \\                       Show / hide the leading # markers on headings
    \\      --frontmatter <s>
    \\                       YAML front matter: panel (default), dim, compact,
    \\                       raw, hidden
    \\      --format <f>     Output format: terminal (default), plain (no
    \\                       escapes), png (requires -o)
    \\  -o, --output <path>  Write plain/png output to a file instead of stdout
    \\      --monochrome     Black-on-white output (png only)
    \\  -p, --pager          Page output through $PAGER, the config pager, or
    \\                       less -R (only when stdout is a terminal)
    \\  -t, --tui            Open the file in the TUI viewer (needs an
    \\                       interactive terminal; defaults to ./README.md)
    \\      --box-style <s>  Mermaid box glyphs: standard, rounded, heavy, double,
    \\                       ascii
    \\      --layout <a>     Mermaid layout: auto (default), sugiyama, tree, force
    \\      --crossing-heuristic <h>
    \\                       Mermaid crossing reduction: median (default),
    \\                       barycenter
    \\      --aspect-ratio <n>
    \\                       Mermaid horizontal cell multiplier (default 1.0; try
    \\                       2.0 on 2:1 terminals)
    \\      --debug-mermaid  Print layout debug info for each Mermaid diagram
    \\  --                   End of options; later arguments are file names
    \\
    \\  Options taking a value accept "--opt value", "--opt=value", and for
    \\  short options "-w80".
    \\
    \\Environment:
    \\  MERCAT_THEME, MERCAT_WIDTH, MERCAT_FRONTMATTER, MERCAT_SUBGRAPH_EDGES
    \\                       Override the matching config keys (flags win)
    \\  MERCAT_SYNTAX_THEME  Deprecated; overrides [display] syntax_theme
    \\  NO_COLOR             Non-empty: disable color (unless --color is given)
    \\  CLICOLOR_FORCE, FORCE_COLOR
    \\                       Non-empty and not "0": force color
    \\  TERM                 "dumb" disables color in auto mode
    \\  COLORTERM            "truecolor"/"24bit" enables 24-bit color
    \\  PAGER                Pager command for -p (before the config pager)
    \\  VISUAL, EDITOR       Editor for the TUI's e key when [general] editor
    \\                       is empty (fallback: nvim, vim, vi, nano)
    \\  COLUMNS              Terminal width fallback when it cannot be queried
    \\  XDG_CONFIG_HOME, HOME
    \\                       Locate config.toml and the themes/ directory
    \\
    \\Exit status:
    \\  0  success
    \\  1  runtime failure (unreadable input, write error, export failure)
    \\  2  usage error (unknown option, bad value, conflicting options)
    \\
    \\Examples:
    \\  cat README.md | mercat
    \\  printf 'flowchart LR\n  A-->B\n' | mercat
    \\  mercat -w 80 --theme light README.md
    \\  mercat --format plain README.md > README.txt
    \\  mercat --color=always README.md | less -R
    \\
;

test {
    _ = @import("help_test.zig");
}
