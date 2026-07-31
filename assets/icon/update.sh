#!/usr/bin/env bash
# Build alacritty.icns for the vc-terminal.app bundle from a square master icon.
# Full-bleed 1:1 — no padding/border (macOS applies its own mask).
# Flow ported from labs/vc-surface (wezterm fork) — same brand mark, same pipeline.
#
# Default source: assets/icon/vc-terminal-icon.png (the vc_ brand mark).
# Override: VC_TERMINAL_ICON_SRC=/path/to/icon.png|svg
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT/assets/icon"

src="${VC_TERMINAL_ICON_SRC:-$ROOT/assets/icon/vc-terminal-icon.png}"
if [[ ! -f "$src" ]]; then
  echo "icon source not found: set VC_TERMINAL_ICON_SRC" >&2
  exit 1
fi

if [[ -n "${CONVERT_BIN:-}" ]]; then
  convert_bin="$CONVERT_BIN"
elif command -v magick >/dev/null 2>&1; then
  convert_bin="magick"
elif command -v convert >/dev/null 2>&1; then
  convert_bin="convert"
else
  convert_bin=""
fi

render_png() {
  local dim="$1"
  local output="$2"
  local ext="${src##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

  if [[ "$ext" == "svg" ]]; then
    if command -v rsvg-convert >/dev/null 2>&1; then
      rsvg-convert -w "$dim" -h "$dim" "$src" -o "$output"
    elif [[ -n "$convert_bin" ]]; then
      "$convert_bin" -background none -density 300 -resize "!${dim}x${dim}" "$src" "$output"
    else
      echo "need rsvg-convert or imagemagick for SVG source" >&2
      exit 1
    fi
  else
    # PNG/other raster — prefer sips on macOS for fidelity
    if command -v sips >/dev/null 2>&1; then
      sips -z "$dim" "$dim" "$src" --out "$output" >/dev/null
    elif [[ -n "$convert_bin" ]]; then
      "$convert_bin" -background none -resize "!${dim}x${dim}" "$src" "$output"
    else
      echo "need sips or imagemagick for raster source" >&2
      exit 1
    fi
  fi
}

# Linux / generic 128px (full bleed, no border)
render_png 128 terminal.png

# macOS iconset — 1:1 full bleed at every size (no 10% padding frame)
rm -rf terminal.iconset
mkdir terminal.iconset
render_png 16  terminal.iconset/icon_16x16.png
render_png 32  terminal.iconset/icon_16x16@2x.png
render_png 32  terminal.iconset/icon_32x32.png
render_png 64  terminal.iconset/icon_32x32@2x.png
render_png 128 terminal.iconset/icon_128x128.png
render_png 256 terminal.iconset/icon_128x128@2x.png
render_png 256 terminal.iconset/icon_256x256.png
render_png 512 terminal.iconset/icon_256x256@2x.png
render_png 512 terminal.iconset/icon_512x512.png
render_png 1024 terminal.iconset/icon_512x512@2x.png

# CFBundleIconFile stays 'alacritty.icns' — the brand lives in bundle
# metadata and pixels, the file name keeps the upstream contract.
ICNS_OUT="$ROOT/extra/osx/vc-terminal.app/Contents/Resources/alacritty.icns"
if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns terminal.iconset -o "$ICNS_OUT"
elif command -v png2icns >/dev/null 2>&1; then
  png2icns "$ICNS_OUT" \
    terminal.iconset/icon_16x16.png \
    terminal.iconset/icon_32x32.png \
    terminal.iconset/icon_128x128.png \
    terminal.iconset/icon_256x256.png \
    terminal.iconset/icon_512x512.png
else
  echo "iconutil or png2icns required" >&2
  exit 1
fi
rm -rf terminal.iconset

echo "ok: terminal.png + $ICNS_OUT from $src (full-bleed 1:1)"
