#!/bin/bash
# Builds bin/ds2mac from source. Needs the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"
# Build next to the old binary and rename, so a running copy is never overwritten in place.
swiftc -O -target arm64-apple-macos14 -import-objc-header CGVirtualDisplay.h -o ../bin/ds2mac.new ds2mac.swift
codesign --force --sign - ../bin/ds2mac.new 2>/dev/null
mv -f ../bin/ds2mac.new ../bin/ds2mac
echo "built $(cd .. && pwd)/bin/ds2mac"
