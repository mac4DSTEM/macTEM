# sem-image

The Tescan reference of macTEM's SEM TIFF metadata reader (`Sources/TEMCore/SEM/SEMImageMetadata.swift`). RosettaSciIO has
no Tescan branch, so `tescan_reference.py` transcribes NexusLIMS's `tescan_tif` pipeline (MIT) and writes, from NexusLIMS's own
test file `tescan-pfib_dataZeroed.tif`, the tag's bytes and the sections it parses into `macTEMTests/Fixtures/sem-tiff/`
(`SOURCES-sem-tiff.md` there names the source and its sha256). Re-run it only when NexusLIMS's pipeline changes; a changed
value is a fixture move (its own commit, its reason).

    tar -xzf tescan-pfib_dataZeroed.tar.gz -C /tmp/tescan
    References/sem-venv/bin/python -I tools/parity/sem/sem-image/tescan_reference.py /tmp/tescan/tescan-pfib_dataZeroed.tif macTEMTests/Fixtures/sem-tiff

The Thermo/FEI and Zeiss references are the harness bundles `m1/read-sem-tiff-*` (`../emit.py`, D-SEM-90). `docs/parity.md`
lists the functions and tolerances.
