#!/bin/bash
# Builds Night Clock for the old iPad "Haam" (iPad 4th gen, iOS 10.3.4,
# 32-bit) — the Flutter app can't run there. Run from anywhere:
#   ipad/build.sh            build ipad/build/NightClock.ipa
#   ipad/build.sh install    ...and install it on the iPad (USB, else Wi-Fi)
# Preview switches as in the Flutter app: FORCE_NIGHT=1 ipad/build.sh install
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
OUT="$HERE/build"
APP="$OUT/Payload/NightClock.app"
FLUTTER="$HOME/FlutterDev/flutter/bin/flutter"

# Apple's current SDK has no 32-bit libraries, so this links against
# iOS 10.3's (from theos/sdks), patched once for today's linker.
SDK="$HOME/Library/Developer/LegacySDKs/iPhoneOS10.3.sdk"
if [ ! -d "$SDK" ]; then
  echo "Fetching the iOS 10.3 SDK…"
  TMP="$(mktemp -d)"
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git "$TMP/sdks"
  git -C "$TMP/sdks" sparse-checkout set iPhoneOS10.3.sdk
  mkdir -p "$(dirname "$SDK")"
  cp -R "$TMP/sdks/iPhoneOS10.3.sdk" "$SDK"
  rm -rf "$TMP"
  python3 -I "$HERE/tool/fix_sdk.py" "$SDK"
fi

# Nabla glyphs and icons, rendered by Flutter (iOS 10 can't draw the font).
if [ ! -f "$OUT/glyphs/glyphs.json" ] || [ "$HERE/tool/glyphs_test.dart" -nt "$OUT/glyphs/glyphs.json" ]; then
  echo "Rendering glyphs…"
  (cd "$REPO" && "$FLUTTER" test --timeout 120s ipad/tool/glyphs_test.dart >/dev/null)
fi

rm -rf "$OUT/Payload"
mkdir -p "$APP"
# The room this iPad sits in: it opens there (the phone's is in lights.json).
IPAD_ROOM="M&M's Room"
export START_ROOM="${START_ROOM:-$IPAD_ROOM}"
python3 -I "$HERE/tool/make_config.py" "$REPO/lights.json" "$OUT/Config.h"

echo "Compiling…"
# -marm: the new linker marks a Thumb entry point wrongly for 32-bit
# (even LC_MAIN offset), which crashes at launch with SIGILL.
# -fno-objc-exceptions: the old SDK lacks the 32-bit (SjLj) unwinder that
# ARC's cleanups would call; the app never throws.
# The 32-bit math helpers (__divsi3, __fixdfdi, …) are also missing from
# its stubs, so they're linked statically from Xcode's compiler-rt.
RT="$(xcrun clang -print-resource-dir)/lib/darwin/libclang_rt.cc_kext_ios.a"
xcrun clang -arch armv7 -marm -miphoneos-version-min=10.0 -isysroot "$SDK" \
  -fobjc-arc -fno-objc-exceptions -fno-exceptions -O2 -Wall -Wno-unused-function -I "$OUT" \
  "$HERE"/src/*.m "$RT" \
  -framework UIKit -framework Foundation -framework AVFoundation \
  -framework QuartzCore -framework CoreGraphics -framework CoreMedia -framework Security \
  -o "$APP/NightClock"

cp "$HERE/Info.plist" "$APP/Info.plist"
plutil -replace CFBundleIdentifier -string "${BUNDLE_ID:-mv.seastack.nightclock}" "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
cp "$OUT"/glyphs/*.png "$OUT/glyphs/glyphs.json" "$APP/"
cp "$REPO"/fonts/Inter-{Light,Regular,Medium,SemiBold}.ttf "$APP/"
# Backgrounds (the user's clips, gitignored; the drawn sky covers without
# them). By day the shrunk clips play, looping; after dark the iPad shows
# a still from the middle of the clip instead — the jump at each restart
# was distracting in the dark. Stills come from the full-size originals in
# the repo root when present, else the shrunk copies.
for name in sunny rainy homescreen; do
  [ -f "$REPO/assets/video/$name.mp4" ] && cp "$REPO/assets/video/$name.mp4" "$APP/"
done
for name in night rainy homescreen; do
  src=""
  for c in "$REPO/$name.mp4" "$REPO/$name.mov" "$REPO/assets/video/$name.mp4"; do
    [ -f "$c" ] && { src="$c"; break; }
  done
  [ -n "$src" ] || continue
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")"
  ffmpeg -v error -y -ss "$(awk "BEGIN{print $dur/2}")" -i "$src" -frames:v 1 \
    -vf "scale=-2:'min(1536,ih)'" -q:v 3 "$APP/$name.jpg"
done
python3 -I "$HERE/tool/make_images.py" "$OUT/glyphs" "$APP"

# Signing: the seastack team's wildcard development profile, which lists
# the iPad. Xcode refreshes it; its certificate is in the login keychain.
# The iPad's UDID: $IPAD_UDID, else ipad/.udid (gitignored), else the
# iPad plugged in now. Team and bundle id can be overridden the same way.
UDID="${IPAD_UDID:-$(cat "$HERE/.udid" 2>/dev/null || idevice_id -l 2>/dev/null | head -1)}"
[ -n "$UDID" ] || { echo "Set IPAD_UDID, write it to ipad/.udid, or plug the iPad in"; exit 1; }
TEAM="${TEAM_ID:-D88J248KNQ}"
BUNDLE="${BUNDLE_ID:-mv.seastack.nightclock}"
PROFILE=""
for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
  plist="$(security cms -D -i "$p" 2>/dev/null)" || continue
  if grep -q "$UDID" <<<"$plist" && grep -q "<string>$TEAM\.\*</string>" <<<"$plist"; then
    PROFILE="$p"
  fi
done
[ -n "$PROFILE" ] || { echo "No profile for team $TEAM lists the iPad ($UDID)"; exit 1; }
security cms -D -i "$PROFILE" > "$OUT/profile.plist"
IDENTITY=""
for i in 0 1 2 3 4 5 6 7 8 9; do
  sha="$(plutil -extract DeveloperCertificates.$i raw "$OUT/profile.plist" 2>/dev/null | base64 -d | shasum | cut -d' ' -f1 | tr a-f A-F)" || break
  [ -n "$sha" ] || break
  if security find-identity -v -p codesigning | grep -q "$sha"; then IDENTITY="$sha"; break; fi
done
[ -n "$IDENTITY" ] || { echo "No signing identity in the keychain matches the profile"; exit 1; }
cp "$PROFILE" "$APP/embedded.mobileprovision"
plutil -extract Entitlements xml1 -o "$OUT/ent.plist" "$OUT/profile.plist"
plutil -replace application-identifier -string "$TEAM.$BUNDLE" "$OUT/ent.plist"
codesign -f -s "$IDENTITY" --entitlements "$OUT/ent.plist" --generate-entitlement-der "$APP" >/dev/null

(cd "$OUT" && rm -f NightClock.ipa && zip -qr NightClock.ipa Payload)
echo "Built $OUT/NightClock.ipa"

if [ "${1:-}" = "install" ]; then
  # Over USB if it's plugged in, else over Wi-Fi (needs "Show this iPad
  # when on Wi-Fi" ticked in Finder once).
  NET=""; idevice_id -l | grep -q . || NET="-n"
  ideviceinstaller $NET install "$OUT/NightClock.ipa" | tail -1
  echo
fi
