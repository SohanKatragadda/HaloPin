#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR=${OUTPUT_DIR:-"${PROJECT_DIR}/outputs"}
APP_PATH=${APP_PATH:-"${OUTPUT_DIR}/HaloPin.app"}
DMG_PATH=${DMG_PATH:-"${OUTPUT_DIR}/HaloPin.dmg"}
VOLUME_NAME=${VOLUME_NAME:-HaloPin}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
STAGING_DIR=$(/usr/bin/mktemp -d "${TMPDIR%/}/halopin-dmg.XXXXXX")

cleanup() {
    /bin/rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Missing ${APP_PATH}; run Scripts/build-app.sh first."
    exit 2
fi

/usr/bin/ditto "${APP_PATH}" "${STAGING_DIR}/HaloPin.app"
/bin/ln -s /Applications "${STAGING_DIR}/Applications"
/bin/mkdir -p "${STAGING_DIR}/Documentation"
for document in \
    README.md \
    PERFORMANCE.md \
    PRIVACY.md \
    PERMISSIONS.md \
    TROUBLESHOOTING.md \
    KNOWN_LIMITATIONS.md; do
    /usr/bin/ditto \
        "${PROJECT_DIR}/${document}" \
        "${STAGING_DIR}/Documentation/${document}"
done
/bin/rm -f "${DMG_PATH}"
/usr/bin/hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
    /usr/bin/codesign --verify --verbose=2 "${DMG_PATH}"
fi

echo "${DMG_PATH}"
