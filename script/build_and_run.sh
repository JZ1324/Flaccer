#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Flaccer"
PROJECT="Flaccer.xcodeproj"
SCHEME="Flaccer"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA=".DerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  pkill -x "${APP_NAME}" || true
fi

xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  build

case "${1:-run}" in
  run)
    /usr/bin/open -n "${APP_PATH}"
    ;;
  --verify)
    /usr/bin/open -n "${APP_PATH}"
    sleep 2
    pgrep -x "${APP_NAME}" >/dev/null
    echo "${APP_NAME} is running"
    ;;
  --logs)
    /usr/bin/open -n "${APP_PATH}"
    /usr/bin/log stream --style compact --predicate "process == '${APP_NAME}'"
    ;;
  --build-only)
    echo "Built ${APP_PATH}"
    ;;
  *)
    echo "Usage: $0 [run|--verify|--logs|--build-only]"
    exit 64
    ;;
esac
