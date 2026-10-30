#!/bin/zsh
# tools/lib/harness.sh — builds a parity harness with SwiftPM. Each harness is an executable target in Package.swift
# (`parityHarness`) over TEMCore, so the kits it links are the ones Package.resolved pins and TEMCore builds with its own settings.
#
#   . "$ROOT/tools/lib/harness.sh"
#   mactem_harness_build <Product> <output>
#       builds the harness from the tree as it is and copies the executable to <output> (with links to the frameworks and
#       resource bundles it loads beside it)
#   mactem_harness_mutant <Product> <output> <file, relative to the repo> <edited copy>
#       builds the harness with that one file replaced by the edited copy (a negative control), then puts the file back
#   mactem_harness_checkout <Package>
#       resolves the tree's dependencies and prints the path of that package's checkout (sidecar-parity takes FormatoKit's
#       vendored libhdf5 from it)
#
# Both build Debug with -O for every module (TEMCore's own Debug setting; the kits' too, so a harness never runs the science
# at -Onone), incrementally. The tree's build lives in <gate dir>/harness-build; a mutant is built in a mirror of the package
# (<gate dir>/harness-mirror, synced from the tree before each mutant), so the tree itself is never edited. Mutant builds take a
# lock (one at a time per gate dir: the mirror is shared); the harness runs after the build need no lock. Nothing is written
# inside the tree.

. "$ROOT/tools/lib/gate-dir.sh"   # needs ROOT, the repo root
zmodload zsh/system

MACTEM_HARNESS_GATE="$(mactem_gate_dir "$ROOT")"
MACTEM_HARNESS_JOBS="${MACTEM_HARNESS_JOBS:-2}"

_mactem_harness_swift_build() {  # <package dir> <scratch dir> <Product>
  swift build --package-path "$1" --scratch-path "$2" --product "$3" -j "$MACTEM_HARNESS_JOBS" -Xswiftc -O
}

# Copies the executable to <output> and links the frameworks and resource bundles it loads (@loader_path) beside it.
_mactem_harness_install() {  # <bin dir> <Product> <output>
  local item
  cp "$1/$2" "$3" || return 1
  for item in "$1"/*.framework(N) "$1"/*.bundle(N); do ln -sfn "$item" "${3:h}/${item:t}"; done
}

mactem_harness_build() {  # <Product> <output>
  (( $# == 2 )) || { echo "harness.sh: usage: mactem_harness_build <Product> <output>" >&2; return 64; }
  local scratch="$MACTEM_HARNESS_GATE/harness-build" bin
  mkdir -p "$scratch"
  _mactem_harness_swift_build "$ROOT" "$scratch" "$1" || { echo "harness.sh: $1 does not build" >&2; return 67; }
  bin="$(swift build --package-path "$ROOT" --scratch-path "$scratch" -Xswiftc -O --show-bin-path)"
  _mactem_harness_install "$bin" "$1" "$2"
}

mactem_harness_checkout() {  # <Package>
  local scratch="$MACTEM_HARNESS_GATE/harness-build"
  mkdir -p "$scratch"
  swift package --package-path "$ROOT" --scratch-path "$scratch" resolve >&2 || return 65
  [[ -d "$scratch/checkouts/$1" ]] || { echo "harness.sh: no checkout of $1 in $scratch/checkouts" >&2; return 66; }
  print -r -- "$scratch/checkouts/$1"
}

# The files a harness build reads: the manifest, the pins, TEMCore's sources and the harnesses' own (with the unit tests' HDF5 binding).
_mactem_harness_sync_mirror() {  # <mirror>
  mkdir -p "$1/macTEMTests" "$1/tools"
  rsync -a "$ROOT/Package.swift" "$ROOT/Package.resolved" "$1/"
  rsync -a --delete "$ROOT/Sources/" "$1/Sources/"
  rsync -a --delete "$ROOT/tools/parity/" "$1/tools/parity/"
  rsync -a "$ROOT/macTEMTests/TestHDF5Binding.swift" "$1/macTEMTests/"
}

mactem_harness_mutant() {  # <Product> <output> <file, relative to the repo> <edited copy>
  (( $# == 4 )) || { echo "harness.sh: usage: mactem_harness_mutant <Product> <output> <file> <edited copy>" >&2; return 64; }
  local product=$1 out=$2 rel=$3 copy=$4
  local mirror="$MACTEM_HARNESS_GATE/harness-mirror" scratch="$MACTEM_HARNESS_GATE/harness-mirror-build" lock fd rc=0 bin
  [[ -f "$ROOT/$rel" ]] || { echo "harness.sh: no such file $rel in the tree" >&2; return 66; }
  mkdir -p "$MACTEM_HARNESS_GATE" "$scratch"
  lock="$MACTEM_HARNESS_GATE/harness-mirror.lock"
  : >> "$lock"
  zsystem flock -f fd "$lock" || { echo "harness.sh: cannot lock $lock" >&2; return 75; }
  {
    # Synced on every mutant (rsync keeps the times, so only what changed rebuilds): a mutant an interrupted run left behind is
    # put back, and the mirror equals the tree but for this one file.
    _mactem_harness_sync_mirror "$mirror"
    cp "$copy" "$mirror/$rel"
    if _mactem_harness_swift_build "$mirror" "$scratch" "$product"; then
      bin="$(swift build --package-path "$mirror" --scratch-path "$scratch" -Xswiftc -O --show-bin-path)"
      _mactem_harness_install "$bin" "$product" "$out" || rc=$?
    else
      rc=67
    fi
    cp -p "$ROOT/$rel" "$mirror/$rel"
  } always {
    exec {fd}>&-
  }
  return $rc
}
