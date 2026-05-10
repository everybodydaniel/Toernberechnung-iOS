#!/usr/bin/env bash
set -euo pipefail

DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"

xcodebuild build \
  -scheme Toernberechnung \
  -destination "$DESTINATION"
