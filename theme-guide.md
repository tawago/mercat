---
title: mercat theme guide
purpose: every themable element, live on screen
tip: open me with `mercat --style <preset> docs/theme-guide.md`
---

# Theme guide

This document renders every element mercat can theme. Open it with different
styles and watch each section change:

```sh
mercat theme-guide.md                      # default (dark)
mercat --style dracula theme-guide.md      # any preset
mercat --dump-theme dark > ~/.config/mercat/themes/mine.toml
mercat --style mine theme-guide.md         # your own theme
```

Built-in presets: `dark`, `light`, `ansi`, `dracula`, `tokyo-night`, `pink`,
`markview`. A theme file can start from any of them with `extends = "name"`
and override only the slots it wants — absent keys inherit, an explicit `""`
clears an inherited prefix or glyph.

The panel above this heading is **front matter** — themed by
`[theme.frontmatter_key]`, `[theme.frontmatter_value]` and
`[theme.frontmatter_cap]`.

---

## Headings — `[theme.heading1]` … `[theme.heading6]`

Each level is its own slot with `fg`, `bold`, and a `prefix` string (the `#`
markers you see are the dark preset's prefixes; ansi uses `┄`, markview uses
`◉ ◈ ◇` marks with a full-line background tint via `bg`).

Any heading level can also carry an **underline row** — one extra row directly
below the heading, filled edge-to-edge (like a full-width rule) in the
heading's own style. Set `underline_row = true`; `underline_glyph` picks the
fill (default `─`). Use `═` for a heavier setext-style rule, or a single space
`" "` to make it a padding row that simply continues the heading's background
tint (handy with `full_line_bg` or a canvas). An explicit empty
`underline_glyph = ""` resets the glyph back to the default `─`.

```toml
[theme.heading1]
underline_row = true
underline_glyph = "═"   # default is "─"; " " gives a blank tinted padding row
```

# Heading level 1

## Heading level 2

### Heading level 3

#### Heading level 4

##### Heading level 5

###### Heading level 6

## Body and inline text

Plain paragraph text uses `[theme.body]`. Inside it you can theme
**bold** (`[theme.strong]`), *italic* (`[theme.emphasis]`),
***bold italic*** (`[theme.strong_emphasis]`), ~~struck text~~
(`[theme.strikethrough]`), ==highlighted text== (`[theme.highlight]`),
and `inline code` (`[theme.code]`).

Superscript^like this^ uses `[theme.superscript]`; subscript~like this~ uses
`[theme.subscript]`.

A [link to the mercat repo](https://github.com/tawago/mercat) is themed by
`[theme.link]` (color + `underline`), and an image reference
![architecture diagram](https://example.com/diagram.png) by
`[theme.image_alt]`.

## Blockquote — `[theme.quote]`

> The quote slot sets this text's color and attributes. The bar on the left
> is a glyph: `[theme.glyphs] quote_bar = "▎"` — dracula drops the bar and
> indents instead (`quote_indent = 2`).

## Lists

Bullet markers use `[theme.bullet]`; the item text has its own slot,
`[theme.list_item]`, so list text can read differently from paragraphs. When
a theme leaves `[theme.list_item]` unset it falls back to that theme's own
`[theme.body]`, so item text matches paragraphs unless you opt in. (The dark
preset nudges it one step softer than body — `252` against the `254` body —
and light does the same with `236` against `234`.) The glyphs cycle per
depth: `[theme.glyphs] bullets` (default `• ◦ ‣`).

- First level bullet
  - Second level bullet
    - Third level bullet

Ordered markers have their own slot, `[theme.ordered]` — in the dark preset
they take an accent color instead of the muted gray:

1. Ordered step one
2. Ordered step two
3. Ordered step three

Task markers split into `[theme.task_on]` / `[theme.task_off]`, with glyphs
`task_ticked` / `task_unticked` (markview swaps in `✓` / `○`):

- [x] A completed task
- [ ] A pending task

## Table

Header cells use `[theme.strong]`; the border rules use `[theme.muted]`.
markview switches the border glyph set to rounded corners via
`[theme.table]`.

| Slot            | Themes                          |
| --------------- | ------------------------------- |
| `heading1..6`   | title ladder                    |
| `body` / `muted`| text and de-emphasized chrome   |
| `link`          | hyperlinks                      |

## Horizontal rule

`[theme.hr]` controls the glyph and fill mode — full-width (below), or a
fixed count like glamour's eight dashes (`fill = "fixed"`, clamped to the
terminal width):

---

## Code block

The panel uses `[theme.code_block]` (fg + panel `bg`); tokens come from
`[theme.tokens]`: `keyword`, `string`, `number`, `comment`. The frame style
(`[theme.code_frame]`) can be a background panel (dark), top/bottom rules
(ansi), or a full-width block with a language chip (markview).

```zig
// comment token
const answer: u32 = 42;          // number token
pub fn greet(name: []const u8) void {
    std.debug.print("hello {s}\n", .{name}); // string token
}
```

## Canvas and warnings

`canvas = true` paints the whole document on the theme's `base_bg` (on by
default for light, dracula, tokyo-night, pink, markview; off for dark and
ansi, which blend into your terminal). Theme problems — an unknown name, a
bad color, a broken `extends` chain — never abort rendering: they surface in
the TUI status bar, or as a dim `# mercat: …` comment on stderr in CLI mode.

## The full slot list

Run `mercat --dump-theme dark` to see every slot with its current value in
ready-to-edit TOML. The slots are:

`heading1..heading6`, `body`, `muted`, `emphasis`, `strong`,
`strong_emphasis`, `code`, `code_block`, `code_block_keyword`,
`code_block_string`, `code_block_number`, `code_block_comment`,
`code_keyword`, `code_string`, `code_number`, `code_comment`, `quote`,
`link`, `strikethrough`, `image_alt`, `superscript`, `subscript`,
`highlight`, `frontmatter_key`, `frontmatter_value`, `frontmatter_cap`,
`bullet`, `ordered`, `task_on`, `task_off`, `list_item`.
