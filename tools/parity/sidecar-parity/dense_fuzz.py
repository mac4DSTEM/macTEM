"""tools/parity/sidecar-parity/dense_fuzz.py -- P3: the structure-aware fuzz of dense-storage sidecars, and the forged header.

A file whose root keeps its attributes in HDF5's dense storage (a fractal heap, FRHP, and a version-2 B-tree, BTHD with its
leaf BTLF) was crashed or hung by editing those blocks and recomputing the block's checksum, so the library's integrity test
passes (an earlier investigation's method and its 648 FRHP windows).
This module makes the same mutations, as patches to a base file the harness applies (the Swift reader then reads each in a child
process with a deadline, fuzz.swift): for every byte of each FRHP, BTHD and BTLF block of an h5py-written dense file, six byte
operations, and every 2-, 4- and 8-byte window set to the sheet's values, with the block's lookup3 checksum recomputed (the
checksum bytes themselves are edited, unfixed, too). The second opinion's 648 are a subset (8-byte windows at 0, 1, 0xFFFF, 2^32-1,
2^64-1 inside the FRHP): `second_opinion_subset` counts them. lookup3 is Bob Jenkins' hash as HDF5 uses it (H5_checksum_lookup3),
checked here against the checksum stored in each block of the unmutated file (a block whose stored checksum does not verify is not
a region, and a missing FRHP, BTHD or BTLF fails the plan).

The forged header (measured, not gated): a compact sidecar with creation order tracked has an attribute-info message (AINFO) whose
fractal-heap and name-index addresses are undefined; `forge_attribute_info` points them at an address and recomputes the object
header's checksum, so the header keeps its attribute messages AND points at a heap. The reader's header filter does not refuse such a
file; what the library then does is recorded."""
import os
import re

import h5py
import numpy as np

M32 = 0xFFFFFFFF


def _rot(x, k):
    return ((x << k) | (x >> (32 - k))) & M32


def lookup3(data, initval=0):
    n = len(data)
    a = b = c = (0xDEADBEEF + n + initval) & M32
    i = 0

    def mix(a, b, c):
        a = (a - c) & M32; a ^= _rot(c, 4); c = (c + b) & M32
        b = (b - a) & M32; b ^= _rot(a, 6); a = (a + c) & M32
        c = (c - b) & M32; c ^= _rot(b, 8); b = (b + a) & M32
        a = (a - c) & M32; a ^= _rot(c, 16); c = (c + b) & M32
        b = (b - a) & M32; b ^= _rot(a, 19); a = (a + c) & M32
        c = (c - b) & M32; c ^= _rot(b, 4); b = (b + a) & M32
        return a, b, c

    while n - i > 12:
        a = (a + int.from_bytes(data[i:i + 4], "little")) & M32
        b = (b + int.from_bytes(data[i + 4:i + 8], "little")) & M32
        c = (c + int.from_bytes(data[i + 8:i + 12], "little")) & M32
        a, b, c = mix(a, b, c)
        i += 12
    rem = data[i:]
    if not rem:
        return c
    r = rem + b"\0" * (12 - len(rem))
    a = (a + int.from_bytes(r[0:4], "little")) & M32
    b = (b + int.from_bytes(r[4:8], "little")) & M32
    c = (c + int.from_bytes(r[8:12], "little")) & M32
    c ^= b; c = (c - _rot(b, 14)) & M32
    a ^= c; a = (a - _rot(c, 11)) & M32
    b ^= a; b = (b - _rot(a, 25)) & M32
    c ^= b; c = (c - _rot(b, 16)) & M32
    a ^= c; a = (a - _rot(c, 4)) & M32
    b ^= a; b = (b - _rot(a, 14)) & M32
    c ^= b; c = (c - _rot(b, 24)) & M32
    return c


def u(d, o, n):
    return int.from_bytes(d[o:o + n], "little")


class Region:
    """A checksummed block [start, end): the checksum is the four bytes at `ck`, over [start, ck)."""

    def __init__(self, kind, start, end, ck):
        self.kind, self.start, self.end, self.ck = kind, start, end, ck

    def __repr__(self):
        return f"{self.kind}[{self.start},{self.end})"


