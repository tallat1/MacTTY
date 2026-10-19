#!/bin/sh
# Builds MacTTY.app (and PuTTY's command-line tools) into build.noindex/.
#   ./build.sh            release build
#   ./build.sh debug      debug build with assertions
#   ./build.sh test       release build with test hooks, into
#                         build-test.noindex/ (the terminal takes clicks
#                         while in the background, so tests can post mouse
#                         events without taking focus)
#
# Build folders end in .noindex: Spotlight skips them, so the copies of
# MacTTY built there do not join the applications on the Mac.
set -e
cd "$(dirname "$0")"

type=Release
dir=build.noindex
flags=
case "$1" in
  debug) type=Debug ;;
  test) dir=build-test.noindex; flags=-DMACTTY_TEST_HOOKS ;;
esac

cmake -S putty -B $dir -G Ninja \
    -DCMAKE_BUILD_TYPE=$type \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OBJC_FLAGS="$flags" \
    -DCMAKE_PROJECT_INCLUDE="$PWD/macos/cmake/inject.cmake"
ninja -C $dir MacTTY

echo
echo "Built: $dir/MacTTY.app"
