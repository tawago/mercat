# Contributing

Thanks for working on `mercat`.

## Development Setup

`mercat` currently targets Zig `0.15.1`.

```bash
zig build
zig build test
```

## Scope Of Public Tests

The public repository keeps contributor-facing tests that should be enough to validate normal changes:

```bash
zig build
zig build test
```

Maintainers may also run additional internal validation before merging or releasing changes. That validation lives in a separate private checkout and is not required for public contributions.

## Pull Requests

Before opening a pull request:

1. Run `zig build`.
2. Run `zig build test`.
3. Update docs if behavior or installation changes.
4. Keep changes focused and explain the user-visible impact.

## Style Notes

1. Prefer small, direct changes.
2. Follow existing naming and layout conventions.
3. Avoid unrelated refactors in the same change.

## File Size

Implementation modules are capped at 500 code lines; test files are not capped.
A code line is a line that is not blank and whose first non-space characters
are not `//`, so doc comments are free. `bash tools/check_line_count.sh`
applies the cap to `src/` and `zig build lint` applies it to
`src/core/mermaid_v2/`; both count the same way and both skip `*_test*.zig`.
A module over the cap is split, not grandfathered.

## Guarded Claims

A doc comment may point at the test that proves its claim:
`/// @guarded-by: some_test.zig "test name"`. `zig build test` fails if that
test does not exist, so rename or delete the test and the comment together.
The lint accepts `guarded-by:` with or without the `@`; `@guarded-by:` is the
preferred spelling.

## Reporting Issues

Include your platform, terminal, Zig version, reproduction steps, and sample markdown when relevant.
