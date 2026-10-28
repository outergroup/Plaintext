#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-7355}"
BUILD_ROOT="$PWD/build/macos"
RUN_ROOT="$PWD/build/run"

xcodebuild -project Plaintext.xcodeproj -scheme Plaintext -configuration Release SYMROOT="$BUILD_ROOT" ONLY_ACTIVE_ARCH=NO build
xcodebuild -project Plaintext.xcodeproj -scheme PlaintextBackend -configuration Release SYMROOT="$BUILD_ROOT" build

rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT/bundles"
Scripts/archive_plaintext_bundle.sh "$BUILD_ROOT/Release/Plaintext.bundle" "$RUN_ROOT/bundles"

mkdir -p "${RUN_ROOT}/web"
python3 Scripts/stage_web.py "$PWD/Resources/PlaintextWeb" "${RUN_ROOT}/web"

"$BUILD_ROOT/Release/PlaintextBackend" --port "$PORT" --bundles-dir "$RUN_ROOT/bundles"
