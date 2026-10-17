# mercat brand assets

The mercat mascot is a meerkat peeking out of its burrow. In the hero art the
burrow is a flowchart, because mercat draws mermaid diagrams in the terminal.

## Files

| File | Use |
|------|-----|
| `mercat-hero.png` | Hero art: the meerkat above a flowchart burrow (1254×1254) |
| `mercat-wordmark.png` | Wordmark: MER, the meerkat, CAT |
| `mercat-wordmark-light.png` | Wordmark on a white background |
| `mercat-mascot.png` | Mascot alone |
| `mercat-mascot-light.png` | Mascot on a white background |
| `mercat-icon-{128,256,512}.png` | Square avatar on the dark background |
| `mercat-icon-transparent-{128,256,512}.png` | Square avatar with a transparent background |
| `mercat-social-preview.png` | GitHub social preview (1280×640) |
| `*.ans` | Terminal versions of the mascot and wordmark |

The `.ans` files are text with 24-bit ANSI colour codes. Print one in a
truecolor terminal:

```bash
cat assets/brand/mercat-mascot.ans
```

The plain `.ans` files keep the terminal's own background and suit dark
themes. The `-light.ans` files paint a white background.

## Colours

| Role | Hex |
|------|-----|
| Fur | `#eb8b29` |
| Fur, shade | `#bf681a` |
| Muzzle and belly | `#fdd68c` |
| Eye patch | `#442710` |
| Pupil | `#140e0a` |
| Outline | `#18140c` |
| Whiskers | `#b88c52` |
| Diagram mint | `#80f5ca` |
| Background | `#0d1117` |

## Usage

- Scale pixel art by whole multiples with nearest-neighbour filtering. Smooth
  scaling blurs it.
- Do not stretch, recolour or redraw the meerkat.
- Keep clear space around the wordmark at least as wide as one letter stroke.

## License

The brand assets are licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Credit "mercat".

The hero art and the source art for the mascot were made with AI image
generation and then edited by hand. The terminal mascot and the wordmark
are pixel art derived from that source.
