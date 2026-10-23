"""Read members of a remote zip by HTTP range requests (central directory first). Standard library only.

  python -I zip_range.py list <url>                      -> name, compressed size, size, crc32, method per member
  python -I zip_range.py extract <url> <member> <out>    -> writes the member, verifies its crc32 and size

The archive is untrusted data: member names are matched exactly and only written to the path given as <out>.
"""
import struct, sys, urllib.request, zlib

def fetch(url, start, end):  # inclusive byte range
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        if r.status != 206:
            raise SystemExit(f"zip_range: server did not honour the range ({r.status})")
        return r.read()

def total_size(url):
    req = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return int(r.headers["Content-Range"].split("/")[1])

def central_directory(url):
    size = total_size(url)
    tail = fetch(url, max(0, size - 70000), size - 1)
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        raise SystemExit("zip_range: no end-of-central-directory record")
    sig, disk, cdisk, nd, entries, cd_size, cd_off, clen = struct.unpack("<IHHHHIIH", tail[i:i + 22])
    if 0xFFFFFFFF in (cd_size, cd_off) or entries == 0xFFFF:  # zip64
        j = tail.rfind(b"PK\x06\x07", 0, i)
        if j < 0:
            raise SystemExit("zip_range: zip64 locator missing")
        (z64_off,) = struct.unpack("<8xQ4x", tail[j:j + 20])
        z = fetch(url, z64_off, z64_off + 55)
        entries, cd_size, cd_off = struct.unpack("<32xQQQ", z[:56])
    cd = fetch(url, cd_off, cd_off + cd_size - 1)
    out, p = {}, 0
    for _ in range(entries):
        (sig, _v, _n, flags, method, _t, _d, crc, csize, usize, nlen, xlen, clen, _dn, _ia, _ea, lho) = \
            struct.unpack("<IHHHHHHIIIHHHHHII", cd[p:p + 46])
        if sig != 0x02014B50:
            raise SystemExit("zip_range: bad central directory entry")
        name = cd[p + 46:p + 46 + nlen].decode("utf-8", "replace")
        extra = cd[p + 46 + nlen:p + 46 + nlen + xlen]
        q = 0
        while q + 4 <= len(extra):  # zip64 extra field: only the fields that were 0xFFFFFFFF, in this order
            tag, ln = struct.unpack("<HH", extra[q:q + 4])
            if tag == 1:
                f = extra[q + 4:q + 4 + ln]; k = 0
                if usize == 0xFFFFFFFF: (usize,) = struct.unpack("<Q", f[k:k + 8]); k += 8
                if csize == 0xFFFFFFFF: (csize,) = struct.unpack("<Q", f[k:k + 8]); k += 8
                if lho == 0xFFFFFFFF: (lho,) = struct.unpack("<Q", f[k:k + 8]); k += 8
            q += 4 + ln
        out[name] = dict(method=method, crc=crc, csize=csize, usize=usize, lho=lho)
        p += 46 + nlen + xlen + clen
    return out

def extract(url, member, dest, entries):
    e = entries[member]
    lh = fetch(url, e["lho"], e["lho"] + 29)
    nlen, xlen = struct.unpack("<HH", lh[26:30])
    start = e["lho"] + 30 + nlen + xlen
    d = zlib.decompressobj(-15) if e["method"] == 8 else None
    if e["method"] not in (0, 8):
        raise SystemExit(f"zip_range: unsupported method {e['method']}")
    crc, written, step = 0, 0, 16 << 20
    with open(dest, "wb") as fh:
        for a in range(start, start + e["csize"], step):
            b = min(a + step, start + e["csize"]) - 1
            chunk = fetch(url, a, b)
            data = d.decompress(chunk) if d else chunk
            crc = zlib.crc32(data, crc); written += len(data); fh.write(data)
        if d:
            data = d.flush(); crc = zlib.crc32(data, crc); written += len(data); fh.write(data)
    if crc != e["crc"] or written != e["usize"]:
        raise SystemExit(f"zip_range: {member}: crc32/size mismatch (got {crc:08x}/{written}, zip says {e['crc']:08x}/{e['usize']})")

if __name__ == "__main__":
    cmd, url = sys.argv[1], sys.argv[2]
    ents = central_directory(url)
    if cmd == "list":
        for n, e in ents.items():
            print(f"{n}\t{e['csize']}\t{e['usize']}\t{e['crc']:08x}\t{e['method']}")
    elif cmd == "extract":
        if sys.argv[3] not in ents:
            raise SystemExit(f"zip_range: no member {sys.argv[3]!r}")
        extract(url, sys.argv[3], sys.argv[4], ents)
    else:
        raise SystemExit("usage: zip_range.py list|extract <url> [member out]")
