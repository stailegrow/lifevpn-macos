# Выбор SDK. Подключается через source из остальных скриптов.
#
# Command Line Tools 6.4 приехали с SDK macOS 27, где @State и соседи в SwiftUI
# стали макросами, — а плагина libSwiftUIMacros.dylib в наборе нет. В итоге не
# собирается ни один файл со @State, и ошибка показывает на наш код, хотя дело
# не в нём: разворачивать макрос просто нечем.
#
# Прежний SDK лежит рядом и полностью рабочий, поэтому пока плагин не приедет,
# собираемся на нём. Как только он появится (или встанет Xcode, который его
# приносит), условие перестанет срабатывать само — никаких правок не понадобится.

sdk_guard() {
  [ -n "${SDKROOT:-}" ] && return 0

  local developer plugins fallback
  developer="$(xcode-select -p 2>/dev/null)" || return 0
  plugins="${developer}/usr/lib/swift/host/plugins"

  [ -f "${plugins}/libSwiftUIMacros.dylib" ] && return 0
  # В полном Xcode плагин лежит внутри тулчейна, а не в Developer/usr.
  [ -f "${developer}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] && return 0

  # «|| true»: скрипт подключают под set -e, и пустой ls иначе оборвал бы сборку.
  fallback="$(ls -d "${developer}"/SDKs/MacOSX26*.sdk 2>/dev/null | tail -1 || true)"
  if [ -z "${fallback}" ]; then
    echo "В наборе инструментов нет плагина макросов SwiftUI, и прежнего SDK тоже нет." >&2
    echo "Поставь Xcode либо верни прежнюю версию Command Line Tools." >&2
    return 0
  fi

  export SDKROOT="${fallback}"
  echo "Плагина макросов SwiftUI в наборе нет — собираю на ${SDKROOT##*/}"
}

sdk_guard
