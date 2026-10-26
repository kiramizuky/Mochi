#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-vla-voice.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc NotchBuddy/Sources/App/IslandTypes.swift \
    NotchBuddy/Sources/App/IslandStateMachine.swift \
    NotchBuddy/Sources/App/SafeWebURL.swift \
    NotchBuddy/Sources/App/SoundEngine.swift \
    NotchBuddy/Sources/App/PolicyEngine.swift \
    NotchBuddy/Sources/App/AuditLog.swift \
    NotchBuddy/Sources/App/LLMProvider.swift \
    NotchBuddy/Sources/App/KeychainStore.swift \
    NotchBuddy/Sources/App/ProviderRegistry.swift \
    NotchBuddy/Sources/App/AnthropicProvider.swift \
    NotchBuddy/Sources/App/OpenAIProvider.swift \
    NotchBuddy/Sources/App/GeminiProvider.swift \
    NotchBuddy/Sources/App/GroqProvider.swift \
    NotchBuddy/Sources/App/LocalSLMProvider.swift \
    NotchBuddy/Sources/App/AccessibilityService.swift \
    NotchBuddy/Sources/App/AppController.swift \
    NotchBuddy/Sources/App/OSComputerControl.swift \
    NotchBuddy/Sources/App/VisualVerificationService.swift \
    NotchBuddy/Sources/App/VisualGroundingEngine.swift \
    NotchBuddy/Sources/App/VoiceCore.swift \
    NotchBuddy/Sources/App/HumanVoiceEngine.swift \
    NotchBuddy/Sources/App/VoiceManager.swift \
    NotchBuddy/Sources/App/VoiceDuplexEngine.swift \
    NotchBuddy/Sources/App/AutonomousTask.swift \
    NotchBuddy/Sources/App/AppState.swift \
    -framework AVFoundation \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework Security \
    -framework Speech \
    -framework ScreenCaptureKit \
    -framework AppKit \
    -framework SwiftUI \
    tests/VLAAndVoiceDuplexTests.swift \
    -o "$TEST_DIR/vla-voice-tests"
"$TEST_DIR/vla-voice-tests"

