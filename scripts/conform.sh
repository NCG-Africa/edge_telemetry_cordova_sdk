#!/usr/bin/env bash
# Conformance gate (#54, processor #40): check every golden batch against the event catalogue at the
# ref pinned in catalogue.version. The goldens live in three places (native Android, native iOS,
# JS) and are checked as one set, since `emitted_by` is per SDK. Needs go and git.
# PROCESSOR_DIR reuses a local processor checkout instead of cloning the pinned ref.
# Not in CI (Actions spend): run it by hand before each release.
set -euo pipefail
shopt -s nullglob
root="$(cd "$(dirname "$0")/.." && pwd)"
ref="$(cat "$root/catalogue.version")"
goldens="$(mktemp -d)"
cleanup=("$goldens")
trap 'rm -rf "${cleanup[@]}"' EXIT
for f in "$root"/android/src/test/resources/golden/*.json; do cp "$f" "$goldens/android-$(basename "$f")"; done
for f in "$root"/ios/Tests/golden/*.json; do cp "$f" "$goldens/ios-$(basename "$f")"; done
for f in "$root"/test/golden/*.json; do cp "$f" "$goldens/js-$(basename "$f")"; done
src="${PROCESSOR_DIR:-}"
if [ -z "$src" ]; then
  src="$(mktemp -d)"
  cleanup+=("$src")
  git clone -q --depth 1 --branch "$ref" https://github.com/NCG-Africa/edge_telemetry_processor_go.git "$src"
fi
cd "$src" && go run ./cmd/conform "$goldens"
