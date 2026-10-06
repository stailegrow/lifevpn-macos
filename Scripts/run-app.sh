#!/usr/bin/env bash
# Собирает и сразу запускает LifeVPN.app. Аргумент: debug | release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"${ROOT}/Scripts/package-app.sh" "${1:-debug}"
open "${ROOT}/LifeVPN.app"
