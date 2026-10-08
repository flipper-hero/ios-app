#!/usr/bin/env bash
# Builds the App Store edition of FlipperHero.
#
# The FLIPPERHERO_STORE compilation condition strips the red team capabilities
# (badusb_execute, rpc_raw, gpio, engagement mode, the report tool and the
# operator persona) from every target, including the SwiftPM packages. The only
# way the flag reaches the packages is this command-line override, so never
# archive the App Store build from Xcode directly: it would silently be the
# full open source edition.
#
# Usage:
#   scripts/build-store.sh build     # DebugStore build into /tmp
#   scripts/build-store.sh archive   # ReleaseStore .xcarchive
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
else
  echo "xcodegen not on PATH, keeping the existing FlipperHero.xcodeproj"
fi

action="${1:-build}"
shift || true

if [ "$action" = "archive" ]; then
  xcodebuild -project FlipperHero.xcodeproj -scheme FlipperHeroStore \
    -configuration ReleaseStore -destination 'generic/platform=iOS' \
    -archivePath build/FlipperHero-Store.xcarchive CODE_SIGNING_ALLOWED=NO \
    OTHER_SWIFT_FLAGS='-D FLIPPERHERO_STORE' archive "$@"
else
  xcodebuild -project FlipperHero.xcodeproj -scheme FlipperHeroStore \
    -configuration DebugStore -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/fh-store CODE_SIGNING_ALLOWED=NO \
    OTHER_SWIFT_FLAGS='-D FLIPPERHERO_STORE' build "$@"
fi
