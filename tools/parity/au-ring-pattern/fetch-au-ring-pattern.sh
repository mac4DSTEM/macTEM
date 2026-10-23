#!/bin/zsh
# Fetch the two HDF5 members of Zenodo 8354219 "Gold thin film.zip" (CC-BY-4.0) into the gitignored References/ by HTTP
# range (the zip's central directory locates them; the other 1.2 GB are never downloaded), and verify their sha256.
# A member already present with the right sha256 is not downloaded again. Downloaded bytes are untrusted data: this
# script only writes them and hashes them; tools/parity/au-ring-pattern/zip_range.py (standard library) does the ranges.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/References/ring-calibration/zenodo-8354219-au-thin-film-arina"
URL="https://zenodo.org/api/records/8354219/files/Gold%20thin%20film.zip/content"
MASTER_SHA="4ae8b2a424f4e373ec16350f9219ee9aeca1ea2aaa681d047a490886b73e0de7"
DATA_SHA="b327c17206d0ed84bf6a2cfbaf33a425e7347fddc56b5af2a4e87e948cf892e3"
PY="${PYTHON:-$ROOT/References/python-venv/bin/python}"   # any python3 works: the helper is standard-library only
[[ -x "$PY" ]] || PY="$(command -v python3)"

mkdir -p "$DEST"
fetch_member() {  # <member name> <sha256>
  local name=$1 want=$2 file="$DEST/$1" have="" tmp
  [[ ! -f "$file" ]] || have="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [[ "$have" == "$want" ]]; then
    echo "fetch-au-ring-pattern: $name present, sha256 matches"; return 0
  fi
  echo "fetch-au-ring-pattern: fetching $name by range from Zenodo 8354219" >&2
  tmp="$file.part"
  "$PY" -I "$ROOT/tools/parity/au-ring-pattern/zip_range.py" extract "$URL" "$name" "$tmp"   # also checks the zip's crc32
  have="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  if [[ "$have" != "$want" ]]; then
    rm -f "$tmp"
    echo "fetch-au-ring-pattern: REFUSED — $name has sha256 $have, expected $want." >&2
    return 1
  fi
  mv "$tmp" "$file"
  echo "fetch-au-ring-pattern: $name verified"
}

fetch_member Au_000_master.h5 "$MASTER_SHA"
fetch_member Au_000_data_000001.h5 "$DATA_SHA"
