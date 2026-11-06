#!/usr/bin/env bash
# tools/parity/sem/fetch-data.sh — download the SEM program's datasets into References/sem-data/ (gitignored) and verify
# their sha256 against data-manifest.txt. Idempotent: a file whose checksum already matches is not fetched again.
#   fetch-data.sh            everything with a URL; "manual" lines are listed, never fetched
#   fetch-data.sh --check    verify only, exit 1 when a URL-backed file is missing or wrong
# Plain bash and curl so GitHub's Linux runners run it (.github/workflows/sem-parity.yml).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DATA="${MACTEM_SEM_DATA:-$ROOT/References/sem-data}"
check_only=0; [[ "${1:-}" == "--check" ]] && check_only=1

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

rc=0
while IFS=$'\t' read -r dest want url; do
  [[ -z "$dest" || "$dest" == \#* ]] && continue
  path="$DATA/$dest"
  if [[ "$url" == manual:* ]]; then
    if [[ -f "$path" ]]; then echo "fetch-data: present (manual) $dest"; else echo "fetch-data: manual   $dest <- ${url#manual:}"; fi
    continue
  fi
  if [[ -f "$path" && "$(sha "$path")" == "$want" ]]; then echo "fetch-data: ok       $dest"; continue; fi
  if (( check_only )); then echo "fetch-data: MISSING  $dest"; rc=1; continue; fi
  mkdir -p "$(dirname "$path")"
  echo "fetch-data: fetching $dest"
  curl -sSfL --retry 4 --retry-delay 2 -o "$path.part" "$url"
  have="$(sha "$path.part")"
  if [[ "$have" != "$want" ]]; then echo "fetch-data: sha256 MISMATCH for $dest: want $want, got $have" >&2; rm -f "$path.part"; rc=1; continue; fi
  mv "$path.part" "$path"
done < "$HERE/data-manifest.txt"
exit $rc
