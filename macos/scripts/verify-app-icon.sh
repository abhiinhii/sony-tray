#!/bin/sh
# Validate the icon named by a source or built bundle's Info.plist using native macOS tools.
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <Info.plist> <Resources directory>" >&2
    exit 2
fi

icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$1")
case "$icon_name" in
    *.icns) ;;
    *) icon_name="$icon_name.icns" ;;
esac
icon_path="$2/$icon_name"
if [ ! -s "$icon_path" ]; then
    echo "FAIL: CFBundleIconFile references missing icon: $icon_path" >&2
    exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/sonytray-icon-check.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
iconutil --convert iconset --output "$work_dir/AppIcon.iconset" "$icon_path"

# macOS uses both physical pixels and point sizes; do not omit Retina representations even
# where they have the same pixel dimensions as a larger non-Retina representation.
for representation in \
    icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 \
    icon_128x128:128 icon_128x128@2x:256 icon_256x256:256 icon_256x256@2x:512 \
    icon_512x512:512 icon_512x512@2x:1024; do
    name=${representation%:*}
    pixels=${representation#*:}
    png="$work_dir/AppIcon.iconset/$name.png"
    if [ ! -s "$png" ]; then
        echo "FAIL: $icon_path is missing $name.png" >&2
        exit 1
    fi
    dimensions=$(sips -g pixelWidth -g pixelHeight "$png")
    width=$(printf '%s\n' "$dimensions" | awk '/pixelWidth:/{print $2}')
    height=$(printf '%s\n' "$dimensions" | awk '/pixelHeight:/{print $2}')
    if [ "$width" != "$pixels" ] || [ "$height" != "$pixels" ]; then
        echo "FAIL: $name.png is ${width}x${height}; expected ${pixels}x${pixels}" >&2
        exit 1
    fi
done

echo "PASS: $icon_path contains all 10 native icon representations (16–1024 pixels)"
