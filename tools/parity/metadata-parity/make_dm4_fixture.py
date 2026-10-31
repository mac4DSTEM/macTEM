#!/usr/bin/env python3
"""The planted-truth DM4 fixtures of the unit tests (macTEMTests/Fixtures/planted-2d.dm4 and its truth).

    make_dm4_fixture.py <fixture.dm4> <truth.json>    the committed fixture (commit both files)
    make_dm4_fixture.py --types <dir>                 one planted DM4 per pixel type, and its truth, into <dir>

Writes small DM4s whose every number is chosen, and the truth those choices are, beside each. Each choice is there
to make a specific reader error visible. The committed fixture:

- ImageList.1 is an RGBA thumbnail (as GMS writes): a reader that takes the first object reads the thumbnail.
- The image is 40 x 24, not square: a reader that swaps width and height produces the wrong shape.
- Pixel (row, col) holds row*1000 + col - 12000, int16: every value is unique, so a transpose or a row
  offset moves values, and about half are negative, so a reader that decodes int16 as unsigned is wrong.
- x and y have different scales (0.0123 and 0.0246 nm) and different, non-integer, opposite-sign origins
  (12 and -4.5 px): a reader that swaps the axes, drops the origin or flips its sign is wrong.
- Every Dimension group carries Origin, Scale and Units, the layout GMS writes (ncempy gives a dimension without
  an Origin the last Origin it read).

The Format fixtures (--types, with the per-type ones): GMS tags a spectrum image `ImageTags.Meta Data.Format`
= "Spectrum image". planted-si.dm4 holds a thumbnail and one 6 x 3 object with BOTH axes in nm and that Format (no
mixed-units clause can catch it); planted-si-then-image.dm4 the same object, then a 3 x 2 image tagged "Image";
planted-diffraction.dm4 a thumbnail and a 3 x 2 image tagged "Diffraction image". Each truth file names the tag.

The per-type fixtures (--types), one per pixel type the reader decodes: thumbnail first, then a 3 x 2 image whose
values only the right sign AND width reproduce — the type's extremes and a value outside the next narrower type's
range. Each signed type holds a negative value, each unsigned type one above its signed maximum, each float type a
non-integer, and float64 values float32 cannot hold (2^24 + 1, 0.1). Values float32 cannot hold round to float32
identically on both sides of the harness (reference.py writes ncempy's values cast to float32). Every float value
fits an Int64, so a decoder that goes through an integer fails a pixel check rather than trapping.
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # `python -I` drops the script's directory
import numpy as np  # noqa: E402
import dm4_writer  # noqa: E402
from dm4_writer import Group, image_object, write_dm4  # noqa: E402

WIDTH, HEIGHT = 40, 24
X = {"origin": 12.0, "scale": 0.0123, "units": "nm"}
Y = {"origin": -4.5, "scale": 0.0246, "units": "nm"}
VOLTAGE_V = 200000.0

# numpy dtype -> (DM DataType, writer kind, the 6 values row-major: 2 rows of 3). reference.py holds the same eight
# type names and asserts what each set of values must contain.
TYPE_WIDTH, TYPE_HEIGHT = 3, 2
PER_TYPE = {
    "uint8":   (6,  "u8",  [200, 255, 0, 1, 127, 128]),
    "int8":    (9,  "i8",  [-128, 127, -1, 0, 1, 100]),
    "int16":   (1,  "i16", [-32768, 32767, -1, 0, 1, 300]),
    "uint16":  (10, "u16", [40000, 65535, 0, 1, 32768, 300]),
    "int32":   (7,  "i32", [-2**31, 2**31 - 1, -1, 0, 1, 70000]),
    "uint32":  (11, "u32", [2**31 + 1, 4294967295, 0, 1, 2**31, 70000]),
    "float32": (2,  "f32", [-1.5e10, 1e-38, 0.1, -2.75, 3.0e18, 1.0]),
    "float64": (12, "f64", [2.0**24 + 1, -1.5e10, 0.1, -2.75, 1e-30, 1.0]),
}
TYPE_X = {"origin": 1.0, "scale": 0.1, "units": "nm"}
TYPE_Y = {"origin": -0.5, "scale": 0.2, "units": "nm"}
# dm4_writer.py (macTEM's own since 2026-10-15, kept as copied) has no int8. GMS writes int8 as DataType 9 with Data an array
# of tag type 9 and PixelDepth 1 (measured with ncempy on RosettaSciIO's digitalmicrograph/2D/test-9.dm4), so the
# int8 fixture is written as uint8 (PixelDepth 1) and retagged: DataType 9, Data tag type 9.
INT8_TAG = ("i8", (9, "<i1"))


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def axis_truth(a):
    scale32 = np.float32(a["scale"])
    return {"origin": float(np.float32(a["origin"])), "scale": float(scale32),
            "scale_f32_bits": f"0x{scale32.view(np.uint32):08x}", "units": a["units"]}


def write_truth(path, truth):
    with open(path, "w") as fh:
        json.dump(truth, fh, indent=1)
        fh.write("\n")


def gms_root(image):
    """A GMS-shaped file: the RGBA thumbnail as ImageList.1 (indexed by Thumbnails), then `image`."""
    root = Group()
    root.group("Thumbnails").group("").value("ImageIndex", "u32", 0)
    image_list = root.group("ImageList")
    image_list.add(image_object(
        name="thumbnail", dtype="rgba", dims=[8, 6], data=np.zeros(8 * 6 * 4, np.uint8),
        calibrations=[(0.0, 1.0, ""), (0.0, 1.0, "")], unique_id=[1, 2, 3, 4], image_tags=Group("ImageTags")))
    if image is not None:
        image_list.add(image)
    return root


def planted(fixture, truth_path):
    rows, cols = np.mgrid[0:HEIGHT, 0:WIDTH]
    image = (rows * 1000 + cols - 12000).astype("<i2")
    tags = Group("ImageTags")
    tags.group("Microscope Info").value("Voltage", "f64", VOLTAGE_V)
    write_dm4(fixture, gms_root(image_object(
        name="planted", dtype="i16", dims=[WIDTH, HEIGHT], data=image.reshape(-1),   # DM order: x fastest
        calibrations=[(X["origin"], X["scale"], X["units"]), (Y["origin"], Y["scale"], Y["units"])],
        unique_id=[5, 6, 7, 8], image_tags=tags)))

    digest = sha256(fixture)
    write_truth(truth_path, {
        "file_sha256": digest,
        "object_index": 2, "object_name": "planted", "dm_data_type": 1, "dtype": "int16",
        "width": WIDTH, "height": HEIGHT, "voltage_v": VOLTAGE_V,
        "x": axis_truth(X), "y": axis_truth(Y),
        "pixels_row_major": image.reshape(-1).astype(int).tolist(),
    })
    print(f"make_fixture: {fixture} ({os.path.getsize(fixture)} bytes, sha256 {digest[:16]}…) and {truth_path}")


def per_type(out):
    if INT8_TAG[0] in dm4_writer._CODES:
        sys.exit("make_fixture: dm4_writer.py now writes i8 itself — drop the int8 retag here")
    os.makedirs(out, exist_ok=True)
    for dtype, (dm_type, kind, values) in PER_TYPE.items():
        data = np.asarray(values, dtype=np.dtype(dtype).newbyteorder("<"))
        if dtype.startswith(("int", "uint")) and data.tolist() != values:
            sys.exit(f"make_fixture: {dtype} cannot hold {values}")
        is_int8 = kind == INT8_TAG[0]
        obj = image_object(
            name=f"planted-{dtype}", dtype="u8" if is_int8 else kind, dims=[TYPE_WIDTH, TYPE_HEIGHT],
            data=data.view(np.uint8) if is_int8 else data,
            calibrations=[(TYPE_X["origin"], TYPE_X["scale"], TYPE_X["units"]),
                          (TYPE_Y["origin"], TYPE_Y["scale"], TYPE_Y["units"])],
            unique_id=[5, 6, 7, 8], image_tags=Group("ImageTags"))
        path = os.path.join(out, f"planted-{dtype}.dm4")
        if is_int8:
            image_data = obj.children[0]
            [data_type] = [c for c in image_data.children if c.label == "DataType"]
            [array] = [c for c in image_data.children if c.label == "Data"]
            data_type.v, array.kind, array.a = dm_type, INT8_TAG[0], data
            dm4_writer._CODES[INT8_TAG[0]] = INT8_TAG[1]
            try:
                write_dm4(path, gms_root(obj))
            finally:
                del dm4_writer._CODES[INT8_TAG[0]]
        else:
            write_dm4(path, gms_root(obj))
        write_truth(os.path.join(out, f"planted-{dtype}.truth.json"), {
            "file_sha256": sha256(path),
            "object_index": 2, "object_name": f"planted-{dtype}", "dm_data_type": dm_type, "dtype": dtype,
            "width": TYPE_WIDTH, "height": TYPE_HEIGHT,
            "x": axis_truth(TYPE_X), "y": axis_truth(TYPE_Y),
            "pixels_row_major": data.tolist(),    # what the file holds (float32: already rounded to float32)
        })
    print(f"make_fixture: {len(PER_TYPE)} per-type fixtures ({', '.join(PER_TYPE)}) in {out}")


# The Format fixtures: (file stem, [(object name, dims, Format)]) after the thumbnail. A 3 x 2 object reads as the type fixtures do.
SI_DIMS = [6, 3]
FORMAT_CASES = {
    "planted-si": [("SI", SI_DIMS, "Spectrum image")],
    "planted-si-then-image": [("SI", SI_DIMS, "Spectrum image"), ("BF", [3, 2], "Image")],
    "planted-diffraction": [("DP", [3, 2], "Diffraction image")],
}


def format_cases(out):
    os.makedirs(out, exist_ok=True)
    for stem, objects in FORMAT_CASES.items():
        root = gms_root(None)   # the thumbnail only
        [image_list] = [c for c in root.children if c.label == "ImageList"]
        truth_objects = []
        for i, (name, dims, fmt) in enumerate(objects):
            n = dims[0] * dims[1]
            data = (np.arange(n, dtype="<i2") * (i + 3) - 7).astype("<i2")
            tags = Group("ImageTags")
            tags.group("Meta Data").string("Format", fmt)
            image_list.add(image_object(
                name=name, dtype="i16", dims=dims, data=data,
                calibrations=[(TYPE_X["origin"], TYPE_X["scale"], TYPE_X["units"]),
                              (TYPE_Y["origin"], TYPE_Y["scale"], "nm")],
                unique_id=[5, 6, 7, 8], image_tags=tags))
            truth_objects.append({"object_index": i + 2, "object_name": name, "format": fmt,
                                  "width": dims[0], "height": dims[1], "pixels_row_major": data.tolist()})
        path = os.path.join(out, f"{stem}.dm4")
        write_dm4(path, root)
        write_truth(os.path.join(out, f"{stem}.truth.json"),
                    {"file_sha256": sha256(path), "objects": truth_objects,
                     "x": axis_truth(TYPE_X), "y": axis_truth(TYPE_Y)})
    print(f"make_fixture: {len(FORMAT_CASES)} Format fixtures ({', '.join(FORMAT_CASES)}) in {out}")


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--types":
        per_type(sys.argv[2])
        format_cases(sys.argv[2])
    elif len(sys.argv) == 3 and not sys.argv[1].startswith("-"):
        planted(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
