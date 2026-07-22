# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Ongoing development

## [0.2.0]

- **Complete rewrite of the flowchart renderer** (`mermaid_v2`): new parse → semantic graph → sketch → raster → paint pipeline with width-budget candidate selection
- Project renamed from `mdv` to `mercat`; the installed binary is now `mercat`
- Config path moved to `~/.config/mercat/config.toml` (the old `~/.config/mdv/` location is no longer read)
- Environment variables renamed `MDV_*` → `MERCAT_*` (e.g. `MERCAT_THEME`, `MERCAT_WIDTH`, `MERCAT_SYNTAX_THEME`)

## [0.1.2]

- Automate Homebrew tap updates after successful tagged releases
- Improve README install ordering and add project badges

## [0.1.1]

- Fix CI and release workflows for published binaries
- Keep installer and release automation aligned with the public GitHub repository
- Support maintainer-only internal validation from a sibling checkout

## [0.1.0]

- Initial planned public release
- CLI markdown rendering with syntax highlighting
- TUI pager with vim-style navigation
- Theme selection, pager support, config loading, and stdin support
