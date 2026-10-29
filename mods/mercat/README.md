# mercat for Claude Code

A Claude Code mod that brings [mercat](https://github.com/tawago/mercat) into the session.

- **Diagrams in replies.** When Claude writes a ```` ```mermaid ```` block, the reply shows it drawn as a text diagram. The raw block shows first, then the drawing replaces it once mercat finishes. If mercat can't draw it, the raw block stays. A diagram wider than the reply is drawn cut off at the `»` marks, with a warning line in color right above it. A label mercat has no room for is left out, also with a warning line in color. Only the screen changes; the stored message stays as Claude wrote it (ctrl+o).
- **`/mercat off`** shows mermaid blocks as written again; **`/mercat on`** brings the drawings back. Each new session starts on. To turn it off for good, uninstall the mod.
- **`/mercat <file>`** opens a side pane with the file rendered by mercat, sized to the pane.
- **`/mercat`** with no argument lists the `.md`, `.markdown`, `.mmd` and `.mermaid` files Claude edited this session, newest first. Pick one to read it; **back** (or `b`) returns to the list.

## Requirements

mercat on your `PATH`:

```bash
brew install tawago/tap/mercat
```

Or any other method under [Installation](../../README.md#installation). If it is missing, the mod shows one hint per session and leaves diagrams as written.

The mod's version is mercat's release version. If your mercat is older than the mod, it shows one upgrade hint at start.

Tested with Claude Code 2.1.299. The plugin API is early access and may change between releases.

## Install

At the prompt of a terminal session:

```
/plugin install mercat --marketplace tawago/mercat
```

Or in two steps:

```
/plugin marketplace add tawago/mercat
/plugin install mercat@mercat
```

From a shell: `claude plugin install mercat --marketplace tawago/mercat`.

## Develop

```bash
claude --plugin-dir mods/mercat     # load from this checkout
claude plugin validate mods/mercat
claude plugin test mods/mercat
```
