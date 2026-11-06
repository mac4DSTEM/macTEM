# Parity

What macTEM reads or computes against which pinned Python reference, with the tolerance each comparison uses (the upstream
package's own, never stricter). The TEM readers' parity is FormatoKit's (`docs/parity.md` there) and the scientific
harnesses' (`tools/parity/*/README.md`); this file lists what the app ports itself, starting with the SEM program.

## SEM images (TIFF)

| Function | Reference | Test | Tolerance | State |
|---|---|---|---|---|
| `SEMImageMetadata.read` (Thermo/FEI tags 34680/34682) | RosettaSciIO 0.15.0 `_axes_fei`, `mapping_fei`; tifffile 2026.9.20 `read_fei_metadata` | `SEMImageMetadataTests` on the five Helios test files' tags | numbers 1e-9 relative, texts exact (RosettaSciIO's own tests: axes rtol 1e-6, metadata 7 places) | live |
| `SEMImageMetadata.read` (Zeiss tag 34118) | RosettaSciIO `_axes_zeiss`, `mapping_cz_sem`; tifffile `read_cz_sem` | the same, on the three Zeiss test files' tags | the same | live |
| `SEMImageMetadata.read` (Tescan tag 50431) | NexusLIMS `tescan_tif` (keys and units); no RosettaSciIO branch | planted header | exact | live, marked unvalidated in the room |
| Databar rows (Thermo `DatabarHeight`, Tescan `ImageStripSize`) | tifffile's parse of the same bytes; no reader maps it | the five Helios files (29 and 39 rows) and a plant | exact | live; Zeiss never cropped (D-SEM-13) |
| Spot, chamber pressure, Thermo detector | tifffile's parse; RosettaSciIO does not map them | the same files | exact | live, noted in the room |

References: `macTEMTests/Fixtures/sem-tiff/sem-tiff-reference.json`, written by `tools/parity/sem/sem-image/reference.py`
from RosettaSciIO's `tiff_FEI_Helios.zip` and `tiff_Zeiss_SEM.zip` (commit 049e7d70's test data, GPL-3.0-or-later).
