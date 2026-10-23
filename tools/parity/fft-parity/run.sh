#!/bin/zsh
# tools/parity/fft-parity — ImagoKit's FFT2D / PowerSpectrum / RadialProfile / MaskedInverseFFT / Micrograph.cropped (ADR 027) against numpy 2.5.4 (pinned:
# tools/lib/references-lock.txt). Classified `scientific` in tools/run-tests.sh. Pre-registration: archive: roadmap-registrations-2026-10-15.md V1-6
# "Slice A, the compute core first" and "Slices B and D". README.md says more.
# Cases carry a "kind": spectrum (slice A), profile (B, radial profile), ifft (D, masked inverse FFT).
#
#   run.sh   make_fixture.py writes the planted images; reference.py checks numpy against every planted truth (DC bin,
#            bin-centred peaks, off-bin leakage) and writes numpy's spectra and axes (manifest.json + .f64); the Swift
#            side must match them (main.swift); then every mutation must fail the check it targets, or the gate fails
#            for being blind.
#
# Pass: "fft-parity: all passed", then "negative controls: 16 of 16 caught by their checks", exit 0.
# macTEM's seam to the kit comes from tools/lib/sources.manifest, group `fft`; the maths is ImagoKit's, built from the pinned checkout.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-fft-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" "$WORK/planted"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/planted" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" fft
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets — anything
# else fails the gate with the mutant's log. Targets are cases chosen so the mutation must change that check:
# p128x96 (even, anisotropic) for no-shift, the axes and power; p125x243 (odd width AND height: ifftshift's (n+1)/2 differs
# from n/2 on both axes) for shift-odd; c128x96-crop-even (non-zero offset 10, 20) for crop-origin.
# Slice B (profile): pr125x243 (dq_y = dq_x / 3.9: the most anisotropic) for the pixel-unit bins and for dq_x used on both
# axes; pr128x96 for round-for-floor, the dropped DC (count[0] loses one pixel) and sum-for-mean.
# Slice D (ifft): ifA-128x96 (raised-cosine edge e = 2, even w and h, strong lattice) for no Friedel partner, the hard
# edge (needs e > 0), the partner at n-k-1 (even n) and the unscaled inverse; measured against the unmutated result
# in numpy (relative to the real maximum): 0.50, 0.071, 0.037 and 1.2e4, all far above the 1e-5 band.
mutations=(no-shift shift-odd x-scale-both power-is-magnitude fftfreq-n-minus-1 crop-origin
           profile-pixel-bins profile-dqx-both profile-round profile-drop-dc profile-sum profile-ring-scale
           ifft-no-friedel ifft-hard-edge ifft-partner-off ifft-unscaled)
typeset -A targets=(
  no-shift             'p128x96 magnitude'
  shift-odd            'p125x243 magnitude'
  x-scale-both         'p128x96 axis_y'
  power-is-magnitude   'p128x96 power'
  fftfreq-n-minus-1    'p128x96 axis_x'
  crop-origin          'c128x96-crop-even crop'
  profile-pixel-bins   'pr125x243 profile'
  profile-dqx-both     'pr125x243 profile'
  profile-round        'pr128x96 profile'
  profile-drop-dc      'pr128x96 counts'
  profile-sum          'pr128x96 profile'
  profile-ring-scale   'pru125x243-uncal profile-away'
  ifft-no-friedel      'ifA-128x96 ifft'
  ifft-hard-edge       'ifA-128x96 ifft'
  ifft-partner-off     'ifA-128x96 ifft'
  ifft-unscaled        'ifA-128x96 ifft'
)
caught=0
for mutation in $mutations; do
  log="$WORK/mutant-$mutation.log"
  target="${targets[$mutation]:-}"
  set +e
  MACTEM_PARITY_MUTATE=$mutation "$WORK/harness" "$WORK/ref" > "$log" 2>&1
  rc=$?
  set -e
  if [[ -n "$target" ]] && (( rc == 1 )) \
     && grep -qE '^fft-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" \
     && awk -v want="$target: " 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$log"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$mutation' is caught by its check '$target'"
  elif [[ -z "$target" ]]; then
    echo "  FAIL  mutation '$mutation' has no target check in run.sh (exit $rc):"
    sed 's/^/        /' "$log"
  else
    echo "  FAIL  mutation '$mutation' exited $rc without failing its check '$target':"
    sed 's/^/        /' "$log"
  fi
done
if (( caught != ${#mutations} )); then
  echo "fft-parity: negative controls: $caught of ${#mutations} caught by their checks"
  exit 1
fi
echo "fft-parity: negative controls: ${#mutations} of ${#mutations} caught by their checks"
