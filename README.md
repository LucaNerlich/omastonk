# Omastonk

Omastonk is a multi-instance market widget for the Omarchy bar. It shows a
selected symbol, current quote, daily direction, and charts ranging from one day
to five years.

![Omastonk screenshot](preview.png)

## Install

```bash
omarchy plugin add https://github.com/brianblakely/omastonk.git --enable --yes
```

To add another instance, edit `~/.config/omarchy/shell.json` and insert another
entry at the desired position in one of the `bar.layout.left`, `center`, or
`right` arrays:

```json
{ "id": "b.omastonk" }
```

Each repeated entry creates an independent instance. Omarchy reloads the bar
when the file changes.

## Usage

Omastonk starts without a symbol. Click it to choose a symbol and open its
chart; right-click it to edit the symbol. In the chart, use the arrow keys or
`HJKL` to switch intervals and `Escape` to close.

Each instance keeps its own symbol, so multiple widgets can track different
markets.

## Update

```bash
omarchy plugin update b.omastonk
```

## Uninstall

```bash
omarchy plugin remove b.omastonk
```
