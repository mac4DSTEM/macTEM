"""tools/parity/sem/writer_cases.py — milestone 8 bundles: crystal maps written as EDAX TSL .ang (orix 0.15.0's
`orix.io.plugins.ang.file_writer`) and Oxford .ctf (`ctf_writer.py`, orix writes none), and figure F18, the round trip:
each written file read back by orix's readers equals the original map to the written precision. `emit.py` collects the
`case_` functions.

Maps: orix-data's two-phase `sdss_ferrite_austenite.ang` (100 x 117, fetched; the Swift test reads its committed copy), its ferrite points
alone (a masked map: the austenite points are written as not indexed) and its rows 10-19, columns 5-14 (a window), and
the first three rows (3 x 507) of orix-data's Ti orientations (622, `fixtures/orientation_inputs.json`, 0.25 um grid).

A bundle holds the written file's exact fingerprint (sha256 of its bytes as uint8), its line count, its header and every
50th data line as text (for a readable failure), and what orix reads back: shape, steps, phase names and ids, and the
largest deviation of every column from the original. The Swift test writes the same map and compares the bytes.
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import numpy as np

from refbundle import Bundle

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
SDSS_LABEL = "sem-data/orix/sdss_ferrite_austenite.ang"  # the same bytes as macTEMTests/Fixtures/ebsd-sdss-ferrite-austenite.ang
ORIENTATION_INPUTS = FIXTURES / "orientation_inputs.json"
TI_COLUMNS, TI_ROWS = 507, 3
SAMPLE_EVERY = 50


def _sdss(path: Path):
    from orix import io

    return io.load(str(path))


def _ti():
    from diffpy.structure import Lattice, Structure
    from orix.crystal_map import CrystalMap, Phase, PhaseList, create_coordinate_arrays
    from orix.quaternion import Rotation

    inp = json.loads(ORIENTATION_INPUTS.read_text())
    eu = np.asarray(inp["ti_euler_degrees"], dtype=np.float64)[: TI_ROWS * TI_COLUMNS]
    d, n = create_coordinate_arrays((TI_ROWS, TI_COLUMNS), (0.25, 0.25))
    ti = Phase("Ti", space_group=194, structure=Structure(lattice=Lattice(2.95, 2.95, 4.68, 90, 90, 120)))
    return CrystalMap(Rotation.from_euler(eu, degrees=True), phase_id=np.ones(n, dtype=int), x=d["x"], y=d["y"],
                      phase_list=PhaseList({1: ti}), scan_unit="um")


def _map(ctx, key: str, case: str):
    """The map of `key`, its input and label; None (the case skipped) when the sdss dataset is not fetched."""
    if key == "ti":
        return _ti(), ORIENTATION_INPUTS, "fixtures/orientation_inputs.json"
    path = ctx.data / "orix" / "sdss_ferrite_austenite.ang"
    if not ctx.have(path, case):
        return None
    sdss = _sdss(path)
    if key == "sdss-ferrite":
        sdss = sdss[sdss.phases.names[1]]
    elif key == "sdss-window":
        sdss = sdss[10:20, 5:15]
    return sdss, path, SDSS_LABEL


def _text_values(b: Bundle, text: str, header_prefix: str | None) -> None:
    data = text.encode("utf-8")
    b.fingerprint("file_bytes", np.frombuffer(data, dtype=np.uint8))
    b.value("byte_count", len(data))
    lines = text.split("\n")
    assert lines[-1] == "", "the file ends with a newline"
    lines = lines[:-1]
    b.value("line_count", len(lines))
    if header_prefix is not None:  # .ang: every header line starts with "#"
        header = [ln for ln in lines if ln.startswith(header_prefix)]
    else:  # .ctf: up to and including the column line
        header = lines[: next(i for i, ln in enumerate(lines) if ln.startswith("Phase\tX\tY")) + 1]
    b.value("header_lines", header)
    first = len(header)
    sample = {str(i): lines[i] for i in list(range(first, len(lines), SAMPLE_EVERY)) + [len(lines) - 1]}
    b.value("data_line_sample", sample)


def _round_trip(b: Bundle, original, back, euler_decimals_rad: float) -> None:
    """What orix reads back, beside the original: the deviations F18 bounds."""
    b.value("read_back", {
        "shape": list(back.shape), "dx": float(back.dx), "dy": float(back.dy),
        "phase_ids": [int(i) for i in back.phases.ids], "phase_names": list(back.phases.names),
        "point_groups": [pg.name if pg is not None else None for pg in back.phases.point_groups],
        "indexed": int(np.count_nonzero(back.is_indexed)), "properties": list(back.prop.keys()),
    })
    size = int(np.prod(back.shape))
    indexed = original.get_map_data(original.is_indexed, fill_value=False).reshape(size).astype(bool)
    o = original.get_map_data("rotations", fill_value=0).reshape(size, 3)
    r = back.get_map_data("rotations", fill_value=0).reshape(size, 3)
    from orix.quaternion import Rotation

    angle = Rotation.from_euler(o[indexed]).angle_with(Rotation.from_euler(r[indexed]))
    b.scalar("round_trip_max_rotation_angle_rad", float(angle.max()) if angle.size else 0.0, atol=1e-12)
    assert angle.size == 0 or angle.max() < euler_decimals_rad * 4, "orix reads back the rotations to the written precision"
    assert np.array_equal(back.get_map_data(back.is_indexed, fill_value=False).reshape(size).astype(bool), indexed), \
        "orix reads back the same indexed points"
    if original.ndim == 2 and back.ndim == 2:
        assert list(back.shape) == list(original.shape)


def _ang_bundle(ctx, key: str) -> None:
    from orix import io

    case = f"m8/write-ang-{key}"
    found = _map(ctx, key, case)
    if found is None:
        return
    xmap, path, label = found
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "map.ang"
        io.save(str(out), xmap)
        text = out.read_text(encoding="utf-8")
        back = io.load(str(out))
    b = Bundle(case, 8, "orix", "orix.io.plugins.ang.file_writer (orix.io.save), read back by orix.io.load", ctx.out)
    b.input(path, label)
    _text_values(b, text, "#")
    _round_trip(b, xmap, back, 0.5e-5)
    b.write()
    ctx.done(case)


def _ctf_bundle(ctx, key: str) -> None:
    from orix import io

    from ctf_writer import ctf_text

    case = f"m8/write-ctf-{key}"
    found = _map(ctx, key, case)
    if found is None:
        return
    xmap, path, label = found
    text = ctf_text(xmap, project=key, author="macTEM")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "map.ctf"
        out.write_text(text, encoding="utf-8", newline="\n")
        back = io.load(str(out))
    b = Bundle(case, 8, "orix", "tools/parity/sem/ctf_writer.py (Oxford layout), read back by orix.io.plugins.ctf.file_reader",
               ctx.out)
    b.input(path, label)
    _text_values(b, text, None)
    _round_trip(b, xmap, back, np.deg2rad(0.5e-4))
    b.write()
    ctx.done(case)


def case_m8_write_ang_sdss(ctx):
    _ang_bundle(ctx, "sdss")


def case_m8_write_ang_sdss_ferrite(ctx):
    _ang_bundle(ctx, "sdss-ferrite")


def case_m8_write_ang_sdss_window(ctx):
    _ang_bundle(ctx, "sdss-window")


def case_m8_write_ang_ti(ctx):
    _ang_bundle(ctx, "ti")


def case_m8_write_ctf_sdss(ctx):
    _ctf_bundle(ctx, "sdss")


def case_m8_write_ctf_sdss_ferrite(ctx):
    _ctf_bundle(ctx, "sdss-ferrite")


def case_m8_write_ctf_sdss_window(ctx):
    _ctf_bundle(ctx, "sdss-window")


def case_m8_write_ctf_ti(ctx):
    _ctf_bundle(ctx, "ti")
