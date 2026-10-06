# Invalid UTF-8 input: reproduction files

Open issue: mercat does not decode invalid UTF-8 input. These files reproduce
it. Each one is a small markdown file with invalid bytes in a different place.
They are not wired into `zig build test`; they hold the inputs for the fix and
its regression tests.

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

## Behavior

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

## Expected

- Decode lossily before parsing: replace each invalid sequence with U+FFFD
  (WHATWG "maximal subpart" rule), so every block renders as normal markdown.
- Print one warning per input, with the file path or `stdin`:
  `mercat: warning: <name>: invalid UTF-8 at line L, column C (replaced with U+FFFD)`.
- No `pcre_exec` noise, because koino only ever sees valid UTF-8.
- Optional: detect a UTF-16 BOM and either transcode or report
  `mercat: <name>: UTF-16 input is not supported`.
