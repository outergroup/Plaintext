#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/plaintext-elastic.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -framework AppKit -module-cache-path "$TEST_DIR/modules" \
    "$ROOT/Frontend/ElasticScrollState.swift" "$ROOT/Tests/ElasticScrollTests.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"

swiftc -swift-version 6 -framework AppKit -framework QuartzCore -module-cache-path "$TEST_DIR/modules" \
    "$ROOT/Frontend/ElasticScrollState.swift" "$ROOT/Frontend/ElasticScrollController.swift" \
    "$ROOT/Tests/ElasticScrollControllerTests.swift" -o "$TEST_DIR/controller-test"
"$TEST_DIR/controller-test"
