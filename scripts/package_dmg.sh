#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LoongMD"
BUILD_DIR="${ROOT_DIR}/.build/release"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
RES_DIR="${ROOT_DIR}/Sources/LoongMD/Resources"
STAGING_DIR="${TMPDIR:-/tmp}/${APP_NAME}-dmg-staging"

cleanup() {
  rm -rf "${STAGING_DIR}"
}

trap cleanup EXIT

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd swift
require_cmd hdiutil

echo "[1/4] Building release binary..."
swift build -c release

echo "[2/4] Preparing app bundle in ${APP_BUNDLE} ..."
mkdir -p "${DIST_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp -f "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>LoongMD</string>
  <key>CFBundleExecutable</key>
  <string>LoongMD</string>
  <key>CFBundleIdentifier</key>
  <string>com.loongmd.loongmd</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>LoongMD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleIconFile</key>
  <string>LoongMD.icns</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

cp -f "${RES_DIR}/app_icon.png" "${APP_BUNDLE}/Contents/Resources/app_icon.png"
cp -f "${RES_DIR}/md_file_icon.png" "${APP_BUNDLE}/Contents/Resources/md_file_icon.png"
cp -f "${RES_DIR}/LoongMD.icns" "${APP_BUNDLE}/Contents/Resources/LoongMD.icns" 2>/dev/null || true

if [ -f "${APP_BUNDLE}/Contents/Resources/LoongMD.icns" ]; then
  echo "[2/4] Using app icon: LoongMD.icns"
elif [ -f "${APP_BUNDLE}/Contents/Resources/app_icon.png" ]; then
  echo "[2/4] Using app icon: app_icon.png"
fi

plutil -lint "${APP_BUNDLE}/Contents/Info.plist"

echo "[3/4] Creating install-style DMG ..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO -fs HFS+ "${DMG_PATH}"

echo "[4/4] Done: ${DMG_PATH}"

echo "Mountable installer-style DMG created with LoongMD.app + Applications shortcut."
