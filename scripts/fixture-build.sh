#!/usr/bin/env bash
# Spec V1 fixture: fresh `cordova create` app + this plugin by local path, built for one platform.
# Usage: scripts/fixture-build.sh android|ios [workdir]
set -euo pipefail

platform="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="${2:-$(mktemp -d)}"
cordova="npx --yes cordova@13"

case "$platform" in
  android) spec="android@15"; www="platforms/android/app/src/main/assets/www" ;;
  ios) spec="ios@8"; www="platforms/ios/www" ;;
  *) echo "usage: $0 android|ios [workdir]" >&2; exit 2 ;;
esac

(cd "$root" && npm run build)

cd "$work"
rm -rf fixture
$cordova create fixture com.nathanclaire.rum.fixture Fixture --no-telemetry
cd fixture
# Spec K5 floor; cordova-ios 8 defaults apps to 13.0. Consumers set this themselves.
sed -i.bak 's|</widget>|    <preference name="deployment-target" value="14.0" />\n</widget>|' config.xml
$cordova platform add "$spec" --no-telemetry
$cordova plugin add "$root" --no-telemetry

if [ "$platform" = ios ]; then
  $cordova build ios --emulator --no-telemetry -- --buildFlag="CODE_SIGNING_ALLOWED=NO"
else
  $cordova build android --no-telemetry
fi

# window.EdgeRum: the module is registered to clobber EdgeRum and its file is in the built app.
grep -q '"clobbers": \[' "$www/cordova_plugins.js"
grep -A3 '"clobbers"' "$www/cordova_plugins.js" | grep -q '"EdgeRum"'
test -f "$www/plugins/@nathanclaire/rum-cordova/www/edge-rum.js"
echo "[fixture] $platform OK ($work/fixture)"
