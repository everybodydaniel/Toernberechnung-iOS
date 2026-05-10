#!/usr/bin/env bash
set -euo pipefail

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build/docbuild}"
OUTPUT_DIR="${OUTPUT_DIR:-docs/api}"
SCHEME="${SCHEME:-Toernberechnung}"
DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

xcodebuild docbuild \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH"

ARCHIVE_PATH="$(find "$DERIVED_DATA_PATH" -name '*.doccarchive' -type d | head -n 1)"

if [[ -z "$ARCHIVE_PATH" ]]; then
  echo "No DocC archive found." >&2
  exit 1
fi

$(xcrun --find docc) process-archive transform-for-static-hosting "$ARCHIVE_PATH" \
  --hosting-base-path Toernberechnung-iOS \
  --output-path "$OUTPUT_DIR"

echo "API documentation written to $OUTPUT_DIR"
