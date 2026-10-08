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
themes="dark, light, ansi, dracula, tokyo-night, pink, markview, mine"
expect theme-did-you-mean 2 "mercat: error: unknown theme 'drakula' (expected one of: $themes)
mercat: note: did you mean 'dracula'?
$hint" -- --theme drakula h.md
expect dump-theme-did-you-mean 2 "mercat: error: unknown theme 'drakula' for '--dump-theme' (expected one of: $themes)
mercat: note: did you mean 'dracula'?
$hint" -- --dump-theme drakula
expect single-dash-width 2 "mercat: error: unknown option '-width'
mercat: note: did you mean '--width'?
$hint" -- -width 80 h.md
expect dash-file-hint 2 "mercat: error: invalid width 'eird.md' for '-w' (expected 0 for auto, or 20..1000)
mercat: note: to open a file whose name starts with '-', use: mercat -- -weird.md
$hint" -- -weird.md
expect tui-needs-tty 2 "mercat: error: --tui needs an interactive terminal; drop -t to render to stdout
$hint" -- -t h.md

# --- runtime failures: exit 1 ---
expect missing-file 1 "mercat: error: nonexist.md: no such file or directory" -- nonexist.md
expect directory 1 "mercat: error: dir: is a directory" -- dir
expect plain-write-fail 1 "mercat: error: cannot write '$work/nope/out.txt': no such file or directory" -- --format plain -o "$work/nope/out.txt" h.md
expect png-write-fail 1 "mercat: error: cannot write '$work/nope/out.png': no such file or directory" -- --format png -o "$work/nope/out.png" h.md
printf '# Oops \360\237\222\251\n' > emoji.md
expect png-missing-glyph 1 "mercat: error: PNG export failed: no glyph for U+1F4A9 at row 0, column 9" -- --format png -o emoji.png emoji.md
check png-missing-glyph-no-file [ -z "$(ls -A | grep -e '^emoji.png$' -e mercat-tmp)" ]
if [ "$(id -u)" != 0 ]; then
  printf '# x\n' > locked.md
  chmod 000 locked.md
  expect permission-denied 1 "mercat: error: locked.md: permission denied" -- locked.md
fi

# --- closed stdout (`>&-`): one wording, exit 1 ---
closed() { m "$@" 2>&1 >&- </dev/null; }
for args in "--version" "h.md" "--format plain h.md"; do
  # shellcheck disable=SC2086
  err=$(closed $args)
  rc=$?
  check "closed-stdout-${args// /_} (rc=$rc err=$err)" \
    [ "$rc:$err" = "1:mercat: error: cannot write to stdout: bad file descriptor" ]
done

# --- a user theme file loads: exit 0 ---
expect user-theme 0 "" -- --theme mine h.md

