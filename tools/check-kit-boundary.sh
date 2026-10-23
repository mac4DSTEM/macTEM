#!/bin/bash
# tools/check-kit-boundary.sh — the kit/app separation as a gate (decision D15).
#
# The kits (ImagoKit, DiffractoKit, FormatoKit, SpectroKit, CuboKit) hold the numerics; the app holds SwiftUI and app
# logic. This fails when app sources go back to doing numerics themselves:
#   1. a gated import (Accelerate, vecLib, Metal, MetalKit, MetalPerformanceShaders*, BNNS, simd) in a file or for a
#      module that tools/kit-boundary.allow does not list for that file;
#   2. a vDSP / cblas / vImage / LAPACK / vForce / BNNS / MPS symbol in a Swift file, unless its allowlist row carries
#      the token `+symbols` in the modules column (e.g. `Metal,MetalPerformanceShadersGraph,+symbols`);
#   3. a .metal file not in the allowlist.
# Plain grep and awk, no build: it runs wherever the repo is checked out. Run it from anywhere: tools/check-kit-boundary.sh
# Exit 0 clean, 1 on a violation, 2 when the allowlist is missing or lists a file that is gone.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOW="$ROOT/tools/kit-boundary.allow"
[ -f "$ALLOW" ] || { echo "kit-boundary: $ALLOW missing" >&2; exit 2; }
cd "$ROOT" || exit 2
rc=0

# Allowlist rows: path<TAB>modules<TAB>reason.
rows="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW")"
while IFS=$'\t' read -r path mods reason; do
  [ -z "$path" ] && continue
  [ -f "$path" ] || { echo "  allowlist names a file that is gone: $path"; rc=2; }
  [ -n "$reason" ] || { echo "  allowlist row without a reason: $path"; rc=2; }
done <<< "$rows"
[ "$rc" = 2 ] && exit 2

allowed_mods() {  # <path> -> comma list, empty when unlisted
  awk -F'\t' -v p="$1" '$1 == p { print $2 }' <<< "$rows"
}

gated='Accelerate|vecLib|Metal|MetalKit|MetalPerformanceShaders[A-Za-z]*|BNNS|simd'
symbols='vDSP_[A-Za-z0-9_]+|vDSP\.[A-Za-z]|cblas_[A-Za-z0-9_]+|vImage[A-Za-z0-9_]*|LAPACK[A-Za-z0-9_]*|[ds]gemm_|vv(exp|log|sin|cos|sqrt|pow|rsqrt|tan|atan2?)f?\(|BNNS[A-Za-z0-9_]*|MPS[A-Z][A-Za-z0-9_]*'

files="$( { find Sources macTEM macTEMTests tools/parity -type f \( -name '*.swift' -o -name '*.metal' \) 2>/dev/null; } | sort)"

while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in *.metal)
    [ -n "$(allowed_mods "$f")" ] || { echo "  $f: .metal file not in tools/kit-boundary.allow"; rc=1; }
    continue ;;
  esac
  ok=",$(allowed_mods "$f"),"
  symok=0; case "$ok" in *,+symbols,*) symok=1 ;; esac
  # Code lines only: whole-line // comments dropped (a comment may name Accelerate).
  code="$(grep -nvE '^[[:space:]]*//' "$f" 2>/dev/null | sed -E 's/^([0-9]+):/\1\t/')"
  while IFS=$'\t' read -r n mod; do
    [ -z "$mod" ] && continue
    case "$ok" in *",$mod,"*) ;; *) echo "  $f:$n: import $mod (not allowed here; numerics belong in a kit, or list the file in tools/kit-boundary.allow with a reason)"; rc=1 ;; esac
  done < <(awk -F'\t' '{ if (match($2, /^[[:space:]]*(@preconcurrency[[:space:]]+|@_exported[[:space:]]+)?(public[[:space:]]+|internal[[:space:]]+)?import[[:space:]]+(struct[[:space:]]+|class[[:space:]]+|func[[:space:]]+)?('"$gated"')([[:space:].;]|$)/)) {
             s = substr($2, RSTART, RLENGTH); sub(/^.*import[[:space:]]+(struct[[:space:]]+|class[[:space:]]+|func[[:space:]]+)?/, "", s); sub(/[[:space:].;].*$/, "", s); print $1 "\t" s } }' <<< "$code")
  hits="$(awk -F'\t' '$2 ~ /(^|[^A-Za-z0-9_])('"$symbols"')/ { print $1 ": " $2 }' <<< "$code")"
  if [ -n "$hits" ] && [ "$symok" = 0 ]; then
    while IFS= read -r h; do echo "  $f:$h  (numerics framework symbol; belongs in a kit)"; done <<< "$hits"; rc=1
  fi
done <<< "$files"

if [ "$rc" = 0 ]; then echo "kit-boundary: clean ($(grep -c . <<< "$files") files scanned, $(grep -c . <<< "$rows") allowlisted)"; else echo "kit-boundary: FAILED"; fi
exit $rc
