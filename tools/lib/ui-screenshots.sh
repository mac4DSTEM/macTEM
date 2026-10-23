#!/bin/zsh
# tools/lib/ui-screenshots.sh <result bundle> <gate dir> — pulls the step screenshots out of a UI run's .xcresult into
# <gate dir>/ui-screenshots/<short sha>/ (PNGs plus the manifest naming test, step and file), and drops runs older than seven days.
# The folder is outside the tree (the gate dir), never in the repo.
set -euo pipefail
result="$1"; gate="$2"
sha="$(git -C "${0:A:h}/../.." rev-parse --short HEAD)"
out="$gate/ui-screenshots/$sha"
rm -rf "$out"; mkdir -p "$out"
xcrun xcresulttool export attachments --path "$result" --output-path "$out" > /dev/null
find "$gate/ui-screenshots" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
echo "ui: $(find "$out" -name '*.png' | wc -l | tr -d ' ') screenshots in $out"