def regions(d):
    """The FRHP, BTHD and BTLF blocks of `d` whose stored checksum verifies (the sheet's `gbhang_blocks.analyze`, restricted)."""
    regs = []
    for m in re.finditer(b"FRHP", d):
        s = m.start()
        e = s + 146
        if u(d, s + 7, 2):
            e += 8 + 4 + u(d, s + 7, 2)               # a filtered root block: size, mask, the filter pipeline
        if e <= len(d) and lookup3(bytes(d[s:e - 4])) == u(d, e - 4, 4):
            regs.append(Region("FRHP", s, e, e - 4))
    headers = []
    for m in re.finditer(b"BTHD", d):
        s = m.start()
        e = s + 38
        if e <= len(d) and lookup3(bytes(d[s:e - 4])) == u(d, e - 4, 4):
            regs.append(Region("BTHD", s, e, e - 4))
            headers.append((u(d, s + 10, 2), u(d, s + 6, 4)))       # record size, node size
    for m in re.finditer(b"BTLF", d):
        s = m.start()
        found = None
        for record, node in sorted(set(headers)):
            for k in range(0, node // max(record, 1) + 1):
                p = s + 6 + k * record
                if p + 4 <= len(d) and lookup3(bytes(d[s:p])) == u(d, p, 4):
                    found = Region("BTLF", s, p + 4, p)
                    break
            if found:
                break
        if found:
            regs.append(found)
    regs.sort(key=lambda r: r.start)
    return regs


WINDOWS = {
    2: [0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF],
    4: [0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x400000, 0x400001],
    8: [0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x400000, 0x400001, 2 ** 63 - 1, 2 ** 64 - 1],
}
BYTE_OPS = [("xor", lambda b: b ^ 0xFF), ("bit0", lambda b: b ^ 1), ("zero", lambda b: 0), ("ff", lambda b: 0xFF),
            ("80", lambda b: b | 0x80), ("inc", lambda b: (b + 1) & 0xFF)]
SECOND_OPINION_VALUES = (0, 1, 0xFFFF, 2 ** 32 - 1, 2 ** 64 - 1)


def mutations(d, regs):
    """Yields (label, patches, quick): `quick` marks the second opinion's 648 (an 8-byte window of the FRHP body at five values). A patch is (offset, bytes) replacing those bytes of `d`; an edit inside a block carries the block's
    recomputed checksum as a second patch. Edits on the checksum bytes are not repaired; windows stay inside one block."""
    def owner(p):
        for r in regs:
            if r.start <= p < r.end and not (r.ck <= p < r.ck + 4):
                return r
        return None

    def patched(r, edits):
        """The patches for `edits` ((offset, bytes) pairs) with r's checksum recomputed over the edited block."""
        block = bytearray(d[r.start:r.ck])
        for off, data in edits:
            block[off - r.start:off - r.start + len(data)] = data
        return edits + [(r.ck, lookup3(bytes(block)).to_bytes(4, "little"))]

    for r in regs:
        for p in range(r.start, r.end):
            owned = owner(p)
            for name, op in BYTE_OPS:
                new = op(d[p])
                if new == d[p]:
                    continue
                edit = [(p, bytes([new]))]
                yield f"{r.kind} p{p} {name}", patched(owned, edit) if owned else edit, False
            for width, values in WINDOWS.items():
                if p + width > r.end:
                    continue
                if owned and any(owner(p + k) is not owned for k in range(width)):
                    continue
                for v in values:
                    data = v.to_bytes(width, "little")
                    if bytes(d[p:p + width]) == data:
                        continue
                    edit = [(p, data)]
                    quick = r.kind == "FRHP" and width == 8 and v in SECOND_OPINION_VALUES and p < r.ck - 7
                    yield f"{r.kind} p{p} w{width}={v:#x}", patched(owned, edit) if owned else edit, quick


def second_opinion_subset(d, regs):
    """How many of the second opinion's FRHP mutations (every 8-byte window of the block's body at five values) the schedule holds."""
    frhp = [r for r in regs if r.kind == "FRHP"][0]
    count = 0
    for p in range(frhp.start, frhp.ck - 7):
        for v in SECOND_OPINION_VALUES:
            if bytes(d[p:p + 8]) != v.to_bytes(8, "little"):
                count += 1
    return count


def dense_base(path, lineage_bytes, source_bytes=124):
    """An h5py-written dense sidecar (the second opinion's `mk.py`: newest format, fixed-length UTF-8 attributes)."""
    with h5py.File(path, "w", libver=("v110", "latest")) as f:
        for name, n in (("mactem_session_schema", 1), ("mactem_min_reader_schema", 1), ("mactem_source", source_bytes), ("mactem_lineage", lineage_bytes)):
            f.attrs.create(name, np.bytes_(b"1" if n == 1 else b"x" * n), dtype=h5py.string_dtype("utf-8", n))
    with h5py.File(path, "r") as f:
        info = h5py.h5o.get_info(f.id)
        if not (info.meta_size.attr.heap_size > 0 and info.meta_size.attr.index_size > 0):
            raise SystemExit(f"{path}: not in dense storage (a lineage of {lineage_bytes} bytes)")


def plan(directory, bases):
    """Plants each base and its mutation list under `directory`; returns the manifest entries. The count of the second opinion's
    windows the list marks is the count `second_opinion_subset` derives from the block alone."""
    import json
    os.makedirs(directory, exist_ok=True)
    out = []
    for label, lineage_bytes in bases:
        path = os.path.join(directory, f"{label}.mactem.h5")
        dense_base(path, lineage_bytes)
        d = open(path, "rb").read()
        regs = regions(d)
        kinds = sorted({r.kind for r in regs})
        if kinds != ["BTHD", "BTLF", "FRHP"]:
            raise SystemExit(f"{path}: the dense file's checksummed blocks are {kinds}; the plan needs FRHP, BTHD and BTLF")
        listing = [{"label": label_, "patches": [[off, data.hex()] for off, data in patches], "second_opinion": quick}
                   for label_, patches, quick in mutations(d, regs)]
        patches_file = f"{label}.patches.json"
        with open(os.path.join(directory, patches_file), "w") as fh:
            json.dump(listing, fh)
        out.append({"label": label, "file": f"dense-fuzz/{label}.mactem.h5", "patches": f"dense-fuzz/{patches_file}",
                    "count": len(listing), "regions": [repr(r) for r in regs], "second_opinion": second_opinion_subset(d, regs)})
        marked = sum(1 for item in listing if item["second_opinion"])
        if marked != out[-1]["second_opinion"]:
            raise SystemExit(f"{label}: {marked} mutations marked as the second opinion's, {out[-1]['second_opinion']} counted from the block")
    return out


def forged_files(directory):
    """The forged headers: a compact sidecar with creation order tracked (it has an attribute-info message), its heap and name-index
    addresses set to each of four places and the object header's checksum recomputed."""
    os.makedirs(directory, exist_ok=True)
    base = os.path.join(directory, "forged-base.mactem.h5")
    with h5py.File(base, "w", libver="latest", track_order=True) as f:
        for name, text in (("mactem_session_schema", "1"), ("mactem_min_reader_schema", "1"), ("mactem_source", "{}"), ("mactem_lineage", "{}")):
            f.attrs.create(name, np.bytes_(text.encode()), dtype=h5py.string_dtype("utf-8", len(text)))
    with h5py.File(base, "r") as f:
        info = h5py.h5o.get_info(f.id)
        if info.meta_size.attr.heap_size != 0 or info.num_attrs != 4:
            raise SystemExit("the forged base is not a compact sidecar of four attributes")
    d = open(base, "rb").read()
    root = root_header(d)[0]
    out = []
    for label, address in (("heap at the superblock", 0), ("heap at the root object header", root), ("heap at the end of the file", len(d)),
                           ("heap beyond the file", len(d) + 4096)):
        name = "forged-" + re.sub(r"[^a-z]+", "-", label) + ".mactem.h5"
        forge_attribute_info(base, os.path.join(directory, name), address)
        out.append({"label": label, "file": f"dense-fuzz/{name}"})
    return out


# ------------------------------------------------------------------------------------------------ the forged header

def root_header(d):
    """(start, end) of the root group's first object-header chunk (version 2): messages in [first, end - 4), checksum at end - 4."""
    assert d[:8] == b"\x89HDF\r\n\x1a\n" and d[8] >= 2, "a version 2 or 3 superblock"
    s = u(d, 36, 8)
    assert d[s:s + 4] == b"OHDR" and d[s + 4] == 2
    flags = d[s + 5]
    o = s + 6
    if flags & 0x20:
        o += 16
    if flags & 0x10:
        o += 4
    n = 1 << (flags & 3)
    size = u(d, o, n)
    first = o + n
    return s, flags, first, first + size + 4


def attribute_info_offset(d):
    """The offset of the root header's attribute-info message data (type 0x15), and its flags byte."""
    s, flags, first, end = root_header(d)
    o = first
    while o + 4 <= end - 4:
        mtype, msize, mflags = d[o], u(d, o + 1, 2), d[o + 3]
        head = 4 + (2 if flags & 0x04 else 0)
        if mtype == 0x15:
            return o + head, d[o + head + 1]
        o += head + msize
    return None, None


def forge_attribute_info(path, out_path, heap_address):
    """Copy `path` to `out_path` with its attribute-info message's fractal-heap and name-index addresses set to `heap_address` and the
    object header's checksum recomputed. Returns the file's bytes' length."""
    d = bytearray(open(path, "rb").read())
    data, aflags = attribute_info_offset(d)
    if data is None:
        raise SystemExit(f"{path}: no attribute-info message in the root's object header")
    o = data + 2 + (2 if aflags & 1 else 0)
    d[o:o + 8] = heap_address.to_bytes(8, "little")           # fractal heap
    d[o + 8:o + 16] = heap_address.to_bytes(8, "little")      # name index (v2 B-tree)
    s, _, _, end = root_header(d)
    d[end - 4:end] = lookup3(bytes(d[s:end - 4])).to_bytes(4, "little")
    with open(out_path, "wb") as fh:
        fh.write(d)
    return len(d)
