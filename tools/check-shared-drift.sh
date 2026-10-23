#!/bin/zsh
# tools/check-shared-drift.sh — every file macTEM copied from mac4DSTEM, held to its source.
#
#   tools/check-shared-drift.sh [--diff]   BODIES (the default): everything --static checks, then each copy's body
#                                          against its source at the pinned commit, and the source's movement on
#                                          mac4DSTEM `main` since. Needs the sibling checkout (MAC4DSTEM_REPO).
#   tools/check-shared-drift.sh --static   no sibling checkout (inventory, CI): the header layout, the single pin,
#                                          the kinds, and tools/lib/copies.manifest equal to what is found — not
#                                          the bodies.
#   --diff prints the differences (an adapted copy against its source, a broken one, a moved source).
#   MAC4DSTEM_REPO=/path   the sibling checkout (default: ../mac4DSTEM beside this repo)
# Exit 0: everything checked holds (upstream movement is reported, never failing — mac4DSTEM's main moves hourly).
# Exit 1: git cannot list this repo's files, a malformed header or manifest line, mixed pins, a copy found but not
# in the manifest or listed but not found or listed under another kind or source, an unresolvable source, or (bodies)
# an enforced copy that no longer matches its pinned source. Exit 64: usage.
#
# THE HEADER. A copy starts with (`#` instead of `//` in Python, shell, YAML and Markdown front matter):
#   // PROVENANCE: mac4DSTEM <40-hex commit> <path in the mac4DSTEM repo> <kind>
#   // KEEPS: <source line ranges at the pin, e.g. 19-20, 22, 101-130>     (subset only, exactly once)
#   // (optional lines: what changed and why)
#   // END PROVENANCE
# Its layout is enforced, so no code hides outside the compared text: the PROVENANCE line is line 1, or line 2 after
# a `#!` shebang or a `---` front-matter line (that line 1 is then compared with the body as the copy's first line);
# it is the file's first line containing the marker string, and no other line looks like a header (a comment naming
# a commit); every line from PROVENANCE through END PROVENANCE starts with the file's comment marker; for verbatim,
# subset and extract the body after END PROVENANCE is not blank.
# Anything else is MALFORMED. Every copy names the SAME commit: the copies are one coherent snapshot (a verbatim
# InspectorRows needs the NumericField of its own commit), so a re-sync moves all of them at once.
#
# THE MANIFEST, tools/lib/copies.manifest: one line per file, `<kind> <copy path> <mac4DSTEM source path>`. Discovery
# is loose — every tracked or untracked-not-ignored file containing the marker string anywhere, near-miss headers
# included — and must equal the manifest. Files that cannot carry a header are listed with kind `asset` or
# `asset-adapted`; files that only mention the header (docs, this tool) with kind `mention` and source `-`.
#
# kind      what the compared text (line 1 when it precedes the header, then the body) must be, against the source
#           at the pinned commit after the normalisations below
#   verbatim  identical
#   subset    exactly the source lines KEEPS names, in order, line for line; a line ending in a `// DEVIATION:` comment
#             (code before it, so not a comment-only line) stands in for the KEEPS line at its position
#   extract   contiguous blocks of the source, in order; blocks are separated by comment-only lines containing
#             `EXTRACT-GAP`; blank lines and plain `import <Module>` lines (an optional trailing comment) do not count
#   adapted   anything: the difference is reported, never enforced
#   asset     byte-identical to the source (no header, no normalisation: an SVG, an image)
#   asset-adapted  anything: the difference is reported, never enforced
#   mention   not a copy: the file names the header format (docs, NOTICE, this tool)
# The normalisations, applied to the source (at the pin and on main) before comparing — each is what Swift 6 or the
# module names force, never logic:
#   1. mac4DSTEM's module names map to macTEM's: DSTEMCore -> TEMCore, DSTEMSession -> TEMSession (whole words).
#   2. `@testable import mac4DSTEM` -> `@testable import macTEM` (the whole line).
#   3. A test class gains `nonisolated` (`final class X: XCTestCase` at the line start): Swift 6 with MainActor
#      default isolation does not compile a MainActor XCTestCase subclass.
#   4. A leading `@MainActor ` is stripped from a `func test…(` line — on BOTH sides, the copy too: under that
#      default a test method touching main-actor UI needs the annotation, which is isolation, not logic.
#
# Two questions per copy: LOCAL — does the copy still match its kind against the pinned source? UPSTREAM — has the
# source changed on mac4DSTEM `main` since (a matching extract: do its blocks still match main; every other copy: is
# the source the same after normalisation)? A copy that stays IDENTICAL is a candidate for a shared
# library at the macTEM v1 review (docs/decisions/003-spectrokit.md).
#
# READ-ONLY on mac4DSTEM: `git --no-optional-locks show/rev-parse/cat-file` only — no fetch, no checkout, never the
# working tree (another session's uncommitted edits are not a source). It compares against the LOCAL `main` ref.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UP="${MAC4DSTEM_REPO:-$ROOT/../mac4DSTEM}"
MANIFEST="$ROOT/tools/lib/copies.manifest"
TAG='PROVENANCE: mac4DSTEM'
SHOW_DIFF=0; STATIC=0
usage() { echo "Usage: tools/check-shared-drift.sh [--diff | --static]" >&2; exit 64; }
(( $# <= 1 )) || usage
case "${1:-}" in --diff) SHOW_DIFF=1 ;; --static) STATIC=1 ;; "") ;; *) usage ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-shared-drift.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- what is in the repo: git must answer, or nothing below means anything --------------------------------------
if ! git -C "$ROOT" ls-files -co --exclude-standard -z > "$WORK/files" 2> "$WORK/files.err"; then
  echo "check-shared-drift: git cannot list the files of $ROOT:" >&2; cat "$WORK/files.err" >&2; exit 1
