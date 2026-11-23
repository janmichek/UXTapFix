#!/bin/zsh
# Rebuilds the animated feature previews used at the top of README.md.
# The frames come from the same SwiftUI cards the Welcome screen shows.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v ffmpeg >/dev/null; then
    echo "ffmpeg is required to encode the previews (brew install ffmpeg)." >&2
    exit 1
fi

mkdir -p build assets/previews
swiftc \
    src/Setup/Theme.swift \
    src/Setup/Installer.swift \
    src/Setup/FeaturePreview.swift \
    tools/export-previews.swift \
    -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -o build/export-previews

rm -rf build/preview-frames
./build/export-previews build/preview-frames --kind all --fps 20

for kind in three-finger-tap quit-dock-app multi-action; do
    ffmpeg -hide_banner -loglevel error -y \
        -framerate 20 -i "build/preview-frames/$kind/frame-%04d.png" \
        -filter_complex "[0:v]split[a][b];[a]palettegen=reserve_transparent=1:stats_mode=diff[p];[b][p]paletteuse=alpha_threshold=128:dither=floyd_steinberg" \
        -loop 0 "assets/previews/$kind.gif"
    echo "Wrote assets/previews/$kind.gif"
done
