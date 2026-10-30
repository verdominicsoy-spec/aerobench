#!/bin/bash
# Builds AeroBench.app with the engine's source inside it and packs it into
# build/AeroBench.dmg. On first launch the app copies the engine to
# ~/Library/Application Support/AeroBench and runs uv sync there (the
# Python environment is several hundred MB of compiled packages, so it is
# made on the Mac rather than shipped).
#
#   app/scripts/make_dmg.sh                   ad-hoc signed: opens on this Mac;
#                                             elsewhere, right-click > Open the first time
#   SIGN_IDENTITY="Developer ID Application: ..." app/scripts/make_dmg.sh
#                                             signed with your certificate (notarise separately)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BUILD=build/dmg
APP="$BUILD/DerivedData/Build/Products/Release/AeroBench.app"
rm -rf "$BUILD/stage" build/AeroBench.dmg
mkdir -p "$BUILD"

echo "Building the app"
xcodebuild -project app/AeroBench.xcodeproj -scheme AeroBench -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" -destination 'generic/platform=macOS' build >"$BUILD/build.log" 2>&1 \
  || { grep -m 10 'error:' "$BUILD/build.log" || tail -20 "$BUILD/build.log"; exit 1; }

echo "Putting the engine inside it"
BUNDLED="$APP/Contents/Resources/AeroBench"
rm -rf "$BUNDLED"
mkdir -p "$BUNDLED/data"
rsync -a --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude '*.egg-info' engine "$BUNDLED/"
rsync -a --exclude 'airfoils/*' data/ "$BUNDLED/data/"
mkdir -p "$BUNDLED/data/airfoils"
git rev-parse --short HEAD > "$BUNDLED/VERSION" 2>/dev/null || date +%Y%m%d%H%M > "$BUNDLED/VERSION"

echo "Signing"
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep "$APP"

echo "Making the disk image"
mkdir -p "$BUILD/stage"
cp -R "$APP" "$BUILD/stage/"
ln -s /Applications "$BUILD/stage/Applications"
hdiutil create -volname AeroBench -srcfolder "$BUILD/stage" -ov -format UDZO build/AeroBench.dmg >/dev/null
rm -rf "$BUILD/stage"
echo "build/AeroBench.dmg ($(du -h build/AeroBench.dmg | cut -f1))"
