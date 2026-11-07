#!/usr/bin/env python3
# The references of macTEM's SEM TIFF metadata reader (Sources/TEMCore/SEM/SEMImageMetadata.swift): what RosettaSciIO's
# TIFF reader (rsciio.tiff, `_axes_fei`, `_axes_zeiss`, `mapping_fei`, `mapping_cz_sem`) and tifffile (`read_fei_metadata`,
# `read_cz_sem`) make of RosettaSciIO's SEM test files. Writes, for the unit tests (SEMImageMetadataTests), the reference
# (macTEMTests/Fixtures/sem-tiff/sem-tiff-reference.json) and the vendor tag's bytes of each file (<name>.<tag>.bin beside
# it), so the tests run on CI without the files; the reference records the versions that wrote it.
#
# Usage: reference.py <dir with the test TIFFs> <fixtures dir>
# Pinned: rosettasciio 0.15.0, tifffile 2026.9.20 (tools/parity/sem). The test files are RosettaSciIO's
# rsciio/tests/data/tiff/tiff_FEI_Helios.zip and tiff_Zeiss_SEM.zip (GPL-3.0-or-later).
import json, sys, importlib.metadata, pathlib
import tifffile
from rsciio.tiff._api import file_reader, get_metadata_mapping

FILES = ["FEI-Helios-Ebeam-8bits.tif", "FEI-Helios-Ebeam-16bits.tif", "FEI-Helios-navcam.tif",
         "FEI-Helios-navcam-with-no-IRBeam.tif", "FEI-Helios-navcam-with-no-IRBeam-bad-floats.tif",
         "test_tiff_Zeiss_SEM_1k.tif", "test_tiff_Zeiss_SEM_512pix.tif", "ZEISS_SEM_multipage.tif"]

def lookup(d, dotted):
    for part in dotted.split("."):
        if not isinstance(d, dict) or part not in d:
            return None
        d = d[part]
    return d

def mapped_metadata(page, om):
    out = {}
    for src, (dst, fn) in get_metadata_mapping(page, om).items():
        v = lookup(om, src)
        if v is None:
            continue
        if fn is not None:
            try:
                v = fn(v)
            except Exception as e:  # the mapping raises on a value it cannot parse (navcam bad floats: stage z "")
                out[dst] = {"error": type(e).__name__}
                continue
        if v is None:
            continue
        out[dst] = v
    return out

def main(src, fixtures):
    src, fixtures = pathlib.Path(src), pathlib.Path(fixtures)
    fixtures.mkdir(parents=True, exist_ok=True)
    ref = {"rosettasciio": importlib.metadata.version("rosettasciio"), "tifffile": tifffile.__version__, "files": {}}
    for name in FILES:
        path = src / name
        d = file_reader(str(path))[0]
        t = tifffile.TiffFile(str(path))
        page = t.pages[0]
        om = d["original_metadata"]
        vendor = "fei" if page.is_fei else "zeiss" if page.is_sem else "none"
        tag = 34682 if 34682 in page.tags else 34680 if 34680 in page.tags else 34118 if 34118 in page.tags else None
        entry = {
            "vendor": vendor, "tag": tag, "width": int(page.imagewidth), "height": int(page.imagelength), "pages": len(t.pages),
            "axes": [{"name": a["name"], "scale": a["scale"], "offset": a["offset"], "units": a["units"], "size": a["size"]} for a in d["axes"]],
            "metadata": mapped_metadata(page, om),
        }
        if vendor == "fei":
            fei = t.fei_metadata
            entry["fei"] = {"DatabarHeight": lookup(fei, "PrivateFei.DatabarHeight"), "ResolutionX": lookup(fei, "Image.ResolutionX"),
                            "ResolutionY": lookup(fei, "Image.ResolutionY"), "Spot": lookup(fei, "Beam.Spot"),
                            "ChPressure": lookup(fei, "Vacuum.ChPressure"), "DetectorName": lookup(fei, "Detectors.Name"),
                            "DetectorMode": lookup(fei, "Detectors.Mode"), "sections": sorted(fei.keys())}
        if vendor == "zeiss":
            cz = t.sem_metadata
            entry["zeiss"] = {"unnamed": list(cz[""]), "keys": len(cz),
                              "ap_spotsize": cz.get("ap_spotsize"), "ap_chamber_pressure": cz.get("ap_chamber_pressure"),
                              "ap_pixel_size": cz.get("ap_pixel_size"), "ap_image_pixel_size": cz.get("ap_image_pixel_size"),
                              "ap_line_counter": cz.get("ap_line_counter"), "dp_image_store": cz.get("dp_image_store"),
                              "ap_width": cz.get("ap_width"), "ap_height": cz.get("ap_height")}
        if tag is not None:
            tt = page.tags[tag]
            with open(path, "rb") as fh:
                fh.seek(tt.valueoffset); raw = fh.read(tt.count)
            fixture = fixtures / f"{path.stem}.{tag}.bin"
            fixture.write_bytes(raw)
            entry["tagBytes"] = fixture.name
            entry["tagType"] = int(tt.dtype)
        ref["files"][name] = entry
    (fixtures / "sem-tiff-reference.json").write_text(json.dumps(ref, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
    print("wrote", len(ref["files"]), "references")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
