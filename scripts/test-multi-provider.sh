#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-multi-provider.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/LLMProvider.swift \
    NotchBuddy/Sources/App/KeychainStore.swift \
    NotchBuddy/Sources/App/AnthropicProvider.swift \
    NotchBuddy/Sources/App/OpenAIProvider.swift \
    NotchBuddy/Sources/App/GeminiProvider.swift \
    NotchBuddy/Sources/App/ProviderRegistry.swift \
    NotchBuddy/Sources/App/ChatStore.swift \
    tests/MultiProviderTests.swift \
    -framework Security -o "$TEST_DIR/multi-provider-tests"
"$TEST_DIR/multi-provider-tests"
