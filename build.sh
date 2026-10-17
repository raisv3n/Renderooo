#!/bin/zsh
# Builds "Renderooo.app" with swiftc alone (no Xcode needed; Command Line Tools are enough).
#   ./build.sh              → build/Renderooo.app for this Mac's architecture
#   ./build.sh --universal  → arm64 + x86_64
#   ./build.sh --install    → also copy to /Applications and register with Launch Services
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Renderooo"
EXECUTABLE="Renderooo"
BUNDLE_ID="local.zquig.md"
VERSION="${RENDEROOO_VERSION:-1.0.0}"   # the release workflow sets this from the git tag
BUILD_NUMBER="${RENDEROOO_BUILD:-1}"
MIN_MACOS="13.0"

UNIVERSAL=0; INSTALL=0
for arg in "$@"; do
  case $arg in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(Renderooo/*.swift)
if (( UNIVERSAL )); then ARCHS=(arm64 x86_64); else ARCHS=($(uname -m)); fi

BINARIES=()
for arch in $ARCHS; do
  out="build/$EXECUTABLE-$arch"
  echo "Compiling $arch…"
  swiftc -O -wmo -swift-version 5 -parse-as-library \
    -module-name "$EXECUTABLE" \
    -target "$arch-apple-macos$MIN_MACOS" \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    $SOURCES -o "$out"
  BINARIES+=("$out")
done
lipo -create $BINARIES -output "$APP/Contents/MacOS/$EXECUTABLE"
rm -f $BINARIES

# Resources are flattened into Contents/Resources, same as the Xcode build.
cp Renderooo/Resources/style.css Renderooo/Resources/render.js Renderooo/Resources/mermaid-enhance.js Renderooo/Resources/vendor/* "$APP/Contents/Resources/"
# KaTeX keeps its folder: katex.min.css loads its fonts from katex/fonts/.
cp -R Renderooo/Resources/katex "$APP/Contents/Resources/"
# App icon: icon.png → whole artwork on a rounded-square tile (tools/MakeIcon.swift) → AppIcon.icns.
if [[ -f icon.png && ( ! -f Renderooo/Resources/AppIcon.icns || icon.png -nt Renderooo/Resources/AppIcon.icns || tools/MakeIcon.swift -nt Renderooo/Resources/AppIcon.icns ) ]]; then
  echo "Making app icon…"
  swiftc -O tools/MakeIcon.swift -o build/MakeIcon
  build/MakeIcon icon.png build/AppIcon-1024.png
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size build/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Renderooo/Resources/AppIcon.icns
  rm -rf "$ICONSET" build/MakeIcon build/AppIcon-1024.png
fi
cp Renderooo/Resources/AppIcon.icns "$APP/Contents/Resources/"

sed -e "s/\$(EXECUTABLE_NAME)/$EXECUTABLE/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/" \
    Renderooo/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - --options runtime "$APP"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if (( INSTALL )); then
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  "$LSREGISTER" -f "/Applications/$APP_NAME.app"
  echo "Installed /Applications/$APP_NAME.app"
else
  "$LSREGISTER" -f "$APP"
  echo "Built $APP"
fi
