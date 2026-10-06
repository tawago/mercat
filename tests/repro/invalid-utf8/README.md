# Invalid UTF-8 input: reproduction files

Status: **fixed** (see "Current behavior" below). Each file is a small
markdown file with invalid bytes in a different place. Their bytes are
covered by unit tests in `src/core/encoding_test.zig` and
`src/core/markdown/render_input_test.zig`, and `tests/cli/run.sh` renders
every file here with the built binary and checks the single warning.

Reproduce:

```sh
zig build -Doptimize=ReleaseSafe
for f in tests/repro/invalid-utf8/*.md; do
  echo "== $f"; ./zig-out/bin/mercat --format plain -w 60 "$f"; echo "rc=$?"
done
printf 'ok \xff bye\n' | ./zig-out/bin/mercat --format plain   # stdin
```

## Files

| File | Bytes | Where |
| --- | --- | --- |
| 01-lone-ff-byte.md | `FF` | paragraph (the original report) |
| 02-latin1-file.md | `E9`, `EF` | whole file saved as Latin-1 |
| 03-cp1252-smart-quotes.md | `93 94 96` | Windows-1252 quotes and dash |
| 04-truncated-multibyte.md | `E2 82` at end of line | truncated sequence |
| 05-overlong-encoding.md | `C0 AF` | overlong `/` |
| 06-utf16-surrogate.md | `ED A0 80` | encoded UTF-16 surrogate |
| 07-in-heading.md | `FF` | heading |
| 08-in-fenced-code.md | `FF` | fenced code block |
| 09-in-link-url.md | `FF` | link destination |
| 10-in-table-cell.md | `FF` | table cell |
| 11-in-front-matter.md | `FF` | YAML front matter |
| 12-in-list-item.md | `FF` | list item |
| 13-in-mermaid.md | `FF` | mermaid node label |
| 14-utf16le-bom-file.md | `FF FE` + NULs | whole file is UTF-16LE |
| 15-many-bad-lines.md | `FF` x5 | five paragraphs |

## Behavior before the fix

Up to v0.3.1, every file except 13 printed nothing and exited 1. For example:

```
$ printf 'ok \xff bye\n' | mercat --format plain
warning: pcre_exec: -10

error: InvalidUtf8
```

After the per-block render fallback (branch `wip/render`), the document
renders and exits 0, but the problems below remain:

- The affected blocks are not rendered as markdown. Each one is shown as muted
  raw source with U+FFFD in place of the bad bytes. Example: 07 shows a literal
  `# Ti�tle` instead of a heading.
- The warning is generic. It names neither the file nor the position:
  `warning: N markdown block(s) could not be rendered and are shown as raw
  source (first error: InvalidUtf8)`.
- koino's autolink extension prints `warning: pcre_exec: -10`
  (PCRE_ERROR_BADUTF8) once per affected inline run, followed by an empty line.
- Invalid bytes can change the parse itself. In 10, the row containing `FF`
  falls out of the table and renders as a separate raw paragraph.
- 13 (mermaid) is inconsistent with the rest: the diagram path accepts the byte
  and renders it as `ÿ` (decoded as Latin-1).
- 14 (UTF-16) is shown as a mess of U+FFFD. Nothing detects the BOM or reports
  that the file is not UTF-8.

## Current behavior

Input is decoded before parsing (`src/core/encoding.zig`):

- Each invalid sequence becomes one U+FFFD per maximal subpart (Unicode
  §3.9, the WHATWG decoder's rule): `C0 AF` gives two, `ED A0 80` three,
  a truncated `E2 82` one. Every block then renders as normal markdown; in
  10 the row stays in its table, in 07 the heading is a heading.
- One warning per input names the file (or `stdin`) and the first position,
  in characters of the decoded line, and counts the replaced bytes:
  `mercat: warning: 01-lone-ff-byte.md: invalid UTF-8 at line 1, column 4 (1 byte replaced with U+FFFD)`.
- koino only sees valid UTF-8, so `pcre_exec: -10` never appears.
- 13 (mermaid) goes through the same decoder and shows `St�art`.
- 14: input starting with a UTF-16 byte order mark (`FF FE` or `FE FF`) is
  transcoded to UTF-8 without a warning, since it is valid text in a known
  encoding. Unpaired surrogates or a dangling odd byte become U+FFFD with
  `invalid UTF-16 at line L, column C (N code units replaced with U+FFFD)`.
- In the TUI, the same message is shown in the status bar at startup and
  after a reload.