# --- broken pipe: exit 0, silent, both stdout formats ---
for run in terminal:always plain:auto; do
  fmt=${run%:*} col=${run#*:}
  out=$( { m --format "$fmt" --color "$col" big.md 2>"$work/pipe.err"; echo "rc=$?" >"$work/pipe.rc"; } | head -1)
  check "broken-pipe-$fmt-$col-rc" [ "$(cat "$work/pipe.rc")" = "rc=0" ]
  check "broken-pipe-$fmt-$col-stderr" [ ! -s "$work/pipe.err" ]
  check "broken-pipe-$fmt-$col-stdout" [ -n "$out" ]
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
# Diagnostics follow stderr's own state: forcing stdout color never puts
# escapes into a redirected stderr.
err=$(m --color=always --bogus 2>&1 >/dev/null)
check always-stderr-not-forced [ "${err#*"$esc"}" = "$err" ]

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
  printf '[display]\ncolor = "never"\n' > xdg/mercat/config.toml
  out=$(pty "$envm \"\$M\" --bogus")
  check pty-config-never-applies-to-usage-error [ "${out#*"$esc"}" = "$out" ]
  rm xdg/mercat/config.toml
  out=$(pty "echo x | $envm \"\$M\" --color=never -t \"\$W/h.md\"; echo rc=\$?")
  check pty-tui-pipe-with-file [ "$out" = "mercat: error: --tui reads keys from the terminal, but stdin is a pipe; run without the pipe or drop -t
$hint
rc=2" ]
fi

never_text=$(m --color never link.md)
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

EXTRA_ENV="MERCAT_THEME=drakula" \
  expect env-theme-did-you-mean 0 "mercat: warning: MERCAT_THEME: unknown theme 'drakula'; using dark (expected one of: $themes)
mercat: note: did you mean 'dracula'?" -- h.md

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
check help-config-path has "Config: $work/xdg/mercat/config.toml" <<<"$out"
out=$(m --version)
check version has "^mercat [0-9]" <<<"$out"

# --- width 0 for plain means the 120-column default ---
printf 'word %.0s' $(seq 1 80) > long.md
first=$(m -w 0 --format plain long.md | head -1)
check width0-plain [ "${#first}" -gt 100 -a "${#first}" -le 120 ]

lacks() { ! grep -q "$@"; }

# --- invalid UTF-8: decoded with one warning that names the input ---
printf 'ok \377 bye\n' > bad.md
err=$(m --format plain bad.md 2>&1 >/dev/null)
check utf8-file-warning [ "$err" = "mercat: warning: bad.md: invalid UTF-8 at line 1, column 4 (1 byte replaced with U+FFFD)" ]
printf '\377\376#\0 \0H\0i\0\n\0' > u16.md
err=$(m --format plain u16.md 2>&1 >/dev/null)
check utf8-utf16-silent [ -z "$err" ]
printf '| a | b |\n|---|---|\n| \377 | ok |\n' > table.md
out=$(m --format plain table.md 2>/dev/null)
check utf8-table-row-stays has "� │ ok" <<<"$out"
err=$(printf 'ok \377 bye\n' | m --format plain 2>&1 >/dev/null)
check utf8-stdin-warning [ "$err" = "mercat: warning: stdin: invalid UTF-8 at line 1, column 4 (1 byte replaced with U+FFFD)" ]

# --- invisible and control characters: text kept, no escape reaches stdout ---
printf 'esc \033[2J text\n\n```\ncode \033[2J\n```\n\n[l](http://x/\033[2J)\n\n| a | b |\n|---|---|\n| \033[2J | &#27;[2J |\n' > inject.md
m --color always inject.md >"$work/inject.out" 2>/dev/null
check inject-always-no-clear lacks "${esc}\[2J" "$work/inject.out"
m --color never inject.md >"$work/inject.out" 2>/dev/null
check inject-never-no-esc lacks "$esc" "$work/inject.out"

# --- over-long path components: an error, never a trap ---
long=$(printf 'a%.0s' $(seq 1 300)).md
expect long-name-input 1 "mercat: error: $long: file name too long" -- "$long"
expect long-name-output 1 "mercat: error: cannot write '$long': file name too long" -- --format plain -o "$long" h.md
EXTRA_ENV="XDG_CONFIG_HOME=$work/$long" expect long-name-config 0 "mercat: warning: cannot read config file $work/$long/mercat/config.toml: file name too long; using defaults" -- h.md
# A theme file that is listed but cannot be read says why, not "unknown theme".
mkdir -p badxdg/mercat/themes
ln -s "$long" badxdg/mercat/themes/longlink.toml
EXTRA_ENV="XDG_CONFIG_HOME=$work/badxdg" expect theme-long-link 1 "mercat: error: cannot read theme 'longlink': file name too long" -- --theme longlink h.md
printf '[display]\ntheme = "longlink"\n' > badxdg/mercat/config.toml
EXTRA_ENV="XDG_CONFIG_HOME=$work/badxdg" expect config-theme-long-link 0 "mercat: warning: cannot read theme 'longlink': file name too long; using dark" -- h.md

# --- output through a symlink: never replace the link (fs_test covers fifos,
# dangling links and temp files; this proves both exports use writeOutput) ---
png_sig=$(printf '\211PNG')
for fmt in plain png; do
  mkdir -p "out-$fmt/real"
  printf 'old\n' > "out-$fmt/real/target"
  ln -s real/target "out-$fmt/link"
  expect "symlink-$fmt" 0 "" -- --format "$fmt" -o "out-$fmt/link" h.md
  check "symlink-$fmt-still-link" [ -L "out-$fmt/link" ]
done
check symlink-png-is-png [ "$(head -c 4 out-png/real/target)" = "$png_sig" ]
check symlink-plain-text grep -q '# hi' out-plain/real/target
mkdir out-dir
expect output-directory 1 "mercat: error: cannot write 'out-dir': is a directory" -- --format plain -o out-dir h.md

# --- -o over existing files as another user: same rules as `>` ---
# Run as root only (to switch to uid 65534), and only when that user can reach
# the binary and the work directory.
as_nobody() {
  setpriv --reuid=65534 --regid=65534 --clear-groups \
    env -i PATH="$PATH" HOME="$work/home" XDG_CONFIG_HOME="$work/xdg" TERM=xterm-256color "$bin" "$@"
}
if [ "$(id -u)" = 0 ] && command -v setpriv >/dev/null; then
  chmod 711 "$work"
  mkdir -m 1777 sticky
  chmod 644 h.md
  if as_nobody --version >/dev/null 2>&1 && setpriv --reuid=65534 --regid=65534 --clear-groups test -w sticky; then
    # Another user's writable file in a sticky directory: written in place.
    printf 'old\n' > sticky/f
    chmod 666 sticky/f
    err=$(as_nobody --format plain -o sticky/f "$work/h.md" 2>&1)
    check "sticky-rc (err=$err)" [ $? = 0 ]
    check sticky-written lacks '^old$' sticky/f
    check sticky-owner-kept [ "$(stat -c %u sticky/f)" = 0 ]
    # A file the user cannot write is refused, as `>` refuses it.
    printf 'RO\n' > sticky/ro
    chown 65534:65534 sticky/ro
    chmod 444 sticky/ro
    err=$(as_nobody --format plain -o sticky/ro "$work/h.md" 2>&1)
    check readonly-rc [ $? = 1 ]
    check "readonly-err (err=$err)" [ "$err" = "mercat: error: cannot write 'sticky/ro': permission denied" ]
    check readonly-kept cmp -s sticky/ro <(printf 'RO\n')
    check sticky-no-temp [ -z "$(ls -A sticky | grep mercat-tmp)" ]
  fi
fi

# --- inline HTML across lines renders as markdown, not as raw source ---
printf 'one <span\nclass=x>two</span>\n\nc <!-- a\nb --> d\n\na<br>b\n' > inline-html.md
out=$(m --format plain inline-html.md 2>"$work/ihtml.err")
check inline-html-quiet [ ! -s "$work/ihtml.err" ]
check inline-html-br [ "$(printf '%s\n' "$out" | tail -2)" = "  a
  b" ]


printf 'cli: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
