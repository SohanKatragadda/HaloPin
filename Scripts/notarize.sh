#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_PATH=${APP_PATH:-"${PROJECT_DIR}/outputs/HaloPin.app"}
DMG_PATH=${DMG_PATH:-"${PROJECT_DIR}/outputs/HaloPin.dmg"}
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

if [[ -z ${NOTARY_PROFILE:-} ]]; then
    echo "Set NOTARY_PROFILE to a keychain profile created with notarytool store-credentials."
    exit 2
fi

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "Missing ${DMG_PATH}; run Scripts/package-dmg.sh first."
    exit 2
fi

/usr/bin/xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
/usr/bin/xcrun stapler staple "${APP_PATH}"
/usr/bin/xcrun stapler staple "${DMG_PATH}"
/usr/bin/xcrun stapler validate "${APP_PATH}"
/usr/bin/xcrun stapler validate "${DMG_PATH}"
