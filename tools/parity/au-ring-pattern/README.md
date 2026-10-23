# Au ring pattern (Zenodo 8354219)

The public polycrystalline-Au diffraction pattern macTEM's ring calibration is checked against. This folder makes its
derivation reproducible from the public record; nothing here is a macTEM result.

## What it is

The mean of the first 100000 of 160000 frames of a 400 x 400 nanobeam 4D-STEM scan of a ~20 nm polycrystalline Au film
on a SiN membrane, 200 kV, recorded on a Dectris ARINA (CZT, 192 x 192 pixels), as a 192 x 192 float32 TIFF
(`derived_mean_pattern_data000001_192x192_float32.tif`). The mean is our derivation, not part of the record.
Camera length is not stated in the record (see below); the pattern is calibrated from the Au lattice itself.

## Provenance and licence

- Record: Zenodo 8354219, DOI 10.5281/zenodo.8354219, file `Gold thin film.zip` (1,238,115,603 B,
  record md5 d6bd4344ba1bbeefa2cbb5a7c50312dd). Paper: doi:10.1088/2515-7639/acf524.
- Licence: CC-BY-4.0. Attribute the record's authors when redistributing; macTEM commits none of these bytes
  (`References/` is gitignored).
- Members used (stored deflate in the zip):

| Member | Bytes | sha256 |
|---|---|---|
| `Au_000_master.h5` | 1,624,944 | `4ae8b2a424f4e373ec16350f9219ee9aeca1ea2aaa681d047a490886b73e0de7` |
| `Au_000_data_000001.h5` | 997,256,617 | `b327c17206d0ed84bf6a2cfbaf33a425e7347fddc56b5af2a4e87e948cf892e3` |

`Au_000_data_000002.h5` (the remaining 60000 frames) is not used. The members' crc32 in the zip are 1d7107ee (master)
and bb90af09 (data_000001); `zip_range.py` checks them while extracting.

## Steps

```sh
tools/parity/au-ring-pattern/fetch-au-ring-pattern.sh          # members by HTTP range into References/ring-calibration/zenodo-8354219-au-thin-film-arina/; sha256 checked; skips a member already present and correct
D=References/ring-calibration/zenodo-8354219-au-thin-film-arina
References/python-venv/bin/python -I tools/parity/au-ring-pattern/derive-mean-pattern.py \
  $D/Au_000_data_000001.h5 $D/rederived/derived_mean_pattern_data000001_192x192_float32.tif \
  $D/derived_mean_pattern_data000001_192x192_float32.tif
```

The fetch needs only the standard library (the locked venv or any python3). The derivation needs h5py, hdf5plugin
(which carries the bitshuffle-LZ4 filter, HDF5 filter 32008, that the frames use), numpy and tifffile; all are already
in `tools/lib/references-lock.txt`, so the lock needs no change. The sum is exact in float64, divided once by 100000,
then rounded to float32 and written uncompressed.

## Result (2026-10-13)

Re-derived mean: 100000 frames, min 0.034180, max 1160.629395, mean 1.056648 counts/pixel, total 3,895,227,511
counts. sha256 of the TIFF `ff80816d0a21ced5f0283d5088b187081defd099b3e4743e63f0843923262470`, **file-identical**
(max |difference| 0) to the earlier derived TIFF, so the earlier undocumented derivation was this mean.

## Detector metadata (`Au_000_master.h5`, NXmx)

| Field | Value |
|---|---|
| detector | Dectris ARINA CZT, `DP-083-04`, type HPC, sensor CZT 1.5 mm, firmware `release-2022.1`, software 1.8.0 |
| x/y_pixel_size | 1e-4 m (100 um); fast/slow_pixel_direction 1e-4 m |
| pixels | 192 x 192; bit_depth_image 16, bit_depth_readout 12; saturation_value 5597 |
| photon_energy | 200000 (eV: the 200 kV beam). `incident_wavelength` 0.0619921 A is the X-ray wavelength of 200 keV, not the electron wavelength (0.02508 A) |
| detector_distance | 0.0 (not stated); geometry translation distances [0,0,0]; beam_center_x/y 0.0 |
| count_time | 5.955e-05 s; frame_time 5.965e-05 s; frame_period 36400.0 (as stored; unit not stated); readout time 1e-07 s |
| ntrigger / nimages | 160000 / 1; trigger_mode `exts`; auto_summation 1 |
| threshold_energy | 17500 (eV) |
| corrections applied | flatfield, pixel mask, countrate, virtual pixel: all 1; excluded pixels 0 |
| flatfield / pixel_mask | present, 192 x 192 (float32 / uint32); not applied again here, the frames are already corrected |
| compression | bslz4 |
| collected | 2022-12-01T13:45:46.962+01:00 |

Camera length: the notebook in the record (cell 57) hand-assigns Au (220) to get 0.022013 1/A per pixel, implying
L = p/(lambda*dq) = 18.1 mm. That is the authors' assumption, not an independent measurement.

## Rings of the mean pattern

Centre (93.5, 89.0) px; 0.5-px radial bins with Gaussian fits: r = 19.05 (weak), 32.00, 48.75, 55.65, 65.3, 84.5, 98,
113.9 px. The 220, 331, 422 and 440 rings stand at 1 : 1.523 : 1.739 : 2.04 against fcc Au 1 : 1.540 : 1.732 : 2.000;
111, 200, 311 and 222 are swamped by the direct beam's tail (archive: reference-search-2026-10-13.md).
