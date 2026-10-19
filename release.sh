#!/bin/sh
# Builds the release disk image into dist/: MacTTY.app (with MacTTYgen,
# Pageant and PuTTY's command-line tools inside it) as a universal binary
# for Apple silicon and Intel Macs running macOS 14 or later, ad-hoc
# signed.
#   ./release.sh
#
# Each architecture is built on its own (build-arm64.noindex/,
# build-x86_64.noindex/) and the two are joined with lipo, in
# build-universal.noindex/: a single two-architecture build would make
# PuTTY's configure tests for the AES-NI/SHA-NI and NEON crypto code fail
# on one side and leave that code out of both. Build folders end in
# .noindex so that Spotlight skips them and the applications built there
# do not join the ones on the Mac; dist/ only gets the disk image.
set -e
cd "$(dirname "$0")"

version=$(cat VERSION)
minos=14.0
dist=dist
universal=build-universal.noindex
app=$universal/MacTTY.app
dmg=$dist/MacTTY-$version.dmg

for arch in arm64 x86_64; do
  cmake -S putty -B build-$arch.noindex -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES=$arch \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=$minos \
      -DCMAKE_PROJECT_INCLUDE="$PWD/macos/cmake/inject.cmake"
  ninja -C build-$arch.noindex MacTTY
done

rm -rf $dist $universal
mkdir -p $dist $universal
ditto build-arm64.noindex/MacTTY.app $app

# Join every Mach-O file in the bundle with its x86_64 twin.
machos=$(find $app -type f -perm -u+x | while read -r f; do
  file -b "$f" | grep -q Mach-O && echo "$f"
done)
for f in $machos; do
  lipo -create "$f" "build-x86_64.noindex/MacTTY.app/${f#$app/}" -output "$f"
done

# lipo leaves the linker's signatures behind, so sign again, inside out:
# the command-line tools, the companion applications, then MacTTY.app.
# Ad-hoc ("-"): there is no Developer ID, so Gatekeeper asks once on
# first launch (see README).
for f in $app/Contents/Resources/bin/*; do
  codesign --force --sign - --timestamp=none \
      --identifier org.mactty.$(basename "$f") "$f"
done
for a in $app/Contents/Applications/*.app $app; do
  codesign --force --sign - --timestamp=none "$a"
done

# Check what is shipped: both architectures, macOS 14 as the minimum,
# the icons, valid signatures.
for f in $machos; do
  archs=$(lipo -archs "$f")
  [ "$archs" = "x86_64 arm64" ] || [ "$archs" = "arm64 x86_64" ] ||
    { echo "$f: architectures are '$archs'" >&2; exit 1; }
  for arch in arm64 x86_64; do
    v=$(vtool -arch $arch -show-build "$f" | awk '$1 == "minos" { print $2 }')
    [ "$v" = "$minos" ] ||
      { echo "$f ($arch): minimum macOS is $v, not $minos" >&2; exit 1; }
  done
done
for p in $app $app/Contents/Applications/*.app; do
  v=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" \
        "$p/Contents/Info.plist")
  [ "$v" = "$minos" ] ||
    { echo "$p: LSMinimumSystemVersion is $v, not $minos" >&2; exit 1; }
  [ -f "$p/Contents/Resources/Assets.car" ] ||
    { echo "$p: no icon (Assets.car missing; actool from Xcode 26 needed)" >&2; exit 1; }
done
codesign --verify --deep --strict $app

# The disk image: the application, a link to /Applications to drag it
# onto, and MacTTY's icon on the volume.
stage=$universal/stage
mkdir $stage
ditto $app $stage/MacTTY.app
ln -s /Applications $stage/Applications
cp $app/Contents/Resources/MacTTY.icns $stage/.VolumeIcon.icns
SetFile -a C $stage
hdiutil create -volname "MacTTY $version" -srcfolder $stage \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov $dmg
rm -rf $stage
hdiutil verify $dmg
(cd $dist && shasum -a 256 "$(basename $dmg)" > "$(basename $dmg).sha256")

echo
echo "Built: $dmg"
cat $dmg.sha256
