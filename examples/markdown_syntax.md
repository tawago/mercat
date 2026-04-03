# Comprehensive Markdown Syntax Guide

## Headings

# Heading 1
## Heading 2
### Heading 3
#### Heading 4
##### Heading 5
###### Heading 6

## Paragraphs and Line Breaks

This is a paragraph with multiple sentences. It wraps naturally across lines without creating separate blocks.

This is another paragraph. Separated by a blank line.

Line break with two spaces at end:  
Next line starts here.

## Text Formatting

**Bold text** or __bold text__

*Italic text* or _italic text_

***Bold and italic*** or ___bold and italic___

~~Strikethrough text~~

==Highlighted text==

`Inline code`

## Footnotes (if supported)

This is a sentence with a footnote[^1].

## Lists

### Unordered Lists

- Item 1
- Item 2
  - Nested item 2.1
  - Nested item 2.2
    - Nested item 3.1
    - Nested item 3.2
- Item 3

### Ordered Lists

1. First item
2. Second item
   1. Nested item 2.1
   2. Nested item 2.2
3. Third item

### Mixed Lists

1. First item
   - Nested unordered
   - Another nested
2. Second item
   - More nested items

### Task Lists

- [x] Completed task
- [ ] Incomplete task
- [x] Another completed task

## Block Quotes

> This is a blockquote.
> It can span multiple lines.

> Nested blockquote
>> This is deeply nested.
>> It continues here.

## Code Blocks

```
Plain code block without syntax highlighting
Line 2
Line 3
```

```python
def hello_world():
    print("Hello, World!")
    return True
```

```javascript
function fibonacci(n) {
  if (n <= 1) return n;
  return fibonacci(n - 1) + fibonacci(n - 2);
}
```

```bash
#!/bin/bash
echo "Bash code block"
for i in {1..5}; do
  echo "Line $i"
done
```

```rust
fn main() {
    println!("Hello, Rust!");
    let x: i32 = 42;
}
```

    Indented code block (4 spaces)
    Second line
    Third line

## Links

[Inline link](https://example.com)

[Link with title](https://example.com "Example Site")

[Reference link][ref]

[ref]: https://example.com

<https://auto-linked-url.com>

<user@example.com>

## Images

![Alt text](https://via.placeholder.com/150)

![Alt text with title](https://via.placeholder.com/150 "Image Title")

## Horizontal Rules

---

***

___

## Tables

| Header 1 | Header 2 | Header 3 |
|----------|----------|----------|
| Cell 1   | Cell 2   | Cell 3   |
| Cell 4   | Cell 5   | Cell 6   |

| Left aligned | Center aligned | Right aligned |
|:---|:---:|---:|
| L1 | C1 | R1 |
| L2 | C2 | R2 |

## Inline HTML

This is <strong>HTML strong</strong> text.

<div>HTML block element</div>

## Escaping

This shows \*escaped asterisk\* and \[escaped bracket\].

## Special Characters

Copyright © 2024

Trademark ™ symbol

Registered ® symbol

## Emphasis Variations

***Bold italic***

**Bold with _nested italic_**

_Italic with **nested bold**_

## Complex Nesting

> **Bold quote**
> 
> - List in quote
> - Another item
>   1. Nested ordered
>   2. In blockquote

1. **Bold in list**
   > Quote in list
   > More quote
2. `Code in list`

## Line Continuation

This is a very long line that should demonstrate how text wrapping works when displaying markdown content in a terminal with limited width. The text should automatically wrap to the next line without breaking words in the middle.

Another paragraph with multiple levels of indentation:

   This paragraph is indented by 3 spaces and should be displayed with that indentation preserved where possible.

## HTML Entities

&copy; 2024 &mdash; Copyright

&lt;tag&gt; and &amp; ampersand

## Definition Lists (if supported)

Term 1
:   Definition 1

Term 2
:   Definition 2a
:   Definition 2b

## Superscript and Subscript (if supported)

E=mc^2^

H~2~O

## Abbreviations (if supported)

The HTML specification is maintained by the W3C.

*[HTML]: Hyper Text Markup Language
*[W3C]: World Wide Web Consortium


[^1]: This is the footnote content.

