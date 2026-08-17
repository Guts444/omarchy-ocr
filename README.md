# omarchy-ocr

Grab text from the screen, a window, or a clipboard image — from the Omarchy bar.

The bar glyph (`A▤`) is a launcher plus last-result status (`· 42` chars, or `· !` on error). Click it to open the overlay: four capture modes, the recognized text (auto-copied), and a searchable history of the last 20 results.

## Install

```sh
omarchy plugin add https://github.com/Guts444/omarchy-ocr.git --enable
omarchy restart shell
```

`omarchy plugin enable` places the widget in the bar (default: right) and is enough for the overlay to load — the plugin id is then considered enabled. After install or update, restart the shell so the fresh QML is compiled.

Do not enable this from a development checkout until you mean it to land on the live bar.

## Use

Click the bar glyph, then pick a mode:

| Button | What it does |
|---|---|
| Select region | `slurp` a rectangle, OCR that crop |
| Clipboard image | OCR the image currently on the clipboard |
| Full screen | `grim` the whole display |
| Window | OCR the focused window (`hyprctl activewindow` geometry) |

Text is copied with `wl-copy`. Click a history row to copy it again; × deletes that entry. The search box filters history.

History lives in `~/.cache/omarchy/ocr/history.json` (atomic write, corrupt-file recovery). Last-run status is `~/.cache/omarchy/ocr/status.json`.

## Configuration

```sh
omarchy bar set io.github.guts444.ocr langs eng
omarchy bar set io.github.guts444.ocr historySize 20
omarchy bar set io.github.guts444.ocr upscale true
```

`langs` is comma-separated (`eng,por`) or tesseract-style (`eng+por`). Only languages already installed for tesseract will work — this plugin does not install language packs.

`upscale` 2×-scales small captures before OCR (ImageMagick `magick`, then `ffmpeg` if magick is missing). Turn it off if you want the raw pixels.

## How OCR is run

`ocr.py` (stdlib only) is the helper the overlay/widget spawn:

1. Capture via grim / slurp / wl-paste / hyprctl
2. Upscale small regions 2× when enabled
3. Run tesseract twice (`--psm 6` and `--psm 11`), compare per-word TSV confidence, keep the better result
4. Copy text, append history, print `{ok, text, chars, langs, error, ms}`

```sh
python3 ocr.py region|clip|screen|window
python3 ocr.py region --geom '100,100 400x200'   # skip slurp (tests)
python3 ocr.py history list
```

## Requirements

Already on a stock Omarchy 4 box:

- tesseract (English traineddata)
- grim, slurp
- wl-clipboard (`wl-copy`, `wl-paste`)
- hyprctl (window mode)
- ImageMagick (`magick`) — optional, used for upscale

No extra packages, no venv, no Python third-party deps.

## Removal

```sh
omarchy plugin disable io.github.guts444.ocr
omarchy plugin remove io.github.guts444.ocr
```

Cache (`~/.cache/omarchy/ocr/`) is left in place; delete it if you want history gone too.

## License

MIT
