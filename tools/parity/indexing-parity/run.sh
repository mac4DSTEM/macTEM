#!/bin/zsh
# tools/parity/indexing-parity — macTEM's index of a measured |q| against the kinematic list (DiffractoKit's
# kinematicReflections rings and RingIndexing.index since ADR 025) against reference.py, a numpy reading of the same definition written from the registration and
# not from the Swift, with py4DSTEM's scattering_factors.txt (commit f050d207, sha256 asserted) for S1's list. Classified
# `scientific` in tools/run-tests.sh. Pre-registration: archive: roadmap-registrations-2026-10-15.md V1-8 "S2, indexing a measured |q| against the
# kinematic list" (ADR 022). README.md says more.
#
#   run.sh   reference.py rebuilds S1's lists, groups and names the families (checked against exact invariants and the
#            point groups' closure), writes every tier's plants with numpy's verdict and the truth, and confirms every
#            mutation below moves at least one plant; the Swift must match it (main.swift); then every mutation must fail
#            the check it targets, or the gate fails for being blind. Each mutation edits a COPY of one DiffractoKit source
#            file (the checkout tools/lib/fetch-diffractokit.sh pins; never the file itself) in the scratch directory, names it
#            in MACTEM_KIT_OVERRIDE and compiles the harness against the kit built from it. 37 controls (38 before DiffractoKit 0.3.0 dropped m16): the 43 of the copied
#            DSpacingIndexing / CIFImport / Crystal files re-expressed on the kit's files, five dropped because the code they
#            edit is gone (any-cell-cubic, mono-at-beta-90, mono-alpha-gamma-dropped, mono-unique-c-accepted and
#            element-before-lattice: the lattice refusal and its order no longer exist).
#
# Pass: "indexing-parity: all passed", then "negative controls: 37 of 37 caught by their checks", exit 0.
# TEMCore sources come from tools/lib/sources.manifest, group `indexing`.
# S2c (archive: roadmap-registrations-2026-10-15.md V1-8 "S2c", ADR 024): the beta'' CIF is written by tools/parity/crystal-structures/make_beta_double_prime.py into
# References/crystal-structures/ (gitignored), read by gemmi in reference.py and by CIFImport in the Swift; the controls
# are S2's 21, then S2c's m1-m15 of DSpacingIndexing.swift, c1-c5 of CIFImport.swift and x1 of Crystal.swift (copies, never
# edited in Sources/).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-indexing-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[[ -f "$HERE/main.swift" ]] || { echo "indexing-parity: $HERE/main.swift is missing (the harness the reference is compared with)"; exit 1; }

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$ROOT/tools/lib/fetch-py4dstem-scattering.sh"
BETA_CIF="$ROOT/References/crystal-structures/beta_double_prime_Mg5Si6.cif"
"$PYTHON_BIN" -I -B "$ROOT/tools/parity/crystal-structures/make_beta_double_prime.py" "$BETA_CIF"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$ROOT/References/py4dstem-scattering/scattering_factors.txt" "$WORK/ref" "$BETA_CIF"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" indexing
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit; a crash by signal
# never counts) AND its log holds a "  FAIL  " line of every check it targets (a check is named by the text before ": ").
# A mutant that makes the list builder trap or hang (the k_max bound dropped: S1's tile traps at 1e19, runs for minutes at
# 1e6) is caught only because main.swift builds the T4 k_max lists in a child process with a time limit, and reports a
# trap or a timeout as that crystal's own failed check.
failed_check() {
  awk -v want="$2: " 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$1"
}
caught_by() {
  local log=$1 rc=$2 spec=$3 name
  (( rc == 1 )) || return 1
  grep -qE '^indexing-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" || return 1
  for name in "${(@s:|:)spec}"; do failed_check "$log" "$name" || return 1; done
}

