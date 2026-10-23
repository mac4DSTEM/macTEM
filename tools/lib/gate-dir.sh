#!/bin/zsh
# tools/lib/gate-dir.sh — where a tree's gate output lives: outside the tree (the lean pass, owner 2026-10-15).
#
#   mactem_gate_dir <tree root>   prints $MACTEM_GATE_DIR, else $TMPDIR/macTEM-gates/<tree's basename>-<8 hex of
#                                 sha256 of its absolute path>
#
# tools/gate.sh keeps its logs, last-green stamps and the warm DerivedData (dd-unit) there; tools/hooks/pre-push keeps
# its log and DerivedData in prepush/ below it. The hash keeps two trees of the same name (a scratch mirror and the repo)
# apart. Nothing is written inside the tree for this.
mactem_gate_dir() {  # <tree root>
  local root="$1" hash
  if [[ -n "${MACTEM_GATE_DIR:-}" ]]; then print -r -- "$MACTEM_GATE_DIR"; return 0; fi
  hash="$(print -rn -- "$root" | /usr/bin/shasum -a 256 | cut -c1-8)"
  print -r -- "${TMPDIR:-/tmp}/macTEM-gates/${root:t}-$hash"
}
