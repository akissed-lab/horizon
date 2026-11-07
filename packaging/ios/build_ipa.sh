#!/usr/bin/env bash
# Builds target/ios/Horizon.ipa (arm64, iOS 15+), unsigned but ad-hoc signed: the
# signing apps (ESign, Feather, Sideloadly) re-sign it with the user's certificate.
# See IOS.md.
#
#   ./packaging/ios/build_ipa.sh                    # release build
#   PROFILE=fast ./packaging/ios/build_ipa.sh       # quicker to build, slower game
#   CARGO_FLAGS="--features mods" ./packaging/ios/build_ipa.sh
#
# Needs macOS with Xcode's command line tools (clang, sips, codesign, ditto) and
# the aarch64-apple-ios Rust target (added if missing). No Xcode project: the
# game is a Rust static library, linked against packaging/ios/main.m by hand.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROFILE="${PROFILE:-release}"
MIN_IOS="${IOS_MIN_VERSION:-15.0}"
SDK="${IOS_SDK:-iphoneos}"
OUT=target/ios
APP="$OUT/Payload/Horizon.app"
BUNDLE_ID="${HORIZON_BUNDLE_ID:-dev.horizonlab.horizon}"
VERSION="${HORIZON_VERSION:-$(sed -n 's/^version = "\([^"]*\)"/\1/p' crates/horizon-ios/Cargo.toml | head -n1)}"
ICON=packaging/icons/ios-1024.png

if ! rustup target list --installed | grep -qx aarch64-apple-ios; then
  rustup target add aarch64-apple-ios
fi
cargo build -p horizon-ios --profile "$PROFILE" --target aarch64-apple-ios ${CARGO_FLAGS:-}

LIB="target/aarch64-apple-ios/$PROFILE/libhorizon.a"
[[ -f "$LIB" ]] || { echo "Horizon: expected $LIB after the cargo build" >&2; exit 1; }
[[ -f "$ICON" ]] || { echo "Horizon: missing $ICON" >&2; exit 1; }

CLANG=$(xcrun --sdk "$SDK" --find clang)
SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
ARCH=(-target "arm64-apple-ios$MIN_IOS" -isysroot "$SDK_PATH" -miphoneos-version-min="$MIN_IOS")

rm -rf "$OUT/Payload"
mkdir -p "$APP"

# main.m is plain C/ObjC: it must not start UIKit before Rust does (see the file).
"$CLANG" "${ARCH[@]}" -fobjc-arc -O2 -c packaging/ios/main.m -o "$OUT/main.o"

# Framework list: winit's iOS backend (UIKit, CoreGraphics, CoreMotion), wgpu's
# Metal backend (Metal, QuartzCore, CoreVideo, IOSurface), cpal's CoreAudio
# backend, and the SystemConfiguration/Security frameworks the network stack
# touches. The Rust libraries only declare link flags in objects the linker may
# not pull in, so they are named here explicitly.
"$CLANG" "${ARCH[@]}" -o "$APP/Horizon" "$OUT/main.o" "$LIB" \
  -framework UIKit \
  -framework Foundation \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework Metal \
  -framework CoreVideo \
  -framework IOSurface \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreMotion \
  -framework GameController \
  -framework Security \
  -framework SystemConfiguration \
  -lc++ -lz

# Rust's debug symbols and the local symbol names are of no use on a phone.
STRIP=$(xcrun --sdk "$SDK" --find strip)
"$STRIP" -x "$APP/Horizon" 2>/dev/null || true

sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" packaging/ios/Info.plist > "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

# Every size iOS asks for, rendered from the 1024px master. The @2x/@3x suffixes
# are what CFBundleIconFiles' base names (Icon-60, Icon-76, ...) resolve to.
icon() { sips -z "$2" "$2" "$ICON" --out "$APP/$1" >/dev/null; }
icon Icon-20@2x.png 40
icon Icon-20@3x.png 60
icon Icon-29@2x.png 58
icon Icon-29@3x.png 87
icon Icon-40@2x.png 80
icon Icon-40@3x.png 120
icon Icon-60@2x.png 120
icon Icon-60@3x.png 180
icon Icon-76.png 76
icon Icon-76@2x.png 152
icon Icon-83.5@2x.png 167
icon Icon-1024.png 1024

# Ad-hoc signature keeps the bundle structurally valid on the Mac; the signing
# app replaces it with the user's certificate before installing. IOS_SIGN_IDENTITY
# signs with a real identity here instead (for a Mac with a provisioning profile).
identity="${IOS_SIGN_IDENTITY:--}"
if [[ "$identity" != "-" && -n "${IOS_ENTITLEMENTS:-}" ]]; then
  codesign --force --timestamp --options runtime --entitlements "$IOS_ENTITLEMENTS" --sign "$identity" "$APP"
else
  codesign --force --sign "$identity" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

# zip (not ditto) with ZIP_DEFLATED and no resource forks: ESign and Feather read
# a plain archive, and `Payload/` has to be the first entry.
rm -f "$OUT/Horizon.ipa"
(cd "$OUT" && zip -qry Horizon.ipa Payload)
ls -lh "$OUT/Horizon.ipa"
