#!/usr/bin/env bash
# Собирает релизную версию и кладёт её в «Программы».
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

[ -f "${ROOT}/Resources/AppIcon.icns" ] || "${ROOT}/Scripts/make-icon.sh"

"${ROOT}/Scripts/package-app.sh" release

TARGET="/Applications"
if [ ! -w "${TARGET}" ]; then
  # Нет прав на общую папку — ставим в личную, она есть у любого пользователя.
  TARGET="${HOME}/Applications"
  mkdir -p "${TARGET}"
  echo "Нет прав на /Applications — ставлю в ${TARGET}"
fi

# Работающую копию надо закрыть, иначе замена оставит половину бандла.
pkill -x LifeVPN 2>/dev/null || true
sleep 1

rm -rf "${TARGET}/LifeVPN.app"
cp -R "${ROOT}/LifeVPN.app" "${TARGET}/LifeVPN.app"
xattr -dr com.apple.quarantine "${TARGET}/LifeVPN.app" 2>/dev/null || true

echo "Установлено: ${TARGET}/LifeVPN.app"
open "${TARGET}/LifeVPN.app"