fi
tracked=(${(0)"$(< "$WORK/files")"})
present=(); typeset -A present_set
for f in $tracked; do [[ -f "$ROOT/$f" ]] && { present+=("$f"); present_set[$f]=1; }; done
(( ${#present} )) || { echo "check-shared-drift: git lists no files in $ROOT" >&2; exit 1; }
found_rc=0
( cd "$ROOT" && grep -l -F -- "$TAG" $present ) > "$WORK/found" 2> "$WORK/found.err" || found_rc=$?
if (( found_rc > 1 )); then
  echo "check-shared-drift: searching for the header failed:" >&2; cat "$WORK/found.err" >&2; exit 1
fi
typeset -A found_set
for f in ${(f)"$(< "$WORK/found")"}; do found_set[$f]=1; done

# ---- the manifest ------------------------------------------------------------------------------------------------
[[ -f "$MANIFEST" ]] || { echo "check-shared-drift: no manifest at $MANIFEST" >&2; exit 1; }
rc=0
typeset -A m_kind m_src
order=()
lineno=0
while IFS= read -r mline || [[ -n "$mline" ]]; do
  lineno=$(( lineno + 1 ))
  [[ "$mline" =~ '^[[:space:]]*(#|$)' ]] && continue
  fields=(${=mline})
  if (( ${#fields} != 3 )) || [[ ! "${fields[1]}" =~ '^(verbatim|subset|extract|adapted|asset|asset-adapted|mention)$' ]] \
     || [[ "${fields[1]}" == mention && "${fields[3]}" != - ]] || [[ "${fields[1]}" != mention && "${fields[3]}" == - ]]; then
    echo "  MANIFEST   line $lineno: '$mline' (want '<kind> <copy path> <source path>', source '-' for a mention)"
    rc=1; continue
  fi
  if (( ${+m_kind[${fields[2]}]} )); then
    echo "  MANIFEST   line $lineno: ${fields[2]} is listed twice"; rc=1; continue
  fi
  m_kind[${fields[2]}]=${fields[1]}; m_src[${fields[2]}]=${fields[3]}; order+=("${fields[2]}")
done < "$MANIFEST"

# ---- the header of one file: OK <p> <e> <marker> <commit> <source> <kind> <keeps> (tab-separated), or BAD <why> ----
parse_header() {  # <file>
  awk -v tag="$TAG" '
    function bad(why) { print "BAD\t" why; exit }
    { line[NR] = $0
      if (index($0, tag) && !p) p = NR
      if ($0 ~ /^[[:space:]]*(\/\/|#)[[:space:]]*PROVENANCE:[[:space:]]*mac4DSTEM[[:space:]]+[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/) looks++ }
    END {
      if (looks > 1) bad(looks " lines look like a header; want exactly one")
      if (p == 2) { if (line[1] !~ /^#!/ && line[1] != "---") bad("the header is on line 2 but line 1 is not a #! shebang or ---") }
      else if (p != 1) bad("the header is on line " p "; want line 1, or line 2 after a #! shebang or ---")
      h = line[p]
      if (substr(h, 1, 3) == "// ") mk = "//"; else if (substr(h, 1, 2) == "# ") mk = "#"; else bad("the header does not start with // or #")
      n = split(h, f, " ")
      if (n != 6 || h != mk " " tag " " f[4] " " f[5] " " f[6] || length(f[4]) != 40 || f[4] ~ /[^0-9a-f]/ \
          || f[6] !~ /^(verbatim|subset|extract|adapted)$/)
        bad("want exactly \"" mk " " tag " <40-hex commit> <source path> <verbatim|subset|extract|adapted>\"")
      kind = f[6]; keeps = ""; nk = 0
      for (i = p + 1; i <= NR; i++) {
        if (line[i] == mk " END PROVENANCE") { e = i; break }
        if (substr(line[i], 1, length(mk)) != mk) bad("line " i " is inside the header block but is not a " mk " comment")
        if (index(line[i], mk " KEEPS:") == 1) { nk++; keeps = substr(line[i], length(mk " KEEPS:") + 1) }
      }
      if (!e) bad("no \"" mk " END PROVENANCE\" line closes the header")
      if (kind == "subset" && nk != 1) bad("a subset names its source lines on exactly one \"" mk " KEEPS: <ranges>\" header line (found " nk ")")
      if (kind != "subset" && nk != 0) bad("only a subset carries a KEEPS line")
      if (kind == "subset") {
        sub(/^ +/, "", keeps); r = split(keeps, part, ", "); last = 0; norm = ""
        for (i = 1; i <= r; i++) {
          if (part[i] !~ /^[1-9][0-9]*(-[1-9][0-9]*)?$/) bad("KEEPS: \"" part[i] "\" is not N or N-M (ranges separated by \", \")")
          split(part[i], ab, "-"); a = ab[1] + 0; b = (2 in ab) ? ab[2] + 0 : a
          if (b < a || a <= last) bad("KEEPS: the ranges must ascend and not overlap (at \"" part[i] "\")")
          last = b; norm = norm (norm == "" ? "" : ",") a "-" b
        }
        keeps = norm
      } else keeps = "-"
      if (kind != "adapted") {
        body = 0
        for (i = e + 1; i <= NR; i++) if (line[i] !~ /^[[:space:]]*$/) { body = 1; break }
        if (!body) bad("the body after END PROVENANCE is empty")
      }
      print "OK\t" p "\t" e "\t" mk "\t" f[4] "\t" f[5] "\t" kind "\t" keeps
    }' "$1"
}

# ---- the normalisations (see the header comment) --------------------------------------------------------------------
normalise() {     # the source side: all four
  sed -E 's/[[:<:]]DSTEMCore[[:>:]]/TEMCore/g; s/[[:<:]]DSTEMSession[[:>:]]/TEMSession/g;
          s/^@testable import mac4DSTEM$/@testable import macTEM/;
          s/^final class ([A-Za-z0-9_]+): XCTestCase/nonisolated final class \1: XCTestCase/;
          s/^([[:space:]]*)@MainActor (func test[A-Za-z0-9_]*\()/\1\2/'
}
normalise_copy() { # the copy side: the fourth only
  sed -E 's/^([[:space:]]*)@MainActor (func test[A-Za-z0-9_]*\()/\1\2/'
}

# subset: exactly the KEEPS lines of the source, in order, line for line; a DEVIATION line stands in for its line.
is_subset() {   # <keeps> <marker> <source> <body>
  awk -v keeps="$1" -v mk="$2" '
    NR == FNR { src[++n] = $0; next }
    { body[++m] = $0 }
    END {
      k = split(keeps, r, ",")
      for (i = 1; i <= k; i++) {
        split(r[i], ab, "-"); a = ab[1] + 0; b = ab[2] + 0
        if (b > n) { print "    KEEPS names source line " b "; the source has " n " lines"; exit 1 }
        for (j = a; j <= b; j++) { want[++x] = src[j]; at[x] = j }
      }
      dev = "[[:space:]]" mk "[[:space:]]*DEVIATION:"; comment = "^[[:space:]]*" mk
      for (i = 1; i <= (x < m ? x : m); i++) {
        if (body[i] == want[i]) continue
        if (body[i] ~ dev && body[i] !~ comment) { print "    DEVIATION body line " i " stands in for source line " at[i] > "/dev/stderr"; continue }
        print "    body line " i " is not source line " at[i] ":"; print "      source: " want[i]; print "      copy:   " body[i]; exit 1
      }
      if (m != x) { print "    the body has " m " lines; KEEPS names " x " source lines"; exit 1 }
    }' "$3" "$4"
}

# extract: each block between comment-only EXTRACT-GAP lines is a contiguous run of the source, blocks in order.
# Blank lines and plain `import <Module>` lines are ignored on both sides (an extract may need its own import).
is_extract() {  # <marker> <source> <body>
  awk -v mk="$1" '
    function keep(s) { return s !~ /^[[:space:]]*$/ && s !~ imp }
    BEGIN { b = 0   # numeric from the start: an unset b keys blocks under "" and the check below sees none
            gap = "^[[:space:]]*" mk ".*EXTRACT-GAP"
            imp = "^[[:space:]]*import[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*(" mk ".*)?$" }
    NR == FNR { if (keep($0)) src[++n] = $0; next }
    $0 ~ gap { if (len[b] > 0) b++; next }
    keep($0) { len[b]++; blk[b, len[b]] = $0 }
    END {
      if (len[0] == 0 && b == 0) { print "    the extract has no lines to check"; exit 1 }
      pos = 1
      for (k = 0; k <= b; k++) {
        if (len[k] == 0) continue
        hit = 0
        for (s = pos; s + len[k] - 1 <= n; s++) {
          ok = 1
          for (j = 1; j <= len[k]; j++) if (src[s + j - 1] != blk[k, j]) { ok = 0; break }
          if (ok) { hit = s; break }
        }
        if (!hit) { print "    block " k + 1 " (" len[k] " lines, from: " blk[k, 1] ") is not a contiguous run of the source"; exit 1 }
        pos = hit + len[k]
      }
    }' "$2" "$3"
}

matches() {     # <kind> <keeps> <marker> <source> <body>
  case "$1" in
    verbatim) cmp -s "$4" "$5" ;;
    subset) is_subset "$2" "$3" "$4" "$5" ;;
    extract) is_extract "$3" "$4" "$5" ;;
    adapted) cmp -s "$4" "$5" ;;
  esac
}

# ---- static: every header, the manifest equality, one pin --------------------------------------------------------
typeset -A h_ok h_p h_e h_mk h_commit h_kind h_keeps
pins=()
for f in ${(ko)found_set}; do
  if (( ! ${+m_kind[$f]} )); then
    echo "  UNLISTED   $f  (contains '$TAG' but is not in tools/lib/copies.manifest)"; rc=1; continue
  fi
  case "${m_kind[$f]}" in
    mention)   # names the format; a header that names a commit is a copy, whatever the manifest calls it
      if grep -qE '^[[:space:]]*(//|#)[[:space:]]*PROVENANCE:[[:space:]]*mac4DSTEM[[:space:]]+[0-9a-f]{7,}' "$ROOT/$f"; then
        echo "  MISLABELLED $f  (listed as a mention but carries a header naming a commit)"; rc=1
      fi
      continue ;;
    asset|asset-adapted) echo "  MALFORMED  $f  (listed as ${m_kind[$f]}, which carries no header, but contains '$TAG')"; rc=1; continue ;;
  esac
  hdr="$(parse_header "$ROOT/$f")"
  if [[ "$hdr" != OK$'\t'* ]]; then
    echo "  MALFORMED  $f  (${hdr#BAD$'\t'})"; rc=1; continue
  fi
  hf=("${(@ps:\t:)hdr}")
  if [[ "${hf[7]}" != "${m_kind[$f]}" || "${hf[6]}" != "${m_src[$f]}" ]]; then
    echo "  MISLABELLED $f  (header: ${hf[7]} ${hf[6]}; manifest: ${m_kind[$f]} ${m_src[$f]})"; rc=1; continue
  fi
  h_ok[$f]=1; h_p[$f]=${hf[2]}; h_e[$f]=${hf[3]}; h_mk[$f]=${hf[4]}; h_commit[$f]=${hf[5]}; h_kind[$f]=${hf[7]}
  h_keeps[$f]=${hf[8]}
  pins+=("${hf[5]}")
done
for f in $order; do
  case "${m_kind[$f]}" in
    asset|asset-adapted)
      (( ${+present_set[$f]} )) || { echo "  MISSING    $f  (listed as ${m_kind[$f]}; not a file git lists here)"; rc=1; } ;;
    mention)
      (( ${+found_set[$f]} )) || { echo "  MISSING    $f  (listed as a mention; no such file, or it no longer contains '$TAG')"; rc=1; } ;;
    *)
      (( ${+found_set[$f]} )) || { echo "  MISSING    $f  (listed as ${m_kind[$f]}; no such file, or it carries no header)"; rc=1; } ;;
  esac
done
distinct=(${(u)pins})
if (( ${#distinct} > 1 )); then
  echo "  MIXED PINS: the copies name ${#distinct} commits (${(j:, :)distinct}); re-sync all of them to one"
  rc=1
fi
pin="${distinct[1]:-}"
n_copy=0; n_asset=0; n_mention=0
for f in $order; do
  case "${m_kind[$f]}" in mention) n_mention=$(( n_mention + 1 )) ;; asset|asset-adapted) n_asset=$(( n_asset + 1 )) ;; *) n_copy=$(( n_copy + 1 )) ;; esac
done

if (( STATIC )); then
  echo "copies $n_copy, assets $n_asset, mentions $n_mention (pinned at ${pin[1,12]:-none}); static: headers, pin, kinds and tools/lib/copies.manifest — bodies not compared"
  exit $rc
fi

# ---- bodies: against the source at the pin, and the source's movement on main ------------------------------------
[[ -e "$UP/.git" ]] || { echo "check-shared-drift: no mac4DSTEM checkout at $UP (set MAC4DSTEM_REPO, or run --static)" >&2; exit 1; }
upgit() { git --no-optional-locks -C "$UP" "$@"; }
main_sha="$(upgit rev-parse --verify --quiet 'main^{commit}')" || { echo "check-shared-drift: $UP has no main" >&2; exit 1; }
[[ -n "$pin" ]] || { echo "check-shared-drift: no copy names a pin" >&2; exit 1; }
echo "mac4DSTEM main = ${main_sha[1,12]} ($UP); pin = ${pin[1,12]}"
printf "  %-13s %-9s %-11s %s\n" "kind" "local" "upstream" "copy  <-  source"

local_n=0; up_n=0
for f in $order; do
  kind="${m_kind[$f]}"; src="${m_src[$f]}"
  [[ "$kind" == mention ]] && continue
  key="${f//\//_}"
  if [[ "$kind" == asset || "$kind" == asset-adapted ]]; then
    [[ -f "$ROOT/$f" ]] || continue                      # reported MISSING above
    if ! upgit cat-file -e "$pin:$src" 2>/dev/null || ! upgit show "$pin:$src" > "$WORK/$key.base" 2>/dev/null; then
      echo "  UNRESOLVED $f  ($src at ${pin[1,12]} is not in $UP)"; rc=1; continue
    fi
    cp "$ROOT/$f" "$WORK/$key.body"
    if cmp -s "$WORK/$key.base" "$WORK/$key.body"; then local_state="matches"
    elif [[ "$kind" == asset-adapted ]]; then
      local_state="$( { diff "$WORK/$key.base" "$WORK/$key.body" || true; } | grep -cE '^[<>]' || true)L"; local_n=$(( local_n + 1 ))
    else local_state="BROKEN"; rc=1
    fi
    if upgit cat-file -e "main:$src" 2>/dev/null && upgit show "main:$src" > "$WORK/$key.main" 2>/dev/null; then
      cmp -s "$WORK/$key.base" "$WORK/$key.main" && up_state="same" || up_state="MOVED"
    else up_state="GONE"
    fi
  else
    (( ${+h_ok[$f]} )) || continue                        # MALFORMED, MISLABELLED or MISSING above
    p=${h_p[$f]}; e=${h_e[$f]}; mk=${h_mk[$f]}; commit=${h_commit[$f]}
    if ! upgit cat-file -e "$commit:$src" 2>/dev/null || ! upgit show "$commit:$src" 2>/dev/null | normalise > "$WORK/$key.base"; then
      echo "  UNRESOLVED $f  ($src at ${commit[1,12]} is not in $UP)"; rc=1; continue
    fi
    # The compared text: line 1 when the header sits on line 2 (a shebang or ---), then everything after END.
    awk -v p="$p" -v e="$e" '(p == 2 && NR == 1) || NR > e' "$ROOT/$f" | normalise_copy > "$WORK/$key.body"
    if matches "$kind" "${h_keeps[$f]}" "$mk" "$WORK/$key.base" "$WORK/$key.body" > "$WORK/$key.why" 2> "$WORK/$key.dev"; then
      local_state="matches"
    elif [[ "$kind" == adapted ]]; then
      local_state="$( { diff "$WORK/$key.base" "$WORK/$key.body" || true; } | grep -cE '^[<>]' || true)L"
      local_n=$(( local_n + 1 ))
    else
      local_state="BROKEN"; rc=1
    fi
    if ! upgit cat-file -e "main:$src" 2>/dev/null || ! upgit show "main:$src" 2>/dev/null | normalise > "$WORK/$key.main"; then
      up_state="GONE"
    elif [[ "$kind" == extract && "$local_state" == matches ]]; then   # a broken extract says nothing about main
      matches extract - "$mk" "$WORK/$key.main" "$WORK/$key.body" > /dev/null 2>&1 && up_state="same" || up_state="MOVED"
    else
      cmp -s "$WORK/$key.base" "$WORK/$key.main" && up_state="same" || up_state="MOVED"
    fi
  fi
  [[ "$up_state" != same ]] && up_n=$(( up_n + 1 ))
  printf "  %-13s %-9s %-11s %s  <-  %s\n" "$kind" "$local_state" "$up_state" "$f" "$src"
  if [[ "$local_state" == BROKEN ]]; then cat "$WORK/$key.why" 2>/dev/null || true; fi
  if (( SHOW_DIFF )); then
    [[ -s "$WORK/$key.dev" ]] && cat "$WORK/$key.dev"
    if [[ "$kind" == adapted || "$kind" == asset-adapted || "$local_state" == BROKEN ]]; then
      echo "  --- $f against $src@${pin[1,12]}"; diff -u "$WORK/$key.base" "$WORK/$key.body" | sed 's/^/    /' || true
    fi
    if [[ "$up_state" == MOVED ]]; then
      echo "  --- upstream since the pin ($src: ${pin[1,12]} -> main)"; diff -u "$WORK/$key.base" "$WORK/$key.main" | sed 's/^/    /' || true
    fi
  fi
done

echo "copies $n_copy, assets $n_asset, mentions $n_mention (pinned at ${pin[1,12]}); adapted with local changes $local_n; upstream moved $up_n"
exit $rc
