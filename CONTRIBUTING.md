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

## Guarded Claims

A comment that states how the renderer behaves is a claim. A claim must
name the test that proves it, on the line after the claim:

```zig
/// Two edges share ink only on their common approach; anywhere else a
/// meeting is still a crossing.
/// @guarded-by: sketch_ports_test.zig "a port share licenses only its shared approach"
```

`zig build test` fails if the file or the test name does not exist, so a
renamed or deleted test breaks the build at the comment instead of leaving
the claim unproven. Rules:

1. Point at one test with a `test "..."` declaration at container scope.
   The file part is a basename; a directory prefix is ignored.
2. The named test must assert the claim, not only touch the code. The lint
   checks that the test exists, not what it asserts. That part is on you
   and on the reviewer.
3. When you change the behavior, change the test and the comment together.
   When you delete the claim, delete its pointer with it.
4. Plain explanation of a mechanism needs no pointer. Only a statement that
   could become false needs one.

## Reporting Issues

Include your platform, terminal, Zig version, reproduction steps, and sample markdown when relevant.
