#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-phase14.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Kumpulkan semua sumber kecuali NotchBuddyApp.swift (punya @main sendiri).
SRCS=()
while IFS= read -r f; do
    if [[ "$f" != */NotchBuddyApp.swift ]]; then
        SRCS+=("$f")
    fi
done < <(find NotchBuddy/Sources/App -name '*.swift' -type f | sort)

swiftc "${SRCS[@]}" \
    -framework AVFoundation -framework ApplicationServices -framework CoreGraphics \
    -framework Security -framework MediaPlayer -framework JavaScriptCore \
    -framework SwiftUI -framework AppKit -framework UserNotifications \
    tests/Phase14Tests.swift \
    -o "$TEST_DIR/phase14-tests"
"$TEST_DIR/phase14-tests"
