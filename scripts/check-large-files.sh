#!/usr/bin/env bash
# ==============================================================================
# check-large-files.sh
# Detects and blocks files larger than 10MB from being committed/pushed to Git.
# ==============================================================================

set -euo pipefail

MAX_BYTES=$((10 * 1024 * 1024)) # 10 Megabytes in bytes
MAX_MB=10

echo "🔍 Memeriksa file > ${MAX_MB}MB di repositori..."

LARGE_FILES_FOUND=0

# 1. Check staged files in git (if inside git repo)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        if [ -f "$file" ]; then
            SIZE=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
            if [ "$SIZE" -gt "$MAX_BYTES" ]; then
                SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $SIZE / 1048576}")
                echo "❌ [STAGED] File terlalu besar (${SIZE_MB}MB): $file"
                LARGE_FILES_FOUND=1
            fi
        fi
    done < <(git diff --cached --name-only --diff-filter=d 2>/dev/null || true)
fi

# 2. Check all untracked / working tree files (excluding .git)
while IFS= read -r file; do
    [ -z "$file" ] && continue
    SIZE=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt "$MAX_BYTES" ]; then
        SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $SIZE / 1048576}")
        echo "⚠️ [WORKSPACE] File melebihi ${MAX_MB}MB (${SIZE_MB}MB): $file"
        LARGE_FILES_FOUND=1
    fi
done < <(find . -type f -size +10M -not -path '*/.*' -not -path './DerivedData/*' -not -path './build/*' 2>/dev/null || true)

if [ "$LARGE_FILES_FOUND" -ne 0 ]; then
    echo ""
    echo "🚨 DITEMUKAN FILE > 10MB!"
    echo "File di atas akan ditolak atau memperlambat push ke GitHub."
    echo "Tambahkan path file tersebut ke .gitignore atau gunakan Git LFS jika memang diperlukan."
    exit 1
else
    echo "✅ Semua file aman (tidak ada file > ${MAX_MB}MB)."
    exit 0
fi
