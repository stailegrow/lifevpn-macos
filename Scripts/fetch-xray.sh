#!/usr/bin/env bash
# Кладёт бинарник Xray-core в Sources/LifeVPN/Resources/.
#
# По умолчанию собирает universal-бинарник (arm64 + x86_64) через lipo, чтобы
# готовый .app можно было просто скопировать на любой мак. Передай "native",
# чтобы взять только архитектуру текущей машины.
set -euo pipefail

REPO="XTLS/Xray-core"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${ROOT}/Sources/LifeVPN/Resources"
MODE="${1:-universal}"
mkdir -p "$DEST_DIR"

# Версия ядра закреплена в файле XRAY_VERSION: «последний релиз» у Xray —
# это последний стабильный, а свежие версии разработчики выпускают как
# предварительные. Обновить ядро = поменять одну строку в этом файле.
if [ -f "${ROOT}/XRAY_VERSION" ]; then
  TAG="$(tr -d '[:space:]' < "${ROOT}/XRAY_VERSION")"
  echo "Версия ядра из XRAY_VERSION: ${TAG}" >&2
else
  echo "Определяю последний релиз Xray-core..." >&2
  TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/${REPO}/releases/latest" | sed -E 's#.*/tag/##')"
fi
[ -n "${TAG}" ] || { echo "Не удалось определить тег релиза." >&2; exit 1; }
echo "Релиз: ${TAG}" >&2

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Печатает путь к распакованному бинарнику в stdout; прогресс — строго в stderr,
# иначе он попадёт в подстановку команды вместе с путём.
fetch_arch() {
  local asset="$1" out="$2"
  echo "Скачиваю ${asset}..." >&2
  curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${asset}" -o "$TMP/${asset}" >&2
  unzip -o -q "$TMP/${asset}" -d "$TMP/${out}" >&2
  printf '%s' "$TMP/${out}/xray"
}

case "$MODE" in
  universal)
    ARM="$(fetch_arch "Xray-macos-arm64-v8a.zip" arm)"
    X64="$(fetch_arch "Xray-macos-64.zip" intel)"
    echo "Склеиваю universal-бинарник..." >&2
    lipo -create "$ARM" "$X64" -output "$DEST_DIR/xray"
    ;;
  native)
    case "$(uname -m)" in
      arm64)  BIN="$(fetch_arch "Xray-macos-arm64-v8a.zip" arm)" ;;
      x86_64) BIN="$(fetch_arch "Xray-macos-64.zip" intel)" ;;
      *) echo "Неизвестная архитектура: $(uname -m)" >&2; exit 1 ;;
    esac
    cp "$BIN" "$DEST_DIR/xray"
    ;;
  *)
    echo "Использование: $0 [universal|native]" >&2; exit 1 ;;
esac

chmod +x "$DEST_DIR/xray"
xattr -dr com.apple.quarantine "$DEST_DIR/xray" 2>/dev/null || true

echo "Готово: $DEST_DIR/xray"
lipo -archs "$DEST_DIR/xray"
"$DEST_DIR/xray" version | head -1
