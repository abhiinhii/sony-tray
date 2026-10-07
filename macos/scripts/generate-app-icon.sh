#!/bin/sh
# Rebuild the macOS application icon from the same brand artwork used by the README.
# The source is 256px; larger representations retain that artwork rather than inventing detail.
set -eu

macos_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_png="$macos_dir/../docs/icon.png"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/sonytray-icon-build.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
mkdir "$work_dir/AppIcon.iconset"

for representation in \
    icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 \
    icon_128x128:128 icon_128x128@2x:256 icon_256x256:256 icon_256x256@2x:512 \
    icon_512x512:512 icon_512x512@2x:1024; do
    name=${representation%:*}
    pixels=${representation#*:}
    sips --resampleHeightWidth "$pixels" "$pixels" "$source_png" \
        --out "$work_dir/AppIcon.iconset/$name.png" >/dev/null
done

iconutil --convert icns --output "$macos_dir/Resources/AppIcon.icns" "$work_dir/AppIcon.iconset"
sh "$macos_dir/scripts/verify-app-icon.sh" "$macos_dir/Resources/Info.plist" "$macos_dir/Resources"
