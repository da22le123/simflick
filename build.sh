#!/bin/sh
# Builds the injectable library for arm64 iOS simulators into build/simflick.dylib.
set -e
cd "$(dirname "$0")"
mkdir -p build
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
clang -arch arm64 -isysroot "$SDK" -mios-simulator-version-min=16.0 -dynamiclib -fobjc-arc \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  -o build/simflick.dylib inject/*.m
echo "built build/simflick.dylib"
