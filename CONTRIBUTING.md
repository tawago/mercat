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

## Reporting Issues

Include your platform, terminal, Zig version, reproduction steps, and sample markdown when relevant.
