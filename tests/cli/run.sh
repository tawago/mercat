#!/usr/bin/env bash
# CLI contract tests: exact stderr messages, exit codes and stdout shape of the
# built binary. Run via `zig build test-cli` (also part of `zig build test`),
# or directly: tests/cli/run.sh path/to/mercat
#
# Every case runs with a private HOME/XDG_CONFIG_HOME and a scrubbed color
# environment so results do not depend on the developer's setup. stdout and
# stdin are never terminals here, so TTY-only paths are covered by unit tests.
set -u

bin=${1:?usage: run.sh path/to/mercat}
case $bin in /*) ;; *) bin="$PWD/$bin" ;; esac
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

work=$(mktemp -d "${TMPDIR:-/tmp}/mercat-cli.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1

mkdir -p home xdg/mercat/themes dir
printf '# hi\n' > h.md
printf '# T\n\nSee [docs](https://example.com) here.\n' > link.md
printf 'x\n' > ./-weird.md
for i in $(seq 1 4000); do printf -- '- item %d\n' "$i"; done > big.md
printf 'extends = "dark"\n' > xdg/mercat/themes/mine.toml

pass=0
fail=0

# Clean environment for every invocation.
m() {
  env -i PATH="$PATH" HOME="$work/home" XDG_CONFIG_HOME="$work/xdg" TERM=xterm-256color \
    ${EXTRA_ENV:-} "$bin" "$@"
}

# expect NAME RC EXPECTED_STDERR -- ARGS...
expect() {
  local name=$1 want_rc=$2 want_err=$3
  shift 4
  local err rc
  err=$(m "$@" 2>&1 >/dev/null </dev/null)
  rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$err" = "$want_err" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  args: %s\n  rc: got %s want %s\n  stderr got:\n%s\n  stderr want:\n%s\n' \
      "$name" "$*" "$rc" "$want_rc" "$err" "$want_err"
  fi
}

check() {
  local name=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$name"
  fi
}

hint="Try 'mercat --help' for more information."

# --- usage errors: exit 2 ---
expect unknown-option 2 "mercat: error: unknown option '--bogus'
$hint" -- --bogus
expect did-you-mean 2 "mercat: error: unknown option '--widht' (did you mean '--width'?)
$hint" -- --widht 80 h.md
expect missing-arg 2 "mercat: error: option '--format' requires an argument
$hint" -- --format
expect bad-format 2 "mercat: error: invalid value 'svg' for '--format' (expected one of: terminal, plain, png)
$hint" -- --format svg h.md
expect bad-frontmatter 2 "mercat: error: invalid value 'zz' for '--frontmatter' (expected one of: panel, dim, compact, raw, hidden)
$hint" -- --frontmatter=zz h.md
expect bad-box-style 2 "mercat: error: invalid value 'zz' for '--box-style' (expected one of: standard, rounded, heavy, double, ascii)
$hint" -- --box-style zz h.md
expect bad-color 2 "mercat: error: invalid value 'yes' for '--color' (expected one of: auto, always, never)
$hint" -- --color yes h.md
themes="dark, light, ansi, dracula, tokyo-night, pink, markview, mine"
expect unknown-theme 2 "mercat: error: unknown theme 'nope' (expected one of: $themes)
$hint" -- --theme nope h.md
expect unknown-style-alias 2 "mercat: error: unknown theme 'nope' (expected one of: $themes)
$hint" -- --style=nope h.md
expect theme-did-you-mean 2 "mercat: error: unknown theme 'drakula' (expected one of: $themes)
mercat: note: did you mean 'dracula'?
$hint" -- --theme drakula h.md
expect dump-theme-did-you-mean 2 "mercat: error: unknown theme 'drakula' for '--dump-theme' (expected one of: $themes)
mercat: note: did you mean 'dracula'?
$hint" -- --dump-theme drakula
expect prefix-out 2 "mercat: error: unknown option '--out' (did you mean '--output'?)
$hint" -- --out x h.md
expect prefix-list 2 "mercat: error: unknown option '--list' (did you mean '--list-themes'?)
$hint" -- --list
expect prefix-vers 2 "mercat: error: unknown option '--vers' (did you mean '--version'?)
$hint" -- --vers
expect prefix-mono 2 "mercat: error: unknown option '--mono' (did you mean '--monochrome'?)
$hint" -- --mono
expect single-dash-width 2 "mercat: error: unknown option '-width'
mercat: note: did you mean '--width'?
$hint" -- -width 80 h.md
expect single-dash-format 2 "mercat: error: unknown option '-format'
mercat: note: did you mean '--format'?
$hint" -- -format plain h.md
expect single-dash-output 2 "mercat: error: unknown option '-output'
mercat: note: did you mean '--output'?
$hint" -- --format plain -output x h.md
check single-dash-output-no-file [ ! -e utput ]
expect monochrome-needs-png 2 "mercat: error: '--monochrome' only applies to --format png
$hint" -- --monochrome h.md
expect monochrome-plain 2 "mercat: error: '--monochrome' only applies to --format png
$hint" -- --format plain --monochrome h.md
expect empty-output 2 "mercat: error: option '-o' needs a non-empty file name
$hint" -- --format plain -o '' h.md
expect empty-output-eq 2 "mercat: error: option '--output' needs a non-empty file name
$hint" -- --format png --output= h.md
expect conflict-p-t 2 "mercat: error: '-p' and '-t' cannot be used together
$hint" -- -p -t h.md
expect multiple-inputs 2 "mercat: error: more than one input given ('a.md' and 'b.md'); mercat renders one file at a time
$hint" -- a.md b.md
expect png-needs-o 2 "mercat: error: --format png needs an output file; add -o <file>.png
$hint" -- --format png h.md
expect width-range 2 "mercat: error: invalid width '5' for '-w' (expected 0 for auto, or 20..1000)
$hint" -- -w 5 h.md
expect width-word 2 "mercat: error: invalid width 'eighty' for '--width' (expected 0 for auto, or 20..1000)
$hint" -- --width=eighty h.md
expect dash-file-hint 2 "mercat: error: invalid width 'eird.md' for '-w' (expected 0 for auto, or 20..1000)
mercat: note: to open a file whose name starts with '-', use: mercat -- -weird.md
$hint" -- -weird.md
expect tui-needs-tty 2 "mercat: error: --tui needs an interactive terminal; drop -t to render to stdout
$hint" -- -t h.md
expect dump-unknown 2 "mercat: error: unknown theme 'nope' for '--dump-theme' (expected one of: $themes)
$hint" -- --dump-theme nope

# --- runtime failures: exit 1 ---
expect missing-file 1 "mercat: error: nonexist.md: no such file or directory" -- nonexist.md
expect directory 1 "mercat: error: dir: is a directory" -- dir
expect plain-write-fail 1 "mercat: error: cannot write '$work/nope/out.txt': no such file or directory" -- --format plain -o "$work/nope/out.txt" h.md
expect png-write-fail 1 "mercat: error: cannot write '$work/nope/out.png': no such file or directory" -- --format png -o "$work/nope/out.png" h.md
if [ "$(id -u)" != 0 ]; then
  printf '# x\n' > locked.md
  chmod 000 locked.md
  expect permission-denied 1 "mercat: error: locked.md: permission denied" -- locked.md
fi

# --- closed stdout (`>&-`): one wording, exit 1 ---
closed() { m "$@" 2>&1 >&- </dev/null; }
for args in "--version" "--help" "--list-themes" "--dump-theme dark" "h.md" "--format plain h.md"; do
  # shellcheck disable=SC2086
  err=$(closed $args)
  rc=$?
  check "closed-stdout-${args// /_} (rc=$rc err=$err)" \
    [ "$rc:$err" = "1:mercat: error: cannot write to stdout: bad file descriptor" ]
done

# --- argument syntax: exit 0 ---
expect width-eq 0 "" -- --width=80 h.md
expect width-attached 0 "" -- -w80 h.md
expect end-of-options 0 "" -- -- -weird.md
expect theme-eq 0 "" -- --theme=light h.md
expect user-theme 0 "" -- --theme mine h.md

# --- broken pipe: exit 0, silent, every format ---
for fmt in terminal plain; do
  for col in auto always; do
    out=$( { m --format "$fmt" --color "$col" big.md 2>"$work/pipe.err"; echo "rc=$?" >"$work/pipe.rc"; } | head -1)
    check "broken-pipe-$fmt-$col-rc" [ "$(cat "$work/pipe.rc")" = "rc=0" ]
    check "broken-pipe-$fmt-$col-stderr" [ ! -s "$work/pipe.err" ]
    check "broken-pipe-$fmt-$col-stdout" [ -n "$out" ]
  done
done

# --- empty input: zero bytes ---
check empty-terminal [ "$(printf '' | m | wc -c | tr -d ' ')" = 0 ]
check empty-plain [ "$(printf '' | m --format plain | wc -c | tr -d ' ')" = 0 ]

# --- color gating ---
esc=$(printf '\033')
has() { grep -q "$1"; }
out=$(m link.md)
check piped-default-no-sgr [ "${out#*"$esc"}" = "$out" ]
out=$(m --color=always link.md)
check always-has-sgr has "${esc}\[" <<<"$out"
check always-piped-no-osc8 [ "${out#*"$esc]8"}" = "$out" ]
out=$(EXTRA_ENV="NO_COLOR=1 FORCE_COLOR=1" m link.md)
check no-color-wins-over-force [ "${out#*"$esc"}" = "$out" ]
out=$(EXTRA_ENV="FORCE_COLOR=1" m link.md)
check force-color has "${esc}\[" <<<"$out"
out=$(EXTRA_ENV="CLICOLOR_FORCE=1" m --color never link.md)
check flag-never-wins [ "${out#*"$esc"}" = "$out" ]
# Diagnostics follow stderr's own state: forcing stdout color never puts
# escapes into a redirected stderr.
err=$(m --color=always --bogus 2>&1 >/dev/null)
check always-stderr-not-forced [ "${err#*"$esc"}" = "$err" ]
err=$(EXTRA_ENV="FORCE_COLOR=1 CLICOLOR_FORCE=1" m --bogus 2>&1 >/dev/null)
check force-env-stderr-not-forced [ "${err#*"$esc"}" = "$err" ]

# Terminal-only paths, run under a pseudo-terminal when util-linux `script`
# is available: stderr color on a terminal, and -t refusals.
if script --version 2>/dev/null | grep -q util-linux; then
  # pty "SHELL COMMAND": runs with stdin, stdout and stderr on a terminal.
  pty() {
    M="$bin" W="$work" script -qec "$1" /dev/null </dev/null 2>/dev/null | tr -d '\r'
  }
  envm='env -i PATH="$PATH" HOME="$W/home" XDG_CONFIG_HOME="$W/xdg" TERM=xterm-256color'
  out=$(pty "$envm \"\$M\" --bogus")
  check pty-stderr-colored has "${esc}\[1;31merror:" <<<"$out"
  out=$(pty "$envm \"\$M\" --bogus --color=never")
  check pty-never-applies-to-usage-error [ "${out#*"$esc"}" = "$out" ]
  out=$(pty "$envm NO_COLOR=1 \"\$M\" --bogus")
  check pty-no-color-stderr [ "${out#*"$esc"}" = "$out" ]
  printf '[display]\ncolor = "never"\n' > xdg/mercat/config.toml
  out=$(pty "$envm \"\$M\" --bogus")
  check pty-config-never-applies-to-usage-error [ "${out#*"$esc"}" = "$out" ]
  rm xdg/mercat/config.toml
  out=$(pty "echo x | $envm \"\$M\" --color=never -t \"\$W/h.md\"; echo rc=\$?")
  check pty-tui-pipe-with-file [ "$out" = "mercat: error: --tui reads keys from the terminal, but stdin is a pipe; run without the pipe or drop -t
$hint
rc=2" ]
  out=$(pty "cd \"\$W\" && echo x | $envm \"\$M\" --color=never -t; echo rc=\$?")
  check pty-tui-pipe-no-file [ "$out" = "mercat: error: --tui reads keys from the terminal, but stdin is a pipe; run without the pipe or drop -t
$hint
rc=2" ]
fi

never_text=$(m --color never link.md)
check never-keeps-text has "See docs" <<<"$never_text"
check never-no-escapes [ "${never_text#*"$esc"}" = "$never_text" ]

# --- config never kills a run ---
cat > xdg/mercat/config.toml <<'EOF'
[display]
width = "eighty"
heading_markers = "true"
them = "light"
[dispaly]
x = 1
EOF
cfg="$work/xdg/mercat/config.toml"
expect config-warnings 0 "mercat: warning: $cfg:2: invalid value \"eighty\" for 'width' in [display] (expected 0 for auto, or an integer from 20 to 1000); keeping the default
mercat: warning: $cfg:4: unknown key 'them' in [display] (did you mean 'theme'?)
mercat: warning: $cfg:5: unknown section [dispaly] (did you mean [display]?); its keys are ignored" -- h.md
out=$(m --dump-theme dark 2>/dev/null)
check dump-theme-with-broken-config has "# Theme: dark" <<<"$out"
out=$(m --format plain h.md 2>/dev/null)
check quoted-true-keeps-markers has "# hi" <<<"$out"
rm xdg/mercat/config.toml

# The sample config shipped in the repo must load cleanly.
cp "$script_dir/../../config/default.toml" xdg/mercat/config.toml
expect sample-config-clean 0 "" -- h.md
rm xdg/mercat/config.toml

EXTRA_ENV="MERCAT_WIDTH=abc MERCAT_FRONTMATTER=zz MERCAT_THEME=nope" \
  expect env-warnings 0 "mercat: warning: ignoring MERCAT_WIDTH='abc' (expected 0 for auto, or an integer from 20 to 1000)
mercat: warning: ignoring MERCAT_FRONTMATTER='zz' (expected one of: panel, dim, compact, raw, hidden)
mercat: warning: MERCAT_THEME: unknown theme 'nope'; using dark (expected one of: $themes)" -- h.md
EXTRA_ENV="MERCAT_THEME=drakula" \
  expect env-theme-did-you-mean 0 "mercat: warning: MERCAT_THEME: unknown theme 'drakula'; using dark (expected one of: $themes)
mercat: note: did you mean 'dracula'?" -- h.md

# Malformed lines warn and do not shift later keys into the wrong section.
cat > xdg/mercat/config.toml <<'EOF'
[general]
pager = 5
[display
theme = "light"
editor = "ed"
[display]
width 80
theme = "drakula
frontmatter = "dim"
EOF
expect config-malformed 0 "mercat: warning: $cfg:2: invalid value 5 for 'pager' in [general] (expected a quoted string); keeping the default
mercat: warning: $cfg:3: cannot parse line (missing ']'; keys up to the next section are ignored)
mercat: warning: $cfg:7: cannot parse line (expected key = value)
mercat: warning: $cfg:8: cannot parse line (unterminated string)" -- h.md
printf '[display]\ntheme = "drakula"\n' > xdg/mercat/config.toml
expect config-theme-did-you-mean 0 "mercat: warning: $cfg:2: unknown theme 'drakula'; using dark (expected one of: $themes)
mercat: note: did you mean 'dracula'?" -- h.md
rm xdg/mercat/config.toml

# --- themes, help, version ---
out=$(m --list-themes)
check list-themes [ "$out" = "dark
light
ansi
dracula
tokyo-night
pink
markview
mine" ]
out=$(m --help)
check help-exit-status has "Exit status:" <<<"$out"
check help-config-path has "Config: $work/xdg/mercat/config.toml" <<<"$out"
out=$(m --version)
check version has "^mercat [0-9]" <<<"$out"

# --- width 0 for plain means the 120-column default ---
printf 'word %.0s' $(seq 1 80) > long.md
first=$(m -w 0 --format plain long.md | head -1)
check width0-plain [ "${#first}" -gt 100 -a "${#first}" -le 120 ]

lacks() { ! grep -q "$@"; }

# --- invalid UTF-8: decoded with exactly one warning, every block rendered ---
repro="$script_dir/../repro/invalid-utf8"
for f in "$repro"/[0-9]*.md; do
  name=$(basename "$f")
  cp "$f" "$name"
  err=$(m --format plain -w 60 "$name" 2>&1 >"$work/utf8.out" </dev/null)
  rc=$?
  check "utf8-$name-rc" [ "$rc" = 0 ]
  check "utf8-$name-rendered" [ -s "$work/utf8.out" ]
  check "utf8-$name-no-fallback" lacks 'could not be rendered' "$work/utf8.out"
  case $name in
    14-*) check "utf8-$name-utf16-silent" [ -z "$err" ] ;;
    *) check "utf8-$name-one-warning" [ "$(printf '%s\n' "$err" | grep -c '')" = 1 ]
       check "utf8-$name-warning-text" has "^mercat: warning: $name: invalid UTF-8 at line [0-9]*, column [0-9]* ([0-9]* bytes\{0,1\} replaced with U+FFFD)$" <<<"$err" ;;
  esac
done
cp "$repro/10-in-table-cell.md" table.md
out=$(m --format plain table.md 2>/dev/null)
check utf8-table-row-stays has "� │ ok" <<<"$out"
err=$(printf 'ok \377 bye\n' | m --format plain 2>&1 >/dev/null)
check utf8-stdin-warning [ "$err" = "mercat: warning: stdin: invalid UTF-8 at line 1, column 4 (1 byte replaced with U+FFFD)" ]

# --- invisible and control characters: text kept, no escape reaches stdout ---
out=$(printf 'a\302\255b\n' | m --format plain 2>&1)
check soft-hyphen-dropped [ "$out" = "  ab" ]
printf 'esc \033[2J text\n\n```\ncode \033[2J\n```\n\n[l](http://x/\033[2J)\n\n| a | b |\n|---|---|\n| \033[2J | &#27;[2J |\n' > inject.md
for col in never always; do
  m --color "$col" inject.md >"$work/inject.out" 2>"$work/inject.err"
  check "inject-$col-no-clear" lacks "${esc}\[2J" "$work/inject.out"
  check "inject-$col-quiet" [ ! -s "$work/inject.err" ]
  if [ "$col" = never ]; then check inject-never-no-esc lacks "$esc" "$work/inject.out"; fi
done

# --- over-long path components: an error, never a trap ---
long=$(printf 'a%.0s' $(seq 1 300)).md
expect long-name-input 1 "mercat: error: $long: file name too long" -- "$long"
expect long-name-plain 1 "mercat: error: $long: file name too long" -- --format plain "$long"
expect long-name-output 1 "mercat: error: cannot write '$long': file name too long" -- --format plain -o "$long" h.md
expect long-name-png 1 "mercat: error: cannot write '$long': file name too long" -- --format png -o "$long" h.md

# --- output through symlinks and into fifos: never replace the link or node ---
png_sig=$(printf '\211PNG')
for fmt in plain png; do
  mkdir -p "out-$fmt/real"
  printf 'old\n' > "out-$fmt/real/target"
  ln -s real/target "out-$fmt/link"
  expect "symlink-$fmt" 0 "" -- --format "$fmt" -o "out-$fmt/link" h.md
  check "symlink-$fmt-still-link" [ -L "out-$fmt/link" ]
  check "symlink-$fmt-target-written" lacks '^old$' "out-$fmt/real/target"
  check "symlink-$fmt-no-temp" [ -z "$(ls -A "out-$fmt" "out-$fmt/real" | grep mercat-tmp)" ]
  ln -s made "out-$fmt/dangling"
  expect "dangling-$fmt" 0 "" -- --format "$fmt" -o "out-$fmt/dangling" h.md
  check "dangling-$fmt-still-link" [ -L "out-$fmt/dangling" ]
  check "dangling-$fmt-target-created" [ -s "out-$fmt/made" ]
  mkfifo "out-$fmt/fifo"
  timeout 20 cat "out-$fmt/fifo" > "out-$fmt/from-fifo" &
  reader=$!
  expect "fifo-$fmt" 0 "" -- --format "$fmt" -o "out-$fmt/fifo" h.md
  wait "$reader"
  check "fifo-$fmt-reader-rc" [ $? = 0 ]
  check "fifo-$fmt-still-fifo" [ -p "out-$fmt/fifo" ]
  check "fifo-$fmt-received" [ -s "out-$fmt/from-fifo" ]
done
check symlink-png-is-png [ "$(head -c 4 out-png/real/target)" = "$png_sig" ]
check symlink-plain-text grep -q '# hi' out-plain/real/target
check fifo-png-is-png [ "$(head -c 4 out-png/from-fifo)" = "$png_sig" ]
mkdir out-dir
expect output-directory 1 "mercat: error: cannot write 'out-dir': is a directory" -- --format plain -o out-dir h.md

# --- inline HTML across lines renders as markdown, not as raw source ---
printf 'one <span\nclass=x>two</span>\n\nc <!-- a\nb --> d\n\na<br>b\n' > inline-html.md
out=$(m --format plain inline-html.md 2>"$work/ihtml.err")
check inline-html-quiet [ ! -s "$work/ihtml.err" ]
check inline-html-joined has '<span class=x>two</span>' <<<"$out"
check inline-html-comment-hidden lacks -e '<!--' <<<"$out"
check inline-html-br [ "$(printf '%s\n' "$out" | tail -2)" = "  a
  b" ]


printf 'cli: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
