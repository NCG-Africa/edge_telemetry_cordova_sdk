#!/usr/bin/env bash
# Spec Q5: build example/ for one platform, this plugin + the example scenarios plugin by local path.
# Usage: scripts/example-build.sh android|ios
# EDGE_RUM_ENDPOINT defaults to mock-ingest as the emulator / simulator sees the host; on a real
# device set it to http://<laptop LAN ip>:4319/collector/telemetry.
set -euo pipefail

platform="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
cordova="npx --yes cordova@13"

case "$platform" in
  android) spec="android@15"; host="10.0.2.2" ;;
  ios) spec="ios@8"; host="localhost" ;;
  *) echo "usage: $0 android|ios" >&2; exit 2 ;;
esac
endpoint="${EDGE_RUM_ENDPOINT:-http://$host:4319/collector/telemetry}"

# By local path, as unpacked from `npm pack`: the repo root holds example/ itself, which cordova would copy into
# example/plugins/ recursively.
pack="$(mktemp -d)"
(cd "$root" && npm pack --pack-destination "$pack" >/dev/null)
tar xzf "$pack"/*.tgz -C "$pack"

cd "$root/example"
rm -rf platforms plugins
$cordova platform add "$spec" --no-telemetry
$cordova plugin add ./scenarios --nosave --no-telemetry
$cordova plugin add "$pack/package" --nosave --no-telemetry \
  --variable EDGE_RUM_API_KEY="${EDGE_RUM_API_KEY:-example-key}" \
  --variable EDGE_RUM_ENDPOINT="$endpoint"

if [ "$platform" = ios ]; then
  $cordova build ios --emulator --no-telemetry -- --buildFlag="CODE_SIGNING_ALLOWED=NO"
else
  $cordova build android --no-telemetry
fi
echo "[example] $platform built, ingest at $endpoint"
