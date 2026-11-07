#!/usr/bin/env python3
# The reference of macTEM's Tescan TIFF reader (SEMImageMetadata.tescan): what NexusLIMS's `tescan_tif` extractor makes of the
# embedded header (tag 50431) of NexusLIMS's own Tescan test file. Writes the tag's bytes (tescan-pfib_dataZeroed.50431.bin)
# and the parsed sections (tescan-reference.json) into the fixtures dir, for SEMImageMetadataTests.
#
# The five steps are NexusLIMS's `TescanTiffExtractor._extract_embedded_hdr` pipeline, transcribed from
# nexusLIMS/extractors/plugins/tescan_tif.py (MIT licence, Datasophos): `_extract_metadata_string` (from the first of five
# keys, NULs dropped, UTF-8 ignoring errors), `_clean_metadata_string` (printable ASCII and \n \r \t), `_add_section_headers_
# if_needed` ([MAIN] first, [SEM] from the line of the earliest SEM key), `_parse_hdr_string` (configparser, keys as written).
# Pinned by content: tescan_tif.py sha256 below, test archive tests/unit/files/tescan-pfib_dataZeroed.tar.gz sha256 below
# (fetched from github.com/datasophos/NexusLIMS, main, 2026-11-07). NexusLIMS's own test (tests/unit/test_extractors/
# test_tescan_tif.py, `_assert_tescan_raw_sections`) asserts the same raw values on this file.
#
# Usage: tescan_reference.py <tescan-pfib_dataZeroed.tif> <fixtures dir>
import configparser, io, json, pathlib, sys, hashlib
import tifffile

EXTRACTOR_SHA256 = "f29d59ad696ed256c07e17421746b511d0e39c1661069160549cf71f01715f67"  # NexusLIMS tescan_tif.py, main, fetched 2026-11-07
ARCHIVE_SHA256 = "a4859def00ce79f14650a87fe775ebf469e1b57c63801036387d0a19998adfba"  # tests/unit/files/tescan-pfib_dataZeroed.tar.gz
SEARCH_KEYS = [b"[MAIN]", b"AccFrames=", b"AccType=", b"Company=", b"Date="]
SEM_KEYS = ["AcceleratorVoltage=", "ApertureDiameter=", "ApertureOptimization=", "ChamberPressure=", "CrossFree=", "HV="]


def extract_metadata_string(b: bytes) -> str:
    for key in SEARCH_KEYS:
        pos = b.find(key)
        if pos >= 0:
            return b[pos:].replace(b"\x00", b"").decode("utf-8", errors="ignore")
    return b.replace(b"\x00", b"").decode("utf-8", errors="ignore")


def clean_metadata_string(s: str) -> str:
    return "".join(c for c in s if ord(c) < 128 and (c.isprintable() or c in "\n\r\t"))


def add_section_headers_if_needed(s: str) -> str:
    if "[MAIN]" in s or "[SEM]" in s:
        return s
    start = len(s)
    for key in SEM_KEYS:
        pos = s.find(key)
        if 0 <= pos < start:
            start = pos
    if start < len(s):
        line = s.rfind("\n", 0, start)
        line = 0 if line < 0 else line + 1
        return "[MAIN]\n" + s[:line] + "[SEM]\n" + s[line:]
    return "[MAIN]\n" + s


def parse_hdr_string(s: str) -> dict:
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    config = configparser.ConfigParser()
    config.optionxform = lambda option: option
    config.read_file(io.StringIO(s))
    return {section: dict(config.items(section)) for section in config.sections()}


def main(tif: str, out: str) -> None:
    with tifffile.TiffFile(tif) as t:
        page = t.pages[0]
        raw = page.tags[50431].value
        height, width = page.shape[:2]
    sections = parse_hdr_string(add_section_headers_if_needed(clean_metadata_string(extract_metadata_string(raw))))
    out = pathlib.Path(out)
    (out / "tescan-pfib_dataZeroed.50431.bin").write_bytes(raw)
    (out / "tescan-reference.json").write_text(json.dumps({
        "file": pathlib.Path(tif).name, "width": width, "height": height, "tag": 50431,
        "tagBytes": "tescan-pfib_dataZeroed.50431.bin", "tagSha256": hashlib.sha256(raw).hexdigest(),
        "sections": sections,
        "versions": {"tifffile": tifffile.__version__, "python": sys.version.split()[0]},
    }, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
