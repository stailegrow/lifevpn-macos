#!/usr/bin/env bash
# Собирает AppIcon.icns из мастер-картинки Resources/AppIcon-master.png.
#
# Мастер — квадрат 1024×1024 с уже скруглёнными углами: macOS форму не
# накладывает сама, её нужно принести в картинке.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

MASTER="${ROOT}/Resources/AppIcon-master.png"
SET_DIR="${ROOT}/build/LifeVPN.iconset"

if [ ! -f "${MASTER}" ]; then
  echo "Нет мастер-картинки: ${MASTER}" >&2
  exit 1
fi

rm -rf "${SET_DIR}"
mkdir -p "${SET_DIR}" "${ROOT}/Resources"

# Пары «размер в точках / имя файла»: macOS ждёт ровно этот набор.
for pair in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- ${pair}
  sips -s format png -z "$1" "$1" "${MASTER}" --out "${SET_DIR}/$2.png" >/dev/null
done

iconutil -c icns "${SET_DIR}" -o "${ROOT}/Resources/AppIcon.icns"
rm -rf "${SET_DIR}"

echo "Готово: ${ROOT}/Resources/AppIcon.icns"
