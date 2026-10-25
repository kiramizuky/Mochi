#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-perception-v2.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc NotchBuddy/Sources/App/VectorMemoryStore.swift \
    NotchBuddy/Sources/App/FileSystemWatcher.swift \
    -framework NaturalLanguage \
    -framework AppKit \
    tests/PerceptionAndMemoryV2Tests.swift \
    -o "$TEST_DIR/perception-v2-tests"
"$TEST_DIR/perception-v2-tests"

