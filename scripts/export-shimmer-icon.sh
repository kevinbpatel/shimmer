#!/bin/sh
# Export the README and in-app icons from the Icon Composer document Xcode builds.
set -eu
cd "$(dirname "$0")/.."
ictool="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" Glimmer/AppIcon.icon --export-image \
  --output-file docs/assets/icon-512.png --platform macOS \
  --rendition Default --width 512 --height 512 --scale 1 --design-generation 27
"$ictool" Glimmer/AppIcon.icon --export-image \
  --output-file docs/assets/icon-social.png --platform macOS \
  --rendition Default --width 640 --height 640 --scale 1 --design-generation 27

# SwiftUI uses these named image variants to follow the window's appearance.
# The compiled app icon's legacy NSImage representation only exposes Default.
about_assets=Glimmer/Assets.xcassets/AboutAppIcon.imageset
for rendition in Default Dark; do
  for scale in 1 2; do
    "$ictool" Glimmer/AppIcon.icon --export-image \
      --output-file "$about_assets/$rendition@${scale}x.png" --platform macOS \
      --rendition "$rendition" --width 96 --height 96 --scale "$scale" --design-generation 27
  done
done
