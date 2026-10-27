#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-telegram-pairing.XXXXXX")"
mkdir -p "$TEST_DIR/mc" "$TEST_DIR/src"
trap 'rm -rf "$TEST_DIR"' EXIT

cp -R NotchBuddy/Sources/App/* "$TEST_DIR/src/"
rm -f "$TEST_DIR/src/NotchBuddyApp.swift"

SRCS=()
while IFS= read -r f; do
    SRCS+=("$f")
done < <(find "$TEST_DIR/src" -name '*.swift' -type f | sort)

swiftc -module-cache-path "$TEST_DIR/mc" "${SRCS[@]}" \
    -framework AVFoundation -framework Vision -framework CoreMedia \
    -framework CoreVideo -framework CoreImage -framework ApplicationServices \
    -framework CoreGraphics -framework Security -framework MediaPlayer \
    -framework JavaScriptCore -framework SwiftUI -framework AppKit \
    -framework UserNotifications -framework SystemConfiguration \
    -framework WebKit -framework Speech -framework NaturalLanguage \
    -framework AVKit \
    tests/TelegramPairingTests.swift \
    -o "$TEST_DIR/telegram-pairing-tests"

"$TEST_DIR/telegram-pairing-tests"

