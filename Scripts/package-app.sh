#!/usr/bin/env bash
# Собирает LifeVPN.app. Аргумент: debug | release (по умолчанию release).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck source=Scripts/sdk-guard.sh
. "${ROOT}/Scripts/sdk-guard.sh"

CONFIG="${1:-release}"
VERSION="$(cat "${ROOT}/VERSION")"
PRODUCT="LifeVPN"
APP_NAME="LifeVPN"
APP_DIR="${ROOT}/${APP_NAME}.app"
BUNDLE_ID="com.stailegrow.lifevpn"

if [ ! -f "${ROOT}/Sources/LifeVPN/Resources/xray" ]; then
  echo "Бинарника xray нет — запускаю Scripts/fetch-xray.sh"
  "${ROOT}/Scripts/fetch-xray.sh"
fi

# ARCH_FLAGS="--arch arm64 --arch x86_64" собирает universal-бинарник —
# так делает сборка релиза на GitHub, чтобы приложение шло и на Intel.
echo "Собираю (${CONFIG})..."
# shellcheck disable=SC2086
swift build -c "${CONFIG}" ${ARCH_FLAGS:-}
# shellcheck disable=SC2086
BIN_PATH="$(swift build -c "${CONFIG}" ${ARCH_FLAGS:-} --show-bin-path)"

echo "Собираю бандл ${APP_NAME}.app (версия ${VERSION})..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}/${PRODUCT}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

RES_BUNDLE="${BIN_PATH}/${PRODUCT}_${PRODUCT}.bundle"
[ -d "${RES_BUNDLE}" ] && cp -R "${RES_BUNDLE}" "${APP_DIR}/Contents/Resources/"

# Иконки может не быть после свежего клона — собираем из мастер-картинки.
if [ ! -f "${ROOT}/Resources/AppIcon.icns" ] && [ -f "${ROOT}/Resources/AppIcon-master.png" ]; then
  echo "Собираю иконку..."
  "${ROOT}/Scripts/make-icon.sh"
fi

ICON_LINE=""
if [ -f "${ROOT}/Resources/AppIcon.icns" ]; then
  cp "${ROOT}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
  ICON_LINE="  <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Life VPN</string>
  <key>CFBundleDisplayName</key><string>Life VPN</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
${ICON_LINE}
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Камера нужна, чтобы считать QR-код с подпиской.</string>
  <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc подпись: без Apple-аккаунта, но локально приложение и вложенные
# бинарники запускаются.
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true
xattr -dr com.apple.quarantine "${APP_DIR}" 2>/dev/null || true

echo "Готово: ${APP_DIR}"
