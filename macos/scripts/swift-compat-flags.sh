#!/bin/sh
# Emits extra swiftc flags this machine needs, or nothing at all.
#
# Some Command Line Tools installs end up with two module maps that both define the SwiftBridging
# module — a stale `usr/include/swift/module.modulemap` left behind beside the current
# `bridging.modulemap`. Clang loads both and rejects the redefinition, which breaks every compile
# that imports Foundation. The real fix is to delete the stale file (see macos/README.md), but it
# lives in a root-owned directory, so this maps it to an empty file with a VFS overlay instead.
#
# The overlay has to go to -Xfrontend, not -Xcc: the failure happens inside the nested module
# build for Foundation's .swiftinterface, and only frontend flags reach that.
#
# Usage: swift-compat-flags.sh <build-dir>
set -eu

BUILD=${1:-build}
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
echo 'import Foundation' > "$probe/probe.swift"

if swiftc -typecheck "$probe/probe.swift" >/dev/null 2>&1; then
    exit 0 # healthy toolchain, no workaround needed
fi

stale=$(swiftc -typecheck "$probe/probe.swift" 2>&1 \
    | grep -m1 "redefinition of module 'SwiftBridging'" \
    | cut -d: -f1)

[ -n "$stale" ] && [ -f "$stale" ] || exit 0 # some other failure — let the real build report it

mkdir -p "$BUILD"
abs_build=$(cd "$BUILD" && pwd)
: > "$abs_build/empty.modulemap"
cat > "$abs_build/modulemap-overlay.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": false,
  "roots": [
    { "type": "file",
      "name": "$stale",
      "external-contents": "$abs_build/empty.modulemap" }
  ]
}
EOF

echo "-Xfrontend -vfsoverlay -Xfrontend $abs_build/modulemap-overlay.yaml"
