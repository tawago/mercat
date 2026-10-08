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
    \\  Writes to stdout. Color follows --color: by default it is emitted only
    \\  when stdout is a terminal, so piped or redirected output is plain text.
    \\  OSC 8 hyperlinks also need stdout to be a terminal, even with
    \\  --color=always. When stdout is not a terminal, -p is ignored and -t
    \\  refuses to start.
    \\
    \\  Diagnostics go to stderr and follow stderr's own state: the level label
    \\  is colored only when stderr is a terminal and NO_COLOR and TERM=dumb
    \\  are unset. --color=never (or [display] color = "never") turns it off;
    \\  --color=always forces color on stdout only.
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
    \\      --color <when>   Color on stdout: auto (default), always, never
    \\      --heading-markers / --no-heading-markers
    \\                       Show / hide the leading # markers on headings
    \\      --frontmatter <s>
    \\                       YAML front matter: panel (default), dim, compact,
    \\                       raw, hidden
    \\      --format <f>     Output format: terminal (default), plain (no
    \\                       escapes), png (requires -o)
    \\  -o, --output <path>  Write plain/png output to a file instead of stdout
    \\      --monochrome     Black-on-white PNG (requires --format png)
    \\  -p, --pager          Page output through $PAGER, the config pager, or
    \\                       less -R (only when stdout is a terminal)
    \\  -t, --tui            Open the file in the TUI viewer (stdin and stdout
    \\                       must be a terminal; defaults to ./README.md)
    \\  --                   End of options; later arguments are file names
    \\
    \\  Options taking a value accept "--opt value", "--opt=value", and for
    \\  short options "-w80". Long options take two dashes ("-width" is an
    \\  error, not "-w idth").
    \\
    \\Compatibility options (accepted and validated, but currently no effect):
    \\  --box-style <standard|rounded|heavy|double|ascii>
    \\  --layout <auto|sugiyama|tree|force>
    \\  --crossing-heuristic <median|barycenter>
    \\  --aspect-ratio <n>
    \\  --debug-mermaid    Prints a fixed marker block, not real layout stats
    \\
    \\Environment:
    \\  MERCAT_THEME, MERCAT_WIDTH, MERCAT_FRONTMATTER, MERCAT_SUBGRAPH_EDGES
    \\                       Override the matching config keys (flags win)
    \\  MERCAT_SYNTAX_THEME  Deprecated; overrides [display] syntax_theme
    \\  NO_COLOR             Non-empty: disable color (on stdout, unless --color
    \\                       is given; on stderr, always)
    \\  CLICOLOR_FORCE, FORCE_COLOR
    \\                       Non-empty and not "0": force color on stdout
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
