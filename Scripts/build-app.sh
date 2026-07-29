#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR=${OUTPUT_DIR:-"${PROJECT_DIR}/outputs"}
APP_PATH="${OUTPUT_DIR}/HaloPin.app"
CONFIGURATION=${CONFIGURATION:-release}
SIGN_IDENTITY=${SIGN_IDENTITY:-}
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
BUILD_CACHE=${BUILD_CACHE:-"${PROJECT_DIR}/.build"}

export DEVELOPER_DIR
export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_CACHE}/ModuleCache"
export CLANG_MODULE_CACHE_PATH="${BUILD_CACHE}/ModuleCache"
export XDG_CACHE_HOME="${BUILD_CACHE}/cache"

if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY=$(
        /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
            | /usr/bin/awk -F '"' \
                '/"Apple Development:|Developer ID Application:/{print $2; exit}'
    )
fi
if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY=-
    echo "warning: no code-signing certificate found; using an ad-hoc signature."
    echo "warning: macOS privacy grants persist across restarts of this exact build,"
    echo "warning: but must be granted again after the executable is rebuilt."
fi

cd "${PROJECT_DIR}"
xcrun swift build \
    --disable-sandbox \
    --scratch-path "${BUILD_CACHE}" \
    -c "${CONFIGURATION}" \
    --arch arm64 \
    --arch x86_64 \
    --product HaloPin
BIN_DIR=$(xcrun swift build \
    --disable-sandbox \
    --scratch-path "${BUILD_CACHE}" \
    -c "${CONFIGURATION}" \
    --arch arm64 \
    --arch x86_64 \
    --show-bin-path)

/bin/rm -rf "${APP_PATH}"
/bin/mkdir -p "${APP_PATH}/Contents/MacOS"
/bin/mkdir -p "${APP_PATH}/Contents/Resources"
/bin/cp "${BIN_DIR}/HaloPin" "${APP_PATH}/Contents/MacOS/HaloPin"
/bin/cp "${PROJECT_DIR}/Configuration/Info.plist" "${APP_PATH}/Contents/Info.plist"
/bin/cp "${PROJECT_DIR}/Configuration/HaloPin.icns" \
    "${APP_PATH}/Contents/Resources/HaloPin.icns"
/bin/chmod 755 "${APP_PATH}/Contents/MacOS/HaloPin"

if [[ -n ${PRODUCT_BUNDLE_IDENTIFIER:-} ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleIdentifier ${PRODUCT_BUNDLE_IDENTIFIER}" \
        "${APP_PATH}/Contents/Info.plist"
fi

/usr/bin/codesign \
    --force \
    --options runtime \
    --entitlements "${PROJECT_DIR}/Configuration/HaloPin.entitlements" \
    --sign "${SIGN_IDENTITY}" \
    "${APP_PATH}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
/usr/bin/plutil -lint "${APP_PATH}/Contents/Info.plist"
echo "${APP_PATH}"
