# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.3] - 2026-08-21

### Changed

- Updated screenshot assets: new preview image and a second panel screenshot
  in the README gallery.

## [2.0.2] - 2026-08-21

### Fixed

- Bar rotation restored: the rotation timer was dropped in the Rust backend
  rewrite, so the watchlist stayed on the first symbol.

## [2.0.1] - 2026-08-21

### Fixed

- Backend watchlist parsing: `--symbols "A,B"` no longer drops everything
  after the first comma (clap `value_delimiter` with a single String arg).
- Widget settings reading: injected shell settings hold QML lists, which
  `Array.isArray` rejects; the watchlist now survives a fresh shell start
  instead of only updating after a manual save.

## [2.0.0] - 2026-08-21

### Added

- Rust backend (`omastonk-qs`): staggered round-robin quote polling with a
  single streaming `watch` process, serde-typed Yahoo Finance parsing, and a
  `chart` subcommand that serves the panel's close-series.
- Bundled statically linked musl x86_64 backend (`omarchy/bin/omastonk-qs`)
  with a reproducible-build attestation (`make verify-bundle`, the
  marketplace gate); falls back to an `omastonk-qs` binary on PATH.
- Unit tests for the backend and node tests for the QML model helpers
  (`make test`, `make plugin-test`).
- GitHub Actions: cargo format/clippy/test, plugin model tests, MSRV check,
  and the independent marketplace bundle job; tag-driven release publishing
  the tarball with changelog notes.

### Changed

- Quote fetching moved from per-symbol curl subprocesses in QML to the Rust
  backend; the QML is now pure presentation.
- Chart requests in the panel go through `omastonk-qs chart` instead of curl.
- Shared parsing/formatting helpers extracted to `omarchy/Model.js`.

## [1.0.0] - 2026-08-20

### Added

- Watchlist support: track any number of symbols in one widget instead of one.
- Bar rotation: the widget cycles through the watchlist on a timer
  (`rotateSeconds` setting; `0` disables rotation).
- Staggered quote polling: every symbol stays fresh while requests are spread
  out to stay gentle on the quote provider.
- Symbol tabs in the chart panel with keyboard navigation: `Up`/`Down` or
  `J`/`K` switch symbols, `Left`/`Right` or `H`/`L` switch intervals.
- Watchlist editor: add symbols (one per line or space-separated), rename, and
  remove entries; the editor opens on right-click.
- Legacy `symbol` settings are migrated to the `symbols` watchlist on first save.
- GitHub Actions CI: manifest validation (mirrors `omarchy plugin validate`)
  and QML linting on every push and pull request.
- GitHub Actions release pipeline: tagging `vX.Y.Z` validates, packages
  `luca.omastonk-X.Y.Z.tar.gz`, and publishes the GitHub Release with the
  changelog section as release notes.

### Fixed

- Editor: Save now commits text still sitting in the add field, so
  type-a-symbol-and-hit-Save no longer discards it.

### Changed

- Rebranded from `b.omastonk` to `luca.omastonk` (new plugin id, author,
  version 1.0.0).
- The single `symbol` setting is superseded by the `symbols` watchlist array.
- Bar tooltips now hint "Add symbols" while the watchlist is empty.

## [0.0.15] - 2026-08-13

### Added

- Original single-symbol Omarchy bar widget by Brian Blakely (`b.omastonk`):
  live quote, daily direction, and 1D-5Y charts from Yahoo Finance.
