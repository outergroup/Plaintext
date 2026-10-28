#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/plaintext-native-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/modules" -parse-as-library \
    "$ROOT/Frontend/PlaintextDocument.swift" "$ROOT/Tests/NativeDocumentTests.swift" -o "$TEST_DIR/documents"
"$TEST_DIR/documents"
cc -std=gnu17 -Wall -Wextra -O2 "$ROOT/Tests/EnvironmentDriver.c" "$ROOT/Backend/Environment.c" \
    -lpthread -lm -o "$TEST_DIR/driver"
swiftc -module-cache-path "$TEST_DIR/modules" -parse-as-library \
    "$ROOT/Frontend/PlaintextDocument.swift" "$ROOT/Tests/NativeCodecTests.swift" -o "$TEST_DIR/codec"
"$TEST_DIR/codec" "$TEST_DIR/driver"
