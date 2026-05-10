#!/usr/bin/env bash
set -euo pipefail

mkdir -p reports

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "SwiftLint is not installed. Install it with: brew install swiftlint" >&2
  exit 127
fi

swiftlint lint --strict
swiftlint lint --reporter json > reports/swiftlint.json
