# Mermaid reproduction files

Minimal inputs for open Mermaid rendering issues. Each file reproduces one
issue on its own; the issue has the expected output. The overall list lives
in the tracking issue [#86](https://github.com/tawago/mercat/issues/86).

Run any file with:

```sh
mercat --format plain -w 80 <file>
```

Issues that need a different command say so in the table. When an issue is
fixed, turn its file into a regression test and delete it from here.

| Issue | File(s) | Notes |
|-------|---------|-------|
| [#57](https://github.com/tawago/mercat/issues/57) | `seq-activation-shorthand-dropped.mmd`, `seq-activation-shorthand-dropped-pair.mmd`, `seq-activation-shorthand-fence.md` | `->>+` / `-->>-` makes the diagram vanish |
| [#58](https://github.com/tawago/mercat/issues/58) | `flow-lr-label-flips-td.mmd` | also at `-w 200` |
| [#59](https://github.com/tawago/mercat/issues/59) | `flow-long-edge-label-dropped.mmd` | |
| [#60](https://github.com/tawago/mercat/issues/60) | `seq-note-overprints-message.mmd` | |
| [#61](https://github.com/tawago/mercat/issues/61) | `seq-note-over-lifeline-leak.mmd` | |
| [#62](https://github.com/tawago/mercat/issues/62) | `seq-alt-else-no-frame.mmd` | |
| [#63](https://github.com/tawago/mercat/issues/63) | `seq-loop-no-frame.mmd` | |
| [#64](https://github.com/tawago/mercat/issues/64) | `seq-opt-no-frame.mmd` | |
| [#65](https://github.com/tawago/mercat/issues/65) | `seq-par-no-frame.mmd` | |
| [#66](https://github.com/tawago/mercat/issues/66) | `seq-cross-arrow-no-head.mmd` | |
| [#67](https://github.com/tawago/mercat/issues/67) | `seq-autonumber-ignored.mmd` | |
| [#68](https://github.com/tawago/mercat/issues/68) | `seq-box-style-ignored.mmd` | compare `--box-style <s>` outputs with `md5sum` |
| [#69](https://github.com/tawago/mercat/issues/69) | `syntax-error-block.md` | |
| [#70](https://github.com/tawago/mercat/issues/70) | `unsupported-{pie,gantt,mindmap,timeline,gitgraph,journey,quadrant}.mmd` | add `2>&1` to see that no notice is printed |
| [#71](https://github.com/tawago/mercat/issues/71) | `frontmatter-title.mmd`, `frontmatter-title-fence.md` | |
| [#72](https://github.com/tawago/mercat/issues/72) | `class-members-lost.mmd` | |
| [#73](https://github.com/tawago/mercat/issues/73) | `class-inheritance-marker.mmd` | |
| [#74](https://github.com/tawago/mercat/issues/74) | `class-edge-through-box.mmd` | |
| [#75](https://github.com/tawago/mercat/issues/75) | `er-layout.mmd` | |
| [#76](https://github.com/tawago/mercat/issues/76) | `er-edge-through-box.mmd` | |
| [#77](https://github.com/tawago/mercat/issues/77) | `er-trailing-blank-rows.mmd` | |
| [#78](https://github.com/tawago/mercat/issues/78) | `state-composite-flattened.mmd` | |
| [#79](https://github.com/tawago/mercat/issues/79) | `state-leading-blank-rows.mmd` | |
| [#80](https://github.com/tawago/mercat/issues/80) | `subgraph-frame-overprints-edge.mmd` | |
| [#81](https://github.com/tawago/mercat/issues/81) | `layout-flags-identical.mmd` | compare `--layout`, `--crossing-heuristic`, `--aspect-ratio` outputs with `md5sum` |
| [#82](https://github.com/tawago/mercat/issues/82) | `debug-mermaid-empty-stats.mmd` | add `--debug-mermaid` |
| [#83](https://github.com/tawago/mercat/issues/83) | `tui-l-key-noop.md` | `mercat -t tui-l-key-noop.md`, then press `l` |
| [#84](https://github.com/tawago/mercat/issues/84) | `too-wide-er-fence.md` | use `-w 60` and `2>&1` |
| [#85](https://github.com/tawago/mercat/issues/85) | `fanout-150.mmd`, `fanout-300.mmd` | wrap in `time`; the 300-edge file takes about 40 s |
