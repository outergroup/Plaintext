#!/bin/bash

set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build/frontend}"
PACKAGE_ROOT="${PACKAGE_ROOT:-${REPO_ROOT}/build/linux-package}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/build/release}"
CONFIGURATION="${CONFIGURATION:-Release}"

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "error: missing $1" >&2
        exit 1
    fi
}

require_file "${PACKAGE_ROOT}/RemoteLinuxBinaries/aarch64/PlaintextBackend"
require_file "${PACKAGE_ROOT}/RemoteLinuxBinaries/x86_64/PlaintextBackend"

mkdir -p "${OUTPUT_ROOT}" "${PACKAGE_ROOT}/bundles"

echo "==> Building Plaintext frontend"
/usr/bin/xcodebuild \
    -project "${REPO_ROOT}/Plaintext.xcodeproj" \
    -scheme Plaintext \
    -configuration "${CONFIGURATION}" \
    SYMROOT="${BUILD_ROOT}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

echo "==> Archiving PlaintextContent bundles"
"${REPO_ROOT}/Scripts/archive_plaintext_bundle.sh" \
    "${BUILD_ROOT}/${CONFIGURATION}/Plaintext.bundle" \
    "${PACKAGE_ROOT}/bundles" \
    PlaintextContent.bundle

STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGING_ROOT}"' EXIT

OUTPUT_APP_ROOT="${OUTPUT_ROOT}/Plaintext"
rm -rf "${OUTPUT_APP_ROOT}"
mkdir -p "${OUTPUT_APP_ROOT}"

package_linux_variant() {
    local arch="$1"
    local output_name="$2"
    local app_root="${STAGING_ROOT}/Plaintext"
    rm -rf "${app_root}"
    mkdir -p \
        "${app_root}/RemoteLinuxBinaries/${arch}" \
        "${app_root}/bundles"
    install -m 0755 "${PACKAGE_ROOT}/RemoteLinuxBinaries/${arch}/PlaintextBackend" "${app_root}/RemoteLinuxBinaries/${arch}/PlaintextBackend"
    install -m 0644 "${PACKAGE_ROOT}/bundles/PlaintextContent.bundle.macos-arm.aar" "${app_root}/bundles/PlaintextContent.bundle.macos-arm.aar"
    install -m 0644 "${PACKAGE_ROOT}/bundles/PlaintextContent.bundle.macos-x86.aar" "${app_root}/bundles/PlaintextContent.bundle.macos-x86.aar"
    tar --format ustar --no-xattrs -C "${STAGING_ROOT}" -czf "${OUTPUT_APP_ROOT}/${output_name}.tar.gz" Plaintext
    echo "Packaged ${OUTPUT_APP_ROOT}/${output_name}.tar.gz"
}

package_linux_variant aarch64 linux-aarch64
package_linux_variant x86_64 linux-x86_64
