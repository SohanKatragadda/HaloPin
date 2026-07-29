#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_PATH=${OUTPUT_PATH:-"${PROJECT_DIR}/outputs/HaloPin-Source.zip"}

cd "${PROJECT_DIR}"
/bin/rm -f "${OUTPUT_PATH}"
/usr/bin/zip -q -r "${OUTPUT_PATH}" \
    Package.swift \
    Sources \
    Tests \
    Configuration \
    Scripts \
    README.md \
    PRIVACY.md \
    PERMISSIONS.md \
    TROUBLESHOOTING.md \
    KNOWN_LIMITATIONS.md

echo "${OUTPUT_PATH}"
