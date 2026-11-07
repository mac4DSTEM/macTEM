The vendor metadata tags (34682 Thermo/FEI, 34118 Zeiss) of RosettaSciIO's SEM test TIFFs, byte for byte, and the reference
their reader makes of the files (`sem-tiff-reference.json`), written by `tools/parity/sem/sem-image/reference.py`. Test data of
RosettaSciIO (https://github.com/hyperspy/rosettasciio, GPL-3.0-or-later), `rsciio/tests/data/tiff/tiff_FEI_Helios.zip` and
`tiff_Zeiss_SEM.zip` at commit 049e7d70. Read by `SEMImageMetadataTests`.

`tescan-pfib_dataZeroed.50431.bin` is tag 50431 of NexusLIMS's Tescan test file `tescan-pfib_dataZeroed.tif`, byte for byte
(sha256 in `tescan-reference.json`); `tescan-reference.json` holds the sections NexusLIMS's `tescan_tif` pipeline parses from it,
written by `tools/parity/sem/sem-image/tescan_reference.py`. Test data of NexusLIMS (https://github.com/datasophos/NexusLIMS,
MIT, (c) 2025 Datasophos), `tests/unit/files/tescan-pfib_dataZeroed.tar.gz` (sha256 a4859def…adfba), fetched 2026-11-07.
