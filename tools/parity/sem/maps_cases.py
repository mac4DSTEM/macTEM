"""tools/parity/sem/maps_cases.py — the Maps room's maps (milestone 3, brief P3-04, figure F6 on screen).

orix 0.15.0 draws an orientation map with `CrystalMap.plot`: the per-point colours laid into the map's rows and columns by
`CrystalMap.get_map_data`. The Maps room draws the same picture, so the bundle holds what orix's plot is made of on
orix-data's two-phase steel (sdss_ferrite_austenite.ang, 100 x 117): the IPF colours along the sample's x, y and z
(`IPFColorKeyTSL(point_group, direction)` per phase, `orientation2color` of that phase's orientations) and the phase
colours (`Phase.color_rgb` per point, the not-indexed phase white), each as a (rows, columns, 3) map image. emit.py
imports every `case_` function here; the file is apart from emit.py so threads adding cases do not collide.

Tolerances: colours atol 1e-6 (the IPF key's own tolerance, docs/parity.md); the phase colours and the image layout exact.
"""

from __future__ import annotations

import numpy as np

from refbundle import Bundle

EXACT = {"rtol": 0.0, "atol": 0.0}
RGB = {"rtol": 0.0, "atol": 1e-6}

AXES = (("x", (1, 0, 0)), ("y", (0, 1, 0)), ("z", (0, 0, 1)))


def case_m3_maps_room_sdss(ctx):
    """The IPF-X, IPF-Y, IPF-Z and phase map images of the two-phase steel as `CrystalMap.plot` draws them."""
    from orix import io
    from orix.plot import IPFColorKeyTSL
    from orix.vector import Vector3d

    p = ctx.data / "orix" / "sdss_ferrite_austenite.ang"
    case = "m3/maps-room-sdss"
    if not ctx.have(p, case):
        return
    xm = io.load(str(p))
    b = Bundle(case, 3, "orix", "orix.plot.IPFColorKeyTSL.orientation2color per phase, Phase.color_rgb, "
               "CrystalMap.get_map_data", ctx.out)
    b.input(p, "sem-data/orix/sdss_ferrite_austenite.ang")
    b.value("shape", [int(n) for n in xm.shape])
    b.value("phases", {str(int(k)): {"name": ph.name, "point_group": ph.point_group.name if ph.point_group else None,
                                    "color": ph.color} for k, ph in xm.phases})
    for axis, vec in AXES:
        rgb = np.zeros((xm.size, 3))
        for k, ph in xm.phases:
            if k == -1 or ph.point_group is None:
                continue
            mask = xm.phase_id == k
            rgb[mask] = IPFColorKeyTSL(ph.point_group, direction=Vector3d(vec)).orientation2color(xm[mask].orientations)
        b.array(f"ipf_{axis}_image", np.asarray(xm.get_map_data(rgb), dtype=np.float64), **RGB,
                note=f"(rows, columns, 3): the IPF-{axis.upper()} map as CrystalMap.plot draws it")
    phase_rgb = np.zeros((xm.size, 3))
    for k, ph in xm.phases:
        phase_rgb[xm.phase_id == k] = ph.color_rgb
    b.array("phase_image", np.asarray(xm.get_map_data(phase_rgb), dtype=np.float64), **EXACT,
            note="(rows, columns, 3): each point the colour of its phase (Phase.color_rgb)")
    b.write()
    ctx.done(case)
