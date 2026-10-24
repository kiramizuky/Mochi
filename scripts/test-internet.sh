#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-internet.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/LLMProvider.swift \
    NotchBuddy/Sources/App/PolicyEngine.swift \
    NotchBuddy/Sources/App/AuditLog.swift \
    NotchBuddy/Sources/App/SafeWebURL.swift \
    NotchBuddy/Sources/App/InternetService.swift \
    NotchBuddy/Sources/App/AppController.swift \
    NotchBuddy/Sources/App/WindowController.swift \
    NotchBuddy/Sources/App/AppAutomation.swift \
    NotchBuddy/Sources/App/AccessibilityService.swift \
    NotchBuddy/Sources/App/MemoryService.swift \
    NotchBuddy/Sources/App/ToolExecutor.swift \
    NotchBuddy/Sources/App/NodeEngine.swift \
    NotchBuddy/Sources/App/NodeDefinitions.swift \
    NotchBuddy/Sources/App/NodeRunner.swift \
    tests/InternetAppTests.swift \
    -framework MediaPlayer -framework JavaScriptCore \
    -o "$TEST_DIR/internet-app-tests"
"$TEST_DIR/internet-app-tests"
