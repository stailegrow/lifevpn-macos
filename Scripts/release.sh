#!/usr/bin/env bash
# Собирает архив с приложением и, если попросить, выкладывает релиз на GitHub.
#
#   Scripts/release.sh            — только собрать dist/LifeVPN-<версия>.zip
#   Scripts/release.sh --publish  — собрать и создать релиз через gh
#
# Описание релиза берётся из Scripts/release-notes.md — оно в репозитории,
# а не в build/, иначе очистка сборки уносила бы его с собой.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

VERSION="$(cat "${ROOT}/VERSION")"
TAG="v${VERSION}"
DIST="${ROOT}/dist"
ZIP="${DIST}/LifeVPN-${VERSION}.zip"

"${ROOT}/Scripts/package-app.sh" release

mkdir -p "${DIST}"
rm -f "${ZIP}"

# ditto, а не zip: сохраняет ресурсные вилки и права, иначе ad-hoc подпись
# на другой машине окажется битой и приложение не откроется вовсе.
ditto -c -k --sequesterRsrc --keepParent "${ROOT}/LifeVPN.app" "${ZIP}"

echo "Архив: ${ZIP} ($(du -h "${ZIP}" | cut -f1))"

if [ "${1:-}" = "--publish" ]; then
  NOTES="${ROOT}/Scripts/release-notes.md"
  [ -f "${NOTES}" ] || { echo "Нет файла с описанием релиза: ${NOTES}" >&2; exit 1; }
  gh release create "${TAG}" "${ZIP}" \
     --title "Life VPN ${VERSION}" \
     --notes-file "${NOTES}"
  echo "Релиз ${TAG} опубликован."
fi
