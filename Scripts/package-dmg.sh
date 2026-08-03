#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR=${OUTPUT_DIR:-"${PROJECT_DIR}/outputs"}
APP_PATH=${APP_PATH:-"${OUTPUT_DIR}/HaloPin.app"}
DMG_PATH=${DMG_PATH:-"${OUTPUT_DIR}/HaloPin.dmg"}
VOLUME_NAME=${VOLUME_NAME:-HaloPin}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
DOCUMENTATION_NAME="Installation Guide and Docs"
BACKGROUND_PATH="${PROJECT_DIR}/Configuration/DMGBackground.png"
DOCUMENTATION_ICON_PATH="${PROJECT_DIR}/Configuration/DocsFolderIcon.icns"
WORK_DIR=$(/usr/bin/mktemp -d "${TMPDIR%/}/halopin-dmg.XXXXXX")
STAGING_DIR="${WORK_DIR}/staging"
DOCUMENTATION_DIR="${STAGING_DIR}/${DOCUMENTATION_NAME}"
DOCUMENTATION_ICON_WORK="${WORK_DIR}/DocsFolderIcon.icns"
DOCUMENTATION_ICON_RESOURCE="${WORK_DIR}/DocsFolderIcon.rsrc"
MOUNT_DIR="${WORK_DIR}/mount"
READ_WRITE_DMG="${WORK_DIR}/HaloPin-read-write.dmg"
MOUNTED=false

cleanup() {
    if [[ "${MOUNTED}" == true ]]; then
        /usr/bin/hdiutil detach "${MOUNT_DIR}" -force >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Missing ${APP_PATH}; run Scripts/build-app.sh first."
    exit 2
fi

/bin/mkdir -p "${STAGING_DIR}"
/usr/bin/ditto "${APP_PATH}" "${STAGING_DIR}/HaloPin.app"
/bin/ln -s /Applications "${STAGING_DIR}/Applications"
/bin/mkdir -p "${STAGING_DIR}/.background"
/usr/bin/ditto \
    "${BACKGROUND_PATH}" \
    "${STAGING_DIR}/.background/DMGBackground.png"
/bin/mkdir -p "${DOCUMENTATION_DIR}"
for document in \
    INSTALLATION_GUIDE.md \
    TECHNICAL_REPORT.md \
    README.md \
    PERFORMANCE.md \
    PRIVACY.md \
    PERMISSIONS.md \
    TROUBLESHOOTING.md \
    KNOWN_LIMITATIONS.md; do
    /usr/bin/ditto \
        "${PROJECT_DIR}/${document}" \
        "${DOCUMENTATION_DIR}/${document}"
done
/usr/bin/ditto "${DOCUMENTATION_ICON_PATH}" "${DOCUMENTATION_ICON_WORK}"
/usr/bin/sips -i "${DOCUMENTATION_ICON_WORK}" >/dev/null
/usr/bin/DeRez -only icns \
    "${DOCUMENTATION_ICON_WORK}" \
    > "${DOCUMENTATION_ICON_RESOURCE}"
/usr/bin/Rez -append \
    "${DOCUMENTATION_ICON_RESOURCE}" \
    -o "${DOCUMENTATION_DIR}/Icon"$'\r'
/usr/bin/SetFile -a C "${DOCUMENTATION_DIR}"

/usr/bin/hdiutil create \
    -size 64m \
    -fs "Journaled HFS+" \
    -volname "${VOLUME_NAME}" \
    -type UDIF \
    "${READ_WRITE_DMG}"

/bin/mkdir -p "${MOUNT_DIR}"
/usr/bin/hdiutil attach \
    "${READ_WRITE_DMG}" \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "${MOUNT_DIR}"
MOUNTED=true

/usr/bin/ditto "${STAGING_DIR}/" "${MOUNT_DIR}/"

if ! DMG_MOUNT_DIR="${MOUNT_DIR}" \
    /usr/bin/osascript <<'APPLESCRIPT'
set mountPath to system attribute "DMG_MOUNT_DIR"
set mountedFolder to POSIX file mountPath as alias
set backgroundFile to POSIX file (mountPath & "/.background/DMGBackground.png") as alias
tell application "Finder"
    set mountedDisk to disk of mountedFolder
    tell mountedDisk
        open
        delay 2
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {180, 120, 880, 570}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 13
        set background picture of theViewOptions to backgroundFile
        update without registering applications
        delay 5
        close
        delay 1

        -- Finder may not expose a newly copied folder as a positionable window
        -- item on the first pass. The required background and install layout
        -- are already saved above, so a failure here must not discard them.
        open
        delay 2
        try
            set position of item "HaloPin.app" of container window to {175, 218}
            set position of item "Applications" of container window to {525, 218}
            set position of item "Installation Guide and Docs" of container window to {350, 290}
        end try
        update without registering applications
        delay 5
        close
    end tell
end tell
APPLESCRIPT
then
    echo "warning: Finder layout automation failed; using the standard icon view."
fi

/bin/sync
/usr/bin/hdiutil detach "${MOUNT_DIR}"
MOUNTED=false

/bin/rm -f "${DMG_PATH}"
/usr/bin/hdiutil convert \
    "${READ_WRITE_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_PATH}"

if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
    /usr/bin/codesign --verify --verbose=2 "${DMG_PATH}"
fi

echo "${DMG_PATH}"
