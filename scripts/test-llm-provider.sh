#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-llm-provider.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/LLMProvider.swift \
    NotchBuddy/Sources/App/AnthropicProvider.swift \
    NotchBuddy/Sources/App/ChatStore.swift \
    tests/LLMProviderTests.swift -o "$TEST_DIR/llm-provider-tests"
"$TEST_DIR/llm-provider-tests"
