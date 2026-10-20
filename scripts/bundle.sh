#!/bin/bash
# Builds "MLX Player.app" into ./dist. Usage: scripts/bundle.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="dist/MLX Player.app"

swift build -c release --product MLXPlayer
swift build -c release --product mlxplayer-mcp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MLXPlayer" "$APP/Contents/MacOS/MLXPlayer"
cp "$BIN/mlxplayer-mcp" "$APP/Contents/MacOS/mlxplayer-mcp"

# App icon, rendered from Brand.appIconImage.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN/MLXPlayer" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MLX Player</string>
  <key>CFBundleDisplayName</key><string>MLX Player</string>
  <key>CFBundleIdentifier</key><string>com.kalahroudi.mlxplayer</string>
  <key>CFBundleExecutable</key><string>MLXPlayer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc sign, sandbox OFF (the app spawns processes). Replace "-" with a Developer ID for distribution.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP/Contents/MacOS/mlxplayer-mcp"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