KIT="$("$ROOT/tools/lib/fetch-diffractokit.sh")"                  # the pinned checkout the next source_mutant edits a copy of
caught=0
total=0
source_mutant() {   # source_mutant <name> <targets, '|'-separated> <kit-relative file> <old> <new> [<old> <new>]... [<next file> <old> <new>...]
  local name=$1 spec=$2 rel=$3; shift 3
  local dir="$WORK/source-$name"
  total=$(( total + 1 ))
  mkdir -p "$dir"
  local -A copies
  copies=()
  local copy="$dir/${rel:t}"
  cp "$KIT/$rel" "$copy"
  copies[$rel]="$copy"
  while (( $# >= 2 )); do
    if [[ "$1" == Sources/*.swift && $(( $# % 2 )) == 1 ]]; then   # a further kit file (odd argument count: file, then pairs)
      rel=$1; copy="$dir/${rel:t}"; cp "$KIT/$rel" "$copy"; copies[$rel]="$copy"; shift; continue
    fi
    "$PYTHON_BIN" -I -B -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("source mutation: expected exactly one occurrence of the edit target, found %d: %s" % (text.count(old), old))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
' "$copy" "$1" "$2" || { echo "  FAIL  source mutation '$name' does not apply to ${rel:t}"; return; }
    shift 2
  done
  MACTEM_KIT_OVERRIDE=()
  for rel in ${(k)copies}; do MACTEM_KIT_OVERRIDE[$rel]="${copies[$rel]}"; done
  if ! mactem_swiftc "$dir/harness" "$HERE/main.swift" > "$dir/build.log" 2>&1; then
    MACTEM_KIT_OVERRIDE=()
    echo "  FAIL  source mutation '$name' does not compile:"
    sed 's/^/        /' "$dir/build.log" | head -30
    return
  fi
  MACTEM_KIT_OVERRIDE=()
  local log="$dir/mutant.log" rc
  set +e
  "$dir/harness" "$WORK/ref" > "$log" 2>&1
  rc=$?
  set -e
  if caught_by "$log" $rc "$spec"; then
    caught=$(( caught + 1 ))
    echo "  ok    source mutation '$name' is caught by its check '${spec//|/' and '}'"
  else
    echo "  FAIL  source mutation '$name' exited $rc without failing its check '${spec//|/' and '}':"
    sed 's/^/        /' "$log" | head -40
  fi
}

RI=Sources/DiffractoGeometry/RingIndexing.swift
RL=Sources/DiffractoCore/ReflectionList.swift
PS=Sources/DiffractoCore/PointSymmetry.swift
UC=Sources/DiffractoCore/UnitCell.swift
SD=Sources/DiffractoCore/SymmetryDetection.swift
CI=Sources/DiffractoCore/CIFImport.swift
SO=Sources/DiffractoCore/SymmetryOperation.swift
SF=Sources/DiffractoScattering/StructureFactors.swift
ES=Sources/DiffractoScattering/ElectronScatteringFactors.swift
FAMTOL='public static let familyTolerance: Double = 1e-9'
GROUP='if let first = group.first, r.gLength > first.gLength * (1 + ringTolerance) { close() }'
ORBITS='let orbits = Set(members.map { laueGroup.canonical($0) }).sorted(by: >)'
MULT='public var multiplicity: Int { members.count }'
CUBICRULE='let orbits = Set(members.map { m -> MillerIndex in let s = [abs(m.h), abs(m.k), abs(m.l)].sorted(by: >); return MillerIndex(s[0], s[1], s[2]) }).sorted(by: >)'

# ---- The decision (RingIndexing.swift): the registered mutations of archive: roadmap-registrations-2026-10-15.md V1-8 S2.
# (1) δ over the measured d, 1 − q/g: −0.0100 instead of −0.00990 at q = 1.01 g.
source_mutant deviation-over-measured-d 'T1 deviation' $RI \
  'deviation: $0.g / q - 1)' 'deviation: 1 - q / $0.g)'
# (2) absences kept: no |F| cut at all keeps every in-range (h, k, l), |F| = 0 included (Au: 8 families become 20).
source_mutant absences-kept 'Au families|T4 noneWithinTolerance' $SF \
  'let kept = all.filter { $0.structureFactor.magnitude > cut }' 'let kept = all'
# (3) grouping at 0: one family splits at the roundoff of its members' |g| (ideal hcp's {30-32} + {0006}; beta'' 417 -> 527).
source_mutant grouping-at-zero 'Mg-ideal families' $RL "$GROUP" 'if let first = group.first, r.gLength > first.gLength * (1 + 0 * ringTolerance) { close() }'
# (4) grouping at 1e-2: Mg {10-15} and {21-32}, 0.156 % apart, merge.
source_mutant grouping-at-1e-2 'Mg families' $RL "$FAMTOL" 'public static let familyTolerance: Double = 1e-2'
# (5) hexagonal orbits named by the cubic rule (|h|, |k|, |l| sorted); (5b) the same edit, monoclinic checks.
source_mutant hexagonal-by-cubic-rule 'Mg orbits' $RL "$ORBITS" "$CUBICRULE"
# (6) the canonical form prefers the FEWEST non-negative indices: Mg {11-20}'s member (−1, −1, 0) is named apart from (1, 1, 0).
source_mutant hexagonal-without-negation 'Mg orbits' $PS \
  '(lhs.nonNegativeCount, lhs.h, lhs.k, lhs.l) < (rhs.nonNegativeCount, rhs.h, rhs.k, rhs.l)' \
  '(-lhs.nonNegativeCount, lhs.h, lhs.k, lhs.l) < (-rhs.nonNegativeCount, rhs.h, rhs.k, rhs.l)'
# (7) the multiplicity as the orbit count.
source_mutant multiplicity-as-orbits 'Si multiplicity' $RL "$MULT" 'public var multiplicity: Int { orbits.count }'
# (8) the second-within check dropped: the nearest of two families within kσ_q is accepted.
source_mutant second-within-dropped 'T4 ambiguous' $RI \
  'if within.count >= 2 { throw .ambiguous(Array(within)) }' ''
# (9) the margin clause dropped: the margin plant (z 2.5 against 3.2, margin 2.0 < ln 19) is accepted.
source_mutant margin-clause-dropped 'T4 ambiguous' $RI \
  'if let next, let ratio = measured, ratio < margin { throw .ambiguous([best, next]) }' ''
# (10) the margin as z₂ − z₁.
source_mutant margin-as-z-difference 'T1 margin' $RI \
  'let measured = next.map { ($0.z * $0.z - best.z * best.z) / 2 }' 'let measured = next.map { $0.z - best.z }'
# (11) the reach at kσ_q alone: Si {620}, whose listed next ({531}) is farther than the edge, is accepted.
source_mutant reach-at-k-sigma 'T4 beyondKMax' $RI \
  'let reachEnd = q + max(r, abs(q - best.family.g), next.map { abs(q - $0.family.g) } ?? 0)' \
  'let reachEnd = q + k * sigma'
# (12) z as |q − g|/(σ_q·q).
source_mutant z-relative 'T1 z' $RI 'z: abs(q - $0.g) / sigma,' 'z: abs(q - $0.g) / (sigma * q),'
# (13) z² ≤ k: an own family at 1.73 < z ≤ 3 is no longer within.
source_mutant z-squared 'T1 P1' $RI 'let within = candidates.prefix { $0.z <= k }' 'let within = candidates.prefix { $0.z * $0.z <= k }'
# (14) the nearest family as the first g ≥ q.
source_mutant nearest-first-above 'T1 P1' $RI \
  '.sorted { ($0.z, $0.family.g) < ($1.z, $1.family.g) }' \
  '.sorted { ($0.family.g < q ? 1 : 0, $0.z) < ($1.family.g < q ? 1 : 0, $1.z) }'
# (15) the next as the upper neighbour of the best.
source_mutant next-as-upper-neighbour 'T1 next' $RI \
  'let next = candidates.count > 1 ? candidates[1] : nil' \
  'let next = candidates.filter { $0.family.g > best.family.g }.min { $0.family.g < $1.family.g }'
# (16) unsupported elements ignored: Z = 104 is scored as Lr's row (the list is built, not refused).
source_mutant elements-ignored 'T4 unsupportedElement' $ES \
  'public static func isSupported(z: Int) -> Bool { z >= 1 && z <= maximumAtomicNumber }' \
  'public static func isSupported(z: Int) -> Bool { z >= 1 }' \
  'let p = parameters[z - 1]' 'let p = parameters[min(z, maximumAtomicNumber) - 1]'
# (17) σ_q = 0 accepted.
source_mutant sigma-zero-accepted 'T4 invalidInput' $RI 'guard sigma.isFinite, sigma > 0 else' 'guard sigma.isFinite, sigma >= 0 else'
# (18) the k_max bound dropped: 5 is built, 1e6 and 1e19 are refused as too large (the latter two in a child, timed).
source_mutant kmax-bound-dropped 'T4 invalidInput' $RL \
  'guard kMax.isFinite, kMax > 0, kMax <= policy.maximumKMax else { throw .invalidKMax(kMax) }' \
  'guard kMax.isFinite, kMax > 0 else { throw .invalidKMax(kMax) }'
# (19) S1's cut raised to 1e-2: the weak families of the Weak-cut cell disappear.
source_mutant cut-raised 'Weak-cut families' $SF 'public static let defaultCut = 1e-4' 'public static let defaultCut = 1e-2'
# (20) the cell family read only at exact equality: the near-cubic (b = a(1 + 1e-11)) and near-hexagonal
# (γ = 120° + 1e-10°) cells fall to a lower Laue class.
source_mutant lattice-exact 'near-cubic list|near-hexagonal list' $SD \
  'public static let defaultMetricLengthTolerance = 1e-9' 'public static let defaultMetricLengthTolerance = 0.0' \
  'public static let defaultMetricAngleToleranceDeg = 1e-9' 'public static let defaultMetricAngleToleranceDeg = 0.0'

# ---- S2c: the monoclinic orbits, names, cell family and grouping.
# m1: monoclinic orbits by the cubic rule (the edit of (5), checked on M-P and beta'').
source_mutant mono-by-cubic-rule 'M-P orbits|beta'"''"' orbits' $RL "$ORBITS" "$CUBICRULE"
# m2: the canonical form is the LEAST orbit member (the sign flip with h is lost).
source_mutant mono-no-sign-flip 'M-P orbits' $PS 'orbit.max { lhs, rhs in' 'orbit.min { lhs, rhs in'
# m3: the canonical form is negated (K and L carry the wrong sign).
source_mutant mono-k-signed-for-negative-h 'M-P orbits' $RL "$ORBITS" \
  'let orbits = Set(members.map { laueGroup.canonical($0).negated }).sorted(by: >)'
# m4: |l| taken for every canonical form (the h = 0 orbits lose the sign of l, and so do (2 0 -1) and (2 0 1)).
source_mutant mono-h0-l-signed 'M-P orbits' $RL "$ORBITS" \
  'let orbits = Set(members.map { m -> MillerIndex in let c = laueGroup.canonical(m); return MillerIndex(c.h, c.k, abs(c.l)) }).sorted(by: >)'
# m5: the multiplicity as the orbit count (the edit of (7), checked on M-P).
source_mutant mono-multiplicity-as-orbits 'M-P multiplicity' $RL "$MULT" 'public var multiplicity: Int { orbits.count }'
# m6: grouping at 1e-4: beta'' {3 1 5} and {7 3 0} (1.03e-5 apart) merge.
source_mutant mono-grouping-1e-4 "beta'' families" $RL "$FAMTOL" 'public static let familyTolerance: Double = 1e-4'
# m7: grouping at 0: families split at the roundoff of their members' |g| (beta'' 417 -> 527).
source_mutant mono-grouping-at-zero "beta'' families" $RL "$GROUP" 'if let first = group.first, r.gLength > first.gLength * (1 + 0 * ringTolerance) { close() }'
# m11: the cell-family angle tolerance 1e-7 deg: beta = 90 deg + 1e-8, which is monoclinic, reads orthorhombic (the list has the same
# 239 rings, so the counts hold and the orbits and member counts are what fail; the copy's refusal check is gone).
source_mutant mono-lattice-tolerance-1e-7 'M-P-b+1e-8 orbits|M-P-b+1e-8 multiplicity' $SD \
  'public static let defaultMetricAngleToleranceDeg = 1e-9' 'public static let defaultMetricAngleToleranceDeg = 1e-7'
# m12: the group of the improper operations missing from the orbits (the mirror and the inversion).
source_mutant mono-mirror-missing 'M-P orbits' $PS \
  'Set(rotations.map { hkl.applying($0) })' 'Set(rotations.filter { $0.determinant == 1 }.map { hkl.applying($0) })'
# m14: the family name lists its first orbit only (M-sq {2 0 0} + {2 0 -1}).
source_mutant name-first-orbit-only 'M-sq names' $RL \
  'name: orbits.map { PointSymmetry.orbitName(ofCanonical: $0, millerBravais: millerBravais) }' \
  'name: orbits.prefix(1).map { PointSymmetry.orbitName(ofCanonical: $0, millerBravais: millerBravais) }'
# m15 (an addition: the closed-form test needs a grouping mutant that merges real rings): grouping at 30 %.
source_mutant mono-grouping-30-percent 'M-P families' $RL "$FAMTOL" 'public static let familyTolerance: Double = 0.3'
# m16 (mono-beta-above-90-only: the acute-beta cell is not monoclinic) is DROPPED at DiffractoKit 0.3.0: a cell is read through its
# Niggli-reduced conventional cell, whose monoclinic angle is obtuse, so neither the restriction of metricFamily to angles above 90 deg
# (all three unique axes) nor the conventional route refusing beta <= 90 deg changes M-P-acute's orbits (both tried; exit 0, the
# multi-file source_mutant below was written for it and stays). The behaviour that control guarded no longer exists as a decision.
# ---- S2c: the beta'' CIF through CIFImport, against the 22 sites and the cell gemmi read.
# c1: the centring translations skipped in the expansion (11 sites).
source_mutant cif-centring-skipped 'cif sites' $CI \
  '            for op in ops {
                let mapped' '            for op in ops.prefix(4) {
                let mapped'
# c2: beta read from the alpha tag.
source_mutant cif-beta-from-alpha-tag 'cif model' $CI 'try requiredNumber("_cell_angle_beta")' 'try requiredNumber("_cell_angle_alpha")'
# c3: z read as y (two sites coincide at 0.43 A: the structure is refused as invalid).
source_mutant cif-z-read-as-y 'cif model' $CI 'let zCoord = try parseNumber(zRaw, tag:' 'let zCoord = try parseNumber(yRaw, tag:'
# c4: the duplicate tolerance 0.5: distinct sites merge.
source_mutant cif-duplicate-tolerance-half 'cif sites' $CI \
  'let maxMergeDistance = policy.nonNegative(policy.maximumMergeDistance)' 'let maxMergeDistance = 50.0' \
  'let mergeFloor = policy.nonNegative(policy.minimumMergeTolerance)' 'let mergeFloor = 0.5'
# c5: a symmetry operation's translation parsed as nothing ("1/2+x" as "x"): the importer's own operation count (4 of 8) refuses.
source_mutant cif-translation-dropped 'cif model' $SO 'constant += sign * magnitude' 'constant += 0 * sign * magnitude'
# ---- S2c: the oblique metric (the first test of it in macTEM): cos(beta) of the third vector flipped.
source_mutant cell-beta-sign-flipped 'monoclinic anchors' $UC \
  'SIMD3<Double>(c * cos(beta), -c * f / sin(gamma)' 'SIMD3<Double>(-c * cos(beta), -c * f / sin(gamma)'

if (( caught != total )); then
  echo "indexing-parity: negative controls: $caught of $total caught by their checks"
  exit 1
fi
echo "indexing-parity: negative controls: $total of $total caught by their checks"
