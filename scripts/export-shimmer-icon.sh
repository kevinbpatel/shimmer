#!/bin/sh
# Export the README icon from the same Icon Composer bundle Xcode builds.
set -eu
cd "$(dirname "$0")/.."
ictool="$(xcode-select -p)/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" Glimmer/AppIcon.icon --export-image \
  --output-file docs/assets/icon-512.png --platform macOS \
  --rendition Default --width 512 --height 512 --scale 1
