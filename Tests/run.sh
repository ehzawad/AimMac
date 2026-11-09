#!/bin/bash
# Compiles and runs the checks in main.swift.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
  -o build/checks main.swift ../Shared/*.swift ../Mac/Sources/DisplayMap.swift ../Mac/Sources/KeyLayout.swift
./build/checks
