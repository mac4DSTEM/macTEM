# sem-image

The reference of macTEM's SEM TIFF metadata reader (`Sources/TEMCore/SEM/SEMImageMetadata.swift`): what RosettaSciIO 0.15.0's
TIFF reader and tifffile 2026.9.20 make of RosettaSciIO's eight SEM test TIFFs (five Thermo Helios, three Zeiss). Unlike the
other harnesses this one is not a nightly executable: `reference.py` writes `macTEMTests/Fixtures/sem-tiff/sem-tiff-reference.json`
and the vendor tag's bytes of each file beside it, and `SEMImageMetadataTests` compares the Swift reading of those bytes with the
reference on every PR (the unit gate, hosted runner, no network). Re-run it only when the pin moves; a changed number is a
fixture move (its own commit, its reason).

    python3 -m venv .venv && .venv/bin/pip install "rosettasciio[tiff]==0.15.0" "tifffile==2026.9.20"
    unzip rsciio/tests/data/tiff/tiff_FEI_Helios.zip rsciio/tests/data/tiff/tiff_Zeiss_SEM.zip -d /tmp/sem-tiffs
    .venv/bin/python tools/parity/sem/sem-image/reference.py /tmp/sem-tiffs macTEMTests/Fixtures/sem-tiff

The test data is RosettaSciIO's (GPL-3.0-or-later), at the lock commit `tools/lib/fetch-rsciio.sh` names; the tag bytes are
the only part committed (72 KB), the images stay fetched. `docs/parity.md` lists the functions and tolerances.
