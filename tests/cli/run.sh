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
expect unknown-theme 2 "mercat: error: unknown theme 'nope' (available: dark, light, ansi, dracula, tokyo-night, pink, markview, mine)
$hint" -- --theme nope h.md
expect unknown-style-alias 2 "mercat: error: unknown theme 'nope' (available: dark, light, ansi, dracula, tokyo-night, pink, markview, mine)
$hint" -- --style=nope h.md
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
expect dump-unknown 2 "mercat: error: unknown theme 'nope' for '--dump-theme' (available: dark, light, ansi, dracula, tokyo-night, pink, markview, mine)
$hint" -- --dump-theme nope

# --- runtime failures: exit 1 ---
expect missing-file 1 "mercat: error: nonexist.md: no such file or directory" -- nonexist.md
expect directory 1 "mercat: error: dir: is a directory" -- dir
expect plain-write-fail 1 "mercat: error: $work/nope/out.txt: no such file or directory" -- --format plain -o "$work/nope/out.txt" h.md
expect png-write-fail 1 "mercat: error: cannot write '$work/nope/out.png': no such file or directory" -- --format png -o "$work/nope/out.png" h.md
if [ "$(id -u)" != 0 ]; then
  printf '# x\n' > locked.md
  chmod 000 locked.md
  expect permission-denied 1 "mercat: error: locked.md: permission denied" -- locked.md
fi

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
mercat: warning: MERCAT_THEME: unknown theme 'nope'; using dark (available: dark, light, ansi, dracula, tokyo-night, pink, markview, mine)" -- h.md

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

printf 'cli: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
