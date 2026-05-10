#!/usr/bin/env bash
set -euo pipefail

DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.4.1}"

xcodebuild test \
  -scheme Toernberechnung \
  -destination "$DESTINATION"
