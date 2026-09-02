#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== 1. Regenerating Xcode project (XcodeGen) ==="
xcodegen generate

echo "=== 2. Building Glance (Release) into ./Build ==="
rm -rf Build/
xcodebuild -project Glance.xcodeproj \
  -scheme Glance \
  -configuration Release \
  -derivedDataPath Build/DerivedData \
  CONFIGURATION_BUILD_DIR="$PWD/Build" \
  build

echo "=== 3. Verifying code signature ==="
# Do NOT re-sign here, and do NOT sign ad-hoc (`--sign -`).
#
# TCC keys the Screen Recording grant to the app's designated requirement. An
# ad-hoc signature has no team identifier, so TCC falls back to the cdhash --
# which changes on every build, silently revoking the permission each time.
# xcodebuild already signed the bundle with a stable identity; a second
# `codesign --force --deep` pass would rewrite that cdhash and break it again.
codesign --verify --strict --verbose=2 Build/Glance.app
codesign -dv --verbose=2 Build/Glance.app 2>&1 | grep -E 'Identifier=|TeamIdentifier|Authority=Apple Development'

echo "=== 4. Launching Glance ==="
killall Glance 2>/dev/null || true

# Wait for the old instance to actually exit. Calling `open` while LaunchServices
# still has the dying process registered fails with -600 (procNotFound).
for _ in $(seq 1 40); do
  pgrep -x Glance >/dev/null || break
  sleep 0.1
done

# Launch the .app bundle, never the raw Mach-O inside it. Executing
# Contents/MacOS/Glance directly makes the process a child of the terminal, and
# macOS then attributes the screen-recording indicator to the terminal (Ghostty)
# instead of to Glance.
open Build/Glance.app

echo
echo "=== Done. Glance is running in the menu bar. ==="
echo "Stream its logs with:"
echo "  log stream --style compact --level debug --predicate 'subsystem == \"com.filippocappa.glance\"'"
echo "or re-run this script as: ./build_and_run.sh --logs"

if [ "$1" = "--logs" ]; then
  echo
  exec log stream --style compact --level debug \
    --predicate 'subsystem == "com.filippocappa.glance"'
fi
