---
title: Kitchen sink
tags: [fixture, regression]
---

<!-- Regression fixture: every construct here once crashed the renderer or
     lost content. It must render, in every built-in style, without a single
     block falling back to raw source. -->

<p align="center">
  <img src="assets/logo.png" alt="mercat logo" width="120">
  <br>
  <a href="https://example.com/ci"><img alt="CI" src="https://example.com/ci.svg"></a>
</p>

<div align="center">
A centered <b>tagline</b> &amp; some <sup>small</sup> print.
</div>

# Kitchen sink

**bold** [link](https://example.com) and *italic* [link](https://example.com),
__strong__ [l](u), `code` [l](u), **b** and **c** [l](u), [l](u) **after**,
[**bold inside** link](u), ~~gone~~ and ==marked== and H~2~O and E=mc^2^.

## Lists with block content

1. Install:

   ```sh
   make install
   ```

   Then run it:

   ```
   mercat README.md
   ```
2. Configure:

   > A quote inside a list item,
   > over two lines.

   | key   | value |
   | ----- | ----- |
   | width | 80    |

3. Done, with a nested list:
   - child one
     ```zig
     const x = 1;
     ```
   - [ ] a task in a nested list
   - [x] a finished task

- A bullet with an HTML block:

  <details>
  <summary>Click to expand</summary>

  Hidden body text.

  </details>

- [ ] A task with code

  ```json
  {"ok": true}
  ```

## HTML blocks

<details>
<summary>More details</summary>

Body text inside details.
</details>

<table>
  <tr><td>cell a</td><td>cell b</td></tr>
  <tr><td>cell c</td><td>cell d</td></tr>
</table>

<!-- a comment on its own -->

<pre>
preformatted
  text
</pre>

<aside>An unknown tag keeps its text.</aside>

## Quotes

> A quote with **bold** and a [link](https://example.com).
>
> > Nested quote.
>
> - list in quote
>
> ```sh
> echo "code in quote"
> ```

Final paragraph[^1].

[^1]: A footnote.
