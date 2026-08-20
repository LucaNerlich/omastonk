# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
