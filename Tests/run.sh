#!/bin/bash
# Builds and runs DeskKit's self-tests (the parts that need no permissions), for this Mac's
# architecture only.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' ! -path 'Sources/App/main.swift' | sort)

mkdir -p build
swiftc -module-name DeskKit -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
    -framework AppKit -framework ServiceManagement \
    -Xlinker -weak_framework -Xlinker ScreenCaptureKit \
    "${SOURCES[@]}" Tests/main.swift -o build/DeskKitTests
build/DeskKitTests
