#!/usr/bin/env bash
set -euo pipefail

if ! xcrun --find swift-format >/dev/null 2>&1; then
  echo "swift-format is not available in the active Xcode toolchain." >&2
  exit 127
fi

xcrun swift-format format --recursive --in-place Toernberechnung ToernberechnungTests
