#!/bin/sh
# Gera build/dist/Robusta-<versão>.dmg: o app e um atalho para Aplicativos, para arrastar.
# Uso, na raiz do repositório: sh Tools/make-dmg.sh
# Só ferramentas do macOS (xcodebuild, diskutil); assinatura ad hoc, sem notarização.
set -eu

VERSION=$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' project.yml)
DERIVED=build/dd
APP="$DERIVED/Build/Products/Release/Robusta.app"
DIST=build/dist
STAGE="$DIST/stage"
DMG="$DIST/Robusta-$VERSION.dmg"

echo "Robusta $VERSION"
xcodegen generate -q
xcodebuild -project Robusta.xcodeproj -scheme Robusta -configuration Release -derivedDataPath "$DERIVED" build -quiet

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Robusta.app"
ln -s /Applications "$STAGE/Applications"

# diskutil image: a forma atual (o "hdiutil create" está obsoleto no macOS 27). ULFO = compactado (lzfse).
diskutil image create from --format ULFO --volumeName "Robusta $VERSION" "$STAGE" "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null
echo "Gerado: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
