#!/bin/bash
# Generate the checked-in macOS .icns from the source brand mark.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/../branding/hyperdisplay-mark.svg"
MENUBAR_SOURCE="$ROOT/../branding/hyperdisplay-menubar.svg"
RESOURCE_DIR="$ROOT/Resources"
ICONSET="$RESOURCE_DIR/Hyperdisplay.iconset"
OUTPUT="$RESOURCE_DIR/Hyperdisplay.icns"
MENUBAR_OUTPUT="$RESOURCE_DIR/HyperdisplayMenuBar.png"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert is required to regenerate $OUTPUT" >&2
    exit 1
fi

mkdir -p "$RESOURCE_DIR" "$ICONSET"

for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" "$SOURCE" -o "$ICONSET/icon_${size}x${size}.png"
    retina=$((size * 2))
    rsvg-convert -w "$retina" -h "$retina" "$SOURCE" -o "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil --convert icns "$ICONSET" --output "$OUTPUT"
rsvg-convert -w 36 -h 36 "$MENUBAR_SOURCE" -o "$MENUBAR_OUTPUT"
echo "Generated $OUTPUT"
