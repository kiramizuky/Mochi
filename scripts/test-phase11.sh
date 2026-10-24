#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-phase11.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/PolicyEngine.swift \
    NotchBuddy/Sources/App/AuditLog.swift \
    NotchBuddy/Sources/App/CrashReporter.swift \
    NotchBuddy/Sources/App/AutoUpdate.swift \
    tests/Phase11Tests.swift \
    -framework AppKit \
    -o "$TEST_DIR/phase11-tests"
"$TEST_DIR/phase11-tests"
