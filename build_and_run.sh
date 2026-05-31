#!/bin/bash
set -e

# Change directory to the script's directory
cd "$(dirname "$0")"

echo "=== 1. Regenerating Xcode Project using XcodeGen ==="
xcodegen generate

echo "=== 2. Building Glance Application to Stable Local Build/ Directory ==="
# Clean old builds to prevent caching issues
rm -rf Build/

xcodebuild -project Glance.xcodeproj \
  -scheme Glance \
  -configuration Release \
  -derivedDataPath Build/DerivedData \
  CONFIGURATION_BUILD_DIR=Build/ \
  build

echo "=== 3. Ensuring Ad-Hoc Code Signing ==="
codesign --force --deep --sign - --entitlements Glance/Glance.entitlements Build/Glance.app

echo "=== 4. Launching Glance ==="
# Terminate any running instances first
killall Glance 2>/dev/null || true

open Build/Glance.app
echo "=== Build and Run Succeeded! ==="
