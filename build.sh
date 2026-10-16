#!/bin/sh
# Builds MacTTY.app (and PuTTY's command-line tools) into build/.
#   ./build.sh            release build
#   ./build.sh debug      debug build with assertions
set -e
cd "$(dirname "$0")"

type=Release
[ "$1" = debug ] && type=Debug

cmake -S putty -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=$type \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_PROJECT_INCLUDE="$PWD/macos/inject.cmake"
ninja -C build MacTTY

echo
echo "Built: build/MacTTY.app"
