# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). App versions are tagged with a `v`
(`v1.0.0`); release-please writes each new entry above the older ones from the merged pull requests' titles.

## [2.0.2](https://github.com/mac4DSTEM/macTEM/compare/v2.0.1...v2.0.2) (2026-11-12)


### Bug Fixes

* a slip-plane row names its trace's colour, and the Maps overlay speaks its colours ([#568](https://github.com/mac4DSTEM/macTEM/issues/568)) ([b7ec490](https://github.com/mac4DSTEM/macTEM/commit/b7ec490f083920b752e9bfca3074a5d0f0195cab))
* release files, cubes and canvases when no longer shown (memory for 2.0.2) ([#582](https://github.com/mac4DSTEM/macTEM/issues/582)) ([3021de6](https://github.com/mac4DSTEM/macTEM/commit/3021de697ef16b5e271116537663992bcde7b4e6))
* slip traces past DefDAP's colour list take its last colour, not black ([#575](https://github.com/mac4DSTEM/macTEM/issues/575)) ([acab31f](https://github.com/mac4DSTEM/macTEM/commit/acab31ff7ce251dd2e84738fa04535960dcec819))
* VoiceOver hears the scan point's values, the Maps histogram and the IPF keys' colours ([#565](https://github.com/mac4DSTEM/macTEM/issues/565)) ([3469aa3](https://github.com/mac4DSTEM/macTEM/commit/3469aa32b52a511a153d12c81052d2ecf03cc7b3))

## [2.0.1](https://github.com/mac4DSTEM/macTEM/compare/v2.0.0...v2.0.1) (2026-11-12)


### Bug Fixes

* a .ctf phase of Laue group 10 reads as point group m-3, not orix's unknown "m3" ([#545](https://github.com/mac4DSTEM/macTEM/issues/545)) ([b89d459](https://github.com/mac4DSTEM/macTEM/commit/b89d459297b508696f47f02a12c5558b7139bd33))
* a .ctf saved on Windows opens, and scan and map sizes read width × height ([#519](https://github.com/mac4DSTEM/macTEM/issues/519)) ([1f6fbfa](https://github.com/mac4DSTEM/macTEM/commit/1f6fbfa0e1e4b605996c7cc2dff0a96f58a982ed))
* a colour TIFF as GMS exports a displayed image opens as grey instead of being refused ([#550](https://github.com/mac4DSTEM/macTEM/issues/550)) ([3eb7fd1](https://github.com/mac4DSTEM/macTEM/commit/3eb7fd10d54a488c9a466c19e329ff748254acb8))
* a DM file with no 2D image says what it holds in words, not dimension tuples ([#543](https://github.com/mac4DSTEM/macTEM/issues/543)) ([5f65d82](https://github.com/mac4DSTEM/macTEM/commit/5f65d8269648e54cf23006b1043fbb8abf043054))
* a DM4 spectrum image with picked spectra no longer also raises a can't-open alert ([#554](https://github.com/mac4DSTEM/macTEM/issues/554)) ([afc5e19](https://github.com/mac4DSTEM/macTEM/commit/afc5e1942c0be7a7e2af5784be83f9f4c271bf7f))
* a file macEM cannot open is titled "macEM can't open this file", not "Something went wrong" ([#552](https://github.com/mac4DSTEM/macTEM/issues/552)) ([559dca8](https://github.com/mac4DSTEM/macTEM/commit/559dca81d1deacfc72b8a607428044a1b99271ca))
* a HyperSpy file that is not one spectrum is refused naming the file, not HyperSpy's __unnamed__ group ([#544](https://github.com/mac4DSTEM/macTEM/issues/544)) ([b6a51fd](https://github.com/mac4DSTEM/macTEM/commit/b6a51fd6689bdf1fb23a6ddb2b8f8c1f449ec0b5))
* a map-only Oxford .h5oina opens in the Maps room ([#516](https://github.com/mac4DSTEM/macTEM/issues/516)) ([833bcf3](https://github.com/mac4DSTEM/macTEM/commit/833bcf33eb4edb8b99dfed1b6bdd638119a537fa))
* a pattern's size reads width × height in Info and in the processing refusals ([#547](https://github.com/mac4DSTEM/macTEM/issues/547)) ([b4028a7](https://github.com/mac4DSTEM/macTEM/commit/b4028a717a637ad94f324e93e5260afb5e6d0c36))
* a TIFF macEM cannot read is refused in a sentence that names the file and the compression in words ([#534](https://github.com/mac4DSTEM/macTEM/issues/534)) ([0d7097b](https://github.com/mac4DSTEM/macTEM/commit/0d7097b1c25c00584e25c392df3ae8d1f9ea5588))
* an EELS line scan is refused once and no longer also opens as a grey image ([#560](https://github.com/mac4DSTEM/macTEM/issues/560)) ([9d813d0](https://github.com/mac4DSTEM/macTEM/commit/9d813d0f8ac152ba87f3d3278e4eba4f04955798)), closes [#559](https://github.com/mac4DSTEM/macTEM/issues/559)
* EBSD HDF5 files without patterns go to the Maps room or are refused in words that name them ([#528](https://github.com/mac4DSTEM/macTEM/issues/528)) ([7c44c77](https://github.com/mac4DSTEM/macTEM/commit/7c44c77dfda6cef17f26127293f2747ce50f9ac5))
* export panels suggest no folder for the on-disk demo files ([#549](https://github.com/mac4DSTEM/macTEM/issues/549)) ([c7eb1fe](https://github.com/mac4DSTEM/macTEM/commit/c7eb1feaa91b0bc612a590e27bca042f33b6e7a7)), closes [#507](https://github.com/mac4DSTEM/macTEM/issues/507)
* LZW-compressed TIFFs open (FormatoKit 0.15.0) ([#537](https://github.com/mac4DSTEM/macTEM/issues/537)) ([1db1944](https://github.com/mac4DSTEM/macTEM/commit/1db19446ad7dcfa5072fee7d8565603764b72e2f))
* the .ctf map's format names its writer in words, and a pattern file's own map keeps the Patterns line ([#548](https://github.com/mac4DSTEM/macTEM/issues/548)) ([631b583](https://github.com/mac4DSTEM/macTEM/commit/631b583e9e519f78a1e3871a58f6fe21f9071e35))
* the CTF map's format names its writer in words, and a pattern file's own map keeps the Patterns line ([631b583](https://github.com/mac4DSTEM/macTEM/commit/631b583e9e519f78a1e3871a58f6fe21f9071e35)), closes [#522](https://github.com/mac4DSTEM/macTEM/issues/522)
* the Maps grains CSV quotes a phase name with a quote, one IPF key image builder, and one unused Indexing property gone ([#498](https://github.com/mac4DSTEM/macTEM/issues/498)) ([1feb50b](https://github.com/mac4DSTEM/macTEM/commit/1feb50b87f55c6f7251e801a1f1224d72e925b8c))
* the Maps room's Euler row names the H5OINA convention for an H5OINA with patterns, not orix ([#546](https://github.com/mac4DSTEM/macTEM/issues/546)) ([9b23296](https://github.com/mac4DSTEM/macTEM/commit/9b232965c51a812ef39185a4b6038a1542729e75))
* the six SEM picture panes have the VoiceOver zoom actions their hint promises ([#557](https://github.com/mac4DSTEM/macTEM/issues/557)) ([922cbb8](https://github.com/mac4DSTEM/macTEM/commit/922cbb868cea55a6b0810b83066cd6fa0dcef56c))

## [2.0.0](https://github.com/mac4DSTEM/macTEM/compare/v1.3.0...v2.0.0) (2026-11-11)


### ⚠ BREAKING CHANGES

* macTEM is now macEM. The download is macEM.dmg and the app is macEM.app, which does not replace macTEM.app. To update: quit macTEM, open the DMG and drag macEM to Applications, then move macTEM to the Trash and replace its Dock icon. Recent files, Reopen Last Session, the folders you allowed, window positions and every .mactem.h5 session file carry over. Exports now name macEM: CSV first lines read "# macEM ...", the line profile's header key "shown in macTEM as" is now "shown in macEM as", and PNG Software, ANG OPERATOR, CTF Author, the MSA comment and the method JSON's "software" say macEM. Session files keep the .mactem.h5 name.
* every EBSD reader hands its orientation map over as CrystalMap ([#182](https://github.com/mac4DSTEM/macTEM/issues/182))

### Features

* a second opened file comes up as a tab of its own, like Finder and Safari ([#435](https://github.com/mac4DSTEM/macTEM/issues/435)) ([025c0cc](https://github.com/mac4DSTEM/macTEM/commit/025c0ccf56bb088da591f057a594b0a6f6c04eee))
* agent door: Claude and other agents on this Mac look at macTEM's windows over MCP ([#497](https://github.com/mac4DSTEM/macTEM/issues/497)) ([7489799](https://github.com/mac4DSTEM/macTEM/commit/74897997eda41a570acb439e64a21a3f05c6d3d0))
* an SEM spectrum goes through the shared EDS room's own Quantify, with the file's elements picked on open ([#401](https://github.com/mac4DSTEM/macTEM/issues/401)) ([e38f563](https://github.com/mac4DSTEM/macTEM/commit/e38f5636378225065b95e8f4bb4263ceb11ec474))
* complete the Maps room with grains, KAM, GOS, GND, slip and texture ([#238](https://github.com/mac4DSTEM/macTEM/issues/238)) ([fb04c32](https://github.com/mac4DSTEM/macTEM/commit/fb04c3252dc2291347864f0c1723b562519ab6dd))
* crystal map model and the neighbour misorientation histogram (figure F7) against orix ([#167](https://github.com/mac4DSTEM/macTEM/issues/167)) ([5904d76](https://github.com/mac4DSTEM/macTEM/commit/5904d762371892b937255731b93f827781f9736e))
* denoise EBSD patterns with NLPAR as pyebsdindex does ([#156](https://github.com/mac4DSTEM/macTEM/issues/156)) ([157047d](https://github.com/mac4DSTEM/macTEM/commit/157047d10c862739cb0b0c821963c580c86a7e1c))
* denoise the scan with NLPAR as the last Process stage in the Patterns room ([#194](https://github.com/mac4DSTEM/macTEM/issues/194)) ([1d90c28](https://github.com/mac4DSTEM/macTEM/commit/1d90c28d3136d1c20aeb077a65edc68999335143))
* each room lists what its verb waits for in a Requirements section, as mac4DSTEM does ([#397](https://github.com/mac4DSTEM/macTEM/issues/397)) ([b7be9f2](https://github.com/mac4DSTEM/macTEM/commit/b7be9f2576a407eebfdb77c8a648fe7f85dc3084))
* each window has its own files, and macOS's window tabs work (New Window ⌘N) ([#413](https://github.com/mac4DSTEM/macTEM/issues/413)) ([9bb692b](https://github.com/mac4DSTEM/macTEM/commit/9bb692b40e10d7d215329a1becbb06fc52eb9b7a))
* EBSD and TKD detector geometry and the moving-screen projection centre against kikuchipy (figure F5) ([#152](https://github.com/mac4DSTEM/macTEM/issues/152)) ([94db1d5](https://github.com/mac4DSTEM/macTEM/commit/94db1d5a00d02f060f1f3a2396cfe806df196ed8))
* every EBSD reader hands its orientation map over as CrystalMap ([#182](https://github.com/mac4DSTEM/macTEM/issues/182)) ([7bbbea0](https://github.com/mac4DSTEM/macTEM/commit/7bbbea0e3bda6ee8243113726801e213d53c1b2f))
* File &gt; Open Recent, Reopen Last Session and Workspace &gt; Run (⌘R), and Close, Stop and Show Output act on what the room shows ([#403](https://github.com/mac4DSTEM/macTEM/issues/403)) ([e076b72](https://github.com/mac4DSTEM/macTEM/commit/e076b729b22db1817e968b3d9bc60706f835206b))
* filter EBSD patterns in the Patterns room: Equalise, FFT filter and Average neighbours ([#206](https://github.com/mac4DSTEM/macTEM/issues/206)) ([0d1d06a](https://github.com/mac4DSTEM/macTEM/commit/0d1d06a37b80abea76d2671fd3ff568451805da8))
* filter EBSD patterns: FFT filters, CLAHE and neighbour averaging as kikuchipy does ([#158](https://github.com/mac4DSTEM/macTEM/issues/158)) ([8acb82e](https://github.com/mac4DSTEM/macTEM/commit/8acb82e68d3fc7b9943769fb17922b2ac7d49bbf))
* geometrical Kikuchi overlay and kinematic master pattern as kikuchipy does (figure F14) ([#203](https://github.com/mac4DSTEM/macTEM/issues/203)) ([343c9e6](https://github.com/mac4DSTEM/macTEM/commit/343c9e62e9abce1ecd49e8f45b36c799a81fdf0d))
* grain statistics and texture as Results rows and session report parts ([#248](https://github.com/mac4DSTEM/macTEM/issues/248)) ([c7bf884](https://github.com/mac4DSTEM/macTEM/commit/c7bf8844b415e83c0842b226c244fad1dad04971))
* grains, boundaries, neighbour network, KAM, GROD and GOS of EBSD maps against DefDAP 1.3.1 (figures F11, F12) ([#187](https://github.com/mac4DSTEM/macTEM/issues/187)) ([5f320aa](https://github.com/mac4DSTEM/macTEM/commit/5f320aa0528a9d9dcb5b95408878ed37cf98a08a))
* hand the Hough-indexed scan over as a CrystalMap as kikuchipy does ([#207](https://github.com/mac4DSTEM/macTEM/issues/207)) ([20897ee](https://github.com/mac4DSTEM/macTEM/commit/20897eefff37c9c8c8ba7d774f4437ff8819f84b))
* Hough indexing (Radon band detection, triplet voting, QUEST) against pyEBSDindex (figure F8) ([#178](https://github.com/mac4DSTEM/macTEM/issues/178)) ([d37ae00](https://github.com/mac4DSTEM/macTEM/commit/d37ae00feafc0ed143802d0d429c65ecbf9933b8))
* image quality and average dot product maps in the Patterns room's Map picker (figure F3) ([#191](https://github.com/mac4DSTEM/macTEM/issues/191)) ([41dcc4e](https://github.com/mac4DSTEM/macTEM/commit/41dcc4e87694fcf5a3fc2375a302e737f9a4983f))
* image quality and average neighbour dot product maps of EBSD scans (figure F3) ([#150](https://github.com/mac4DSTEM/macTEM/issues/150)) ([895f943](https://github.com/mac4DSTEM/macTEM/commit/895f943cd4799883d64823b65691306bcb195201))
* index EBSD scans against a master-pattern dictionary as kikuchipy does (figure F9) ([#181](https://github.com/mac4DSTEM/macTEM/issues/181)) ([6e4a185](https://github.com/mac4DSTEM/macTEM/commit/6e4a1856730f6ebc9cff97e82ddeb251e04b96a6))
* Indexing room (⌘7): Hough-index the scan, watch the IPF map grow, read each point's solution and bands ([#209](https://github.com/mac4DSTEM/macTEM/issues/209)) ([c88200b](https://github.com/mac4DSTEM/macTEM/commit/c88200bd5eb89c79f681cef0557814b474367f2b))
* Indexing room compares two results (Hough, Dictionary, the file's indexing) as linked maps and a disorientation histogram ([#245](https://github.com/mac4DSTEM/macTEM/issues/245)) ([8941a3e](https://github.com/mac4DSTEM/macTEM/commit/8941a3e7d0a79f31de2b9835db9aa8d9a90b8434))
* Indexing room indexes several phases by dictionary, merged as kikuchipy's merge_crystal_maps ([#247](https://github.com/mac4DSTEM/macTEM/issues/247)) ([90b5197](https://github.com/mac4DSTEM/macTEM/commit/90b519713e4bd591d3e5cb285df569f08e881d61))
* Indexing room: index with a dictionary against a master pattern, with Score and OSM layers and each point's best match, as kikuchipy does (figure F9) ([#227](https://github.com/mac4DSTEM/macTEM/issues/227)) ([1ef16a9](https://github.com/mac4DSTEM/macTEM/commit/1ef16a9426f1e757ffade4df0f335322b6e25c55))
* Indexing room: scalar layers through the Map Display, an Euler layer, and ⌘C copies the Results table as TSV ([#240](https://github.com/mac4DSTEM/macTEM/issues/240)) ([ce01882](https://github.com/mac4DSTEM/macTEM/commit/ce018825398d77340c04687e1a54a6d0a26b7073))
* **indexing:** Refine stage after Dictionary (orientation, PC or both) ([#437](https://github.com/mac4DSTEM/macTEM/issues/437)) ([ffddb6b](https://github.com/mac4DSTEM/macTEM/commit/ffddb6b44bd256a599865d72d59aba3187212ae2))
* Kikuchi overlay band edges at the Bragg angle, and overlay CSV and PNG export ([#228](https://github.com/mac4DSTEM/macTEM/issues/228)) ([07d2c06](https://github.com/mac4DSTEM/macTEM/commit/07d2c0634dba0220a123357cf6e52b4111bb94f5))
* Kikuchi overlay of the run's solution in the Indexing room's pattern pane ([#243](https://github.com/mac4DSTEM/macTEM/issues/243)) ([db594eb](https://github.com/mac4DSTEM/macTEM/commit/db594ebe1adbf0e4fa23414c55c2cc81cf8f477e))
* Kinematical Kikuchi overlay with Blend and the kinematical master pattern ([#236](https://github.com/mac4DSTEM/macTEM/issues/236)) ([d145c77](https://github.com/mac4DSTEM/macTEM/commit/d145c772eea3da08c36512442544d1b99c63653d))
* macTEM is now macEM: the app, its DMG, its window and menus, its exports and the store texts carry the new name ([#505](https://github.com/mac4DSTEM/macTEM/issues/505)) ([fd1206a](https://github.com/mac4DSTEM/macTEM/commit/fd1206ab3c007ce73f6a2fce5815f279ece86f32))
* Maps room histograms, several selected grains and their poles on the pole figures ([#246](https://github.com/mac4DSTEM/macTEM/issues/246)) ([8729c67](https://github.com/mac4DSTEM/macTEM/commit/8729c67c26af527596825f52cfc8bfac8c5e1e2d))
* Maps room with IPF and phase maps, colour keys and hover readout of .ang and .ctf maps (F6 on screen) ([#199](https://github.com/mac4DSTEM/macTEM/issues/199)) ([cb0e226](https://github.com/mac4DSTEM/macTEM/commit/cb0e2267b15ff739c108960ca14d0c59805c0cab))
* open Bruker .bcf/.spx, EDAX .spd/.lsd/.spc and JEOL .pts/.eds/.img/.asw SEM-EDS files ([#164](https://github.com/mac4DSTEM/macTEM/issues/164)) ([5b050d4](https://github.com/mac4DSTEM/macTEM/commit/5b050d4e8203e1c4ef6c81ad0ab3781f25f219a0))
* Open in Maps shows the Indexing room's run in the Maps room, with a Source pop-up and a stale mark ([#244](https://github.com/mac4DSTEM/macTEM/issues/244)) ([dffe6cd](https://github.com/mac4DSTEM/macTEM/commit/dffe6cd76b01fd67055aa8c0a2e19b3b82118dec))
* open NORDIF Pattern.dat in the Patterns room ([#175](https://github.com/mac4DSTEM/macTEM/issues/175)) ([5bb3dac](https://github.com/mac4DSTEM/macTEM/commit/5bb3dac253ce9556274120e271bf0f1edf57d9a0))
* open Oxford .ebsp/.ctf and EDAX .up1/.up2/.ang scans in the Patterns room as one EBSDDataset ([#161](https://github.com/mac4DSTEM/macTEM/issues/161)) ([6fd2189](https://github.com/mac4DSTEM/macTEM/commit/6fd218926b8806f39a0601f26606d300ecf7edc4))
* orientation core (rotations, 32 point groups, fundamental zones, orientations and misorientations) against orix 0.15.0 ([#162](https://github.com/mac4DSTEM/macTEM/issues/162)) ([2a46109](https://github.com/mac4DSTEM/macTEM/commit/2a461092fb74f30d2f6cf4a082620b6ff245cba4))
* orientation similarity map and merge of dictionary-indexed maps as kikuchipy does ([#221](https://github.com/mac4DSTEM/macTEM/issues/221)) ([985e3d4](https://github.com/mac4DSTEM/macTEM/commit/985e3d42168399f1fa4bbba98c3f9232b69fdc47))
* Patterns and Indexing have one Display section with a Map · Pattern switch ([#402](https://github.com/mac4DSTEM/macTEM/issues/402)) ([fe87c40](https://github.com/mac4DSTEM/macTEM/commit/fe87c40c9293b3204975b887daa06076cafb8a4c))
* Patterns room ⌘6 browses EBSD pattern datasets (scan map, live pattern pane, calibration) ([#144](https://github.com/mac4DSTEM/macTEM/issues/144)) ([0860add](https://github.com/mac4DSTEM/macTEM/commit/0860addee1e419f986907e8e254fa961458b0438))
* pole figures, inverse pole figure densities and ODF sections against orix (figure F13) ([#196](https://github.com/mac4DSTEM/macTEM/issues/196)) ([24bb4b3](https://github.com/mac4DSTEM/macTEM/commit/24bb4b3013a9635c2933f7200979827354e556b4))
* process EBSD patterns in the Patterns room (static and dynamic background, rescale or normalise, binning) as kikuchipy does ([#190](https://github.com/mac4DSTEM/macTEM/issues/190)) ([13e7ccc](https://github.com/mac4DSTEM/macTEM/commit/13e7ccc939f24865495917b866ece4e03011087f))
* read EDAX .up1/.up2 pattern files and .ang orientation maps in TEMCore ([#138](https://github.com/mac4DSTEM/macTEM/issues/138)) ([d515bc4](https://github.com/mac4DSTEM/macTEM/commit/d515bc478204d03ea4f317f34dcce51103df0efd))
* read EMsoft master patterns and project them onto the EBSD detector as kikuchipy does (figure F15) ([#160](https://github.com/mac4DSTEM/macTEM/issues/160)) ([d18a5e7](https://github.com/mac4DSTEM/macTEM/commit/d18a5e7abaffab109fe5654a5735c1b3d9069234))
* read h5ebsd EBSD pattern files (kikuchipy, Bruker, EDAX, Oxford H5OINA) in TEMCore ([#125](https://github.com/mac4DSTEM/macTEM/issues/125)) ([d7117b9](https://github.com/mac4DSTEM/macTEM/commit/d7117b9ccb0cdc5e13b380676fd21291e90a80cc))
* read NORDIF EBSD acquisitions (Pattern.dat, Setting.txt, calibration patterns) as kikuchipy does ([#129](https://github.com/mac4DSTEM/macTEM/issues/129)) ([7d0f896](https://github.com/mac4DSTEM/macTEM/commit/7d0f89679c19a5829973364e309ad46b3c2761e4))
* read Oxford .ebsp patterns and .ctf orientation maps against kikuchipy and orix ([#135](https://github.com/mac4DSTEM/macTEM/issues/135)) ([adeebf2](https://github.com/mac4DSTEM/macTEM/commit/adeebf265c993713cb1d049636a45c07fff4992f))
* refine EBSD orientations and projection centres against the master pattern as kikuchipy does (figure F10) ([#214](https://github.com/mac4DSTEM/macTEM/issues/214)) ([3c5930e](https://github.com/mac4DSTEM/macTEM/commit/3c5930e93324368171c66142cb881d2a94bc1c0a))
* sample orientations on the cubochoric grid in a fundamental zone or around an orientation, against orix 0.15.0 ([#168](https://github.com/mac4DSTEM/macTEM/issues/168)) ([18302ef](https://github.com/mac4DSTEM/macTEM/commit/18302ef2aad39f58e36ba07285bf5dd4c0a357e0))
* Schmid factors, slip traces and GND density of EBSD maps against DefDAP 1.3.1 ([#170](https://github.com/mac4DSTEM/macTEM/issues/170)) ([e67cb6d](https://github.com/mac4DSTEM/macTEM/commit/e67cb6d4df4e12cb4cd485d99c313eb079b90505))
* SEM parity harness, north-star data and reference bundles for milestone 1 ([#130](https://github.com/mac4DSTEM/macTEM/issues/130)) ([d2afafe](https://github.com/mac4DSTEM/macTEM/commit/d2afafed6f7d9e7fddf6db2a4f48f0ab50b7ab5b))
* SEM session report and the SEM rows in the Results room (P8-02) ([#241](https://github.com/mac4DSTEM/macTEM/issues/241)) ([6262cea](https://github.com/mac4DSTEM/macTEM/commit/6262cea182cf86a339009a755ff0858421464d21))
* SEM TIFF metadata (Thermo, Zeiss, Tescan) in the Image room, databar cropped ([#136](https://github.com/mac4DSTEM/macTEM/issues/136)) ([a3436f0](https://github.com/mac4DSTEM/macTEM/commit/a3436f0aacfe0681bcf203edcde39324a651586f))
* SEM-EDS line intensities with background windows and Cliff-Lorimer quantification against exspy (figures F16, F17) ([#155](https://github.com/mac4DSTEM/macTEM/issues/155)) ([73e2124](https://github.com/mac4DSTEM/macTEM/commit/73e21240c606a17e2b79f528bdc87990b4bcfe62))
* ship the SEM demo data (Ni EBSD patterns, BAM TM002 spectrum) and open the spectrum from Try Demo Data ([#127](https://github.com/mac4DSTEM/macTEM/issues/127)) ([f95b7d9](https://github.com/mac4DSTEM/macTEM/commit/f95b7d99e74f28c97e3ff89f7a1f23a2a1927753))
* show the SEM databar as a strip under the picture ([#229](https://github.com/mac4DSTEM/macTEM/issues/229)) ([4e40618](https://github.com/mac4DSTEM/macTEM/commit/4e406184cc7012c96aa21147c6030df60eb2d1b1))
* static and dynamic background removal of EBSD patterns in TEMCore (figure F2) ([#133](https://github.com/mac4DSTEM/macTEM/issues/133)) ([eeb7660](https://github.com/mac4DSTEM/macTEM/commit/eeb7660a4a3bf0af783990a853f8d2c833568fef))
* the EDS room's region tools and Pin Region in the Workspace menu on ⌃⌘0…4 ([#446](https://github.com/mac4DSTEM/macTEM/issues/446)) ([63ea5bf](https://github.com/mac4DSTEM/macTEM/commit/63ea5bfa75c05b3210df638b32dad2b0ab7f281b))
* the EELS results table selects its edges and ⌘C copies them as tab-separated text ([#353](https://github.com/mac4DSTEM/macTEM/issues/353)) ([8a97f0f](https://github.com/mac4DSTEM/macTEM/commit/8a97f0f6d96abc00383692a18b1ee93a40bee7b9))
* the SEM maps open on their 1st to 99th percentile, so a few outliers no longer wash a map out ([#416](https://github.com/mac4DSTEM/macTEM/issues/416)) ([224945b](https://github.com/mac4DSTEM/macTEM/commit/224945b38fd44af2f779e5938c0057c826a69ece))
* the sidebar is the workspaces alone; the window's tabs are the open files ([#449](https://github.com/mac4DSTEM/macTEM/issues/449)) ([d0bfb53](https://github.com/mac4DSTEM/macTEM/commit/d0bfb538650c6fe2df32006972bc0185993214ce))
* the sidebar lists five workspaces with their parts underneath, as mac4DSTEM's does ([#399](https://github.com/mac4DSTEM/macTEM/issues/399)) ([7ab4579](https://github.com/mac4DSTEM/macTEM/commit/7ab4579dd62bdcc0565b1da25202833edde22a11))
* the workspaces read Imaging, Diffraction, EBSD, Spectroscopy, Results (⌘1…⌘5 follow) ([#474](https://github.com/mac4DSTEM/macTEM/issues/474)) ([d2243da](https://github.com/mac4DSTEM/macTEM/commit/d2243da2fb9220fcd58b7466e7ab30c121f6ab72))
* vectors, Miller indices, stereographic projection and IPF colour keys against orix 0.15.0 (figure F6) ([#172](https://github.com/mac4DSTEM/macTEM/issues/172)) ([71a6f40](https://github.com/mac4DSTEM/macTEM/commit/71a6f40b4d96b5f33861ea51ab65556c7e4ca7cf))
* virtual BSE images in the Patterns room (detector grid, tiles, colour mix) reproduce north-star figure F1 ([#174](https://github.com/mac4DSTEM/macTEM/issues/174)) ([d6d497b](https://github.com/mac4DSTEM/macTEM/commit/d6d497b1f1800c81fb6e9413d24809bace88e463))
* write EBSD crystal maps as .ang and .ctf that orix reads back (figure F18) ([#185](https://github.com/mac4DSTEM/macTEM/issues/185)) ([33ea462](https://github.com/mac4DSTEM/macTEM/commit/33ea462ff9886444d39782f052c0d57acb1877fa))


### Bug Fixes

* a file macTEM may not read says so instead of blaming its format, and a refused file leaves no empty tab ([#486](https://github.com/mac4DSTEM/macTEM/issues/486)) ([a29c9e1](https://github.com/mac4DSTEM/macTEM/commit/a29c9e1f0d1a90547fb2cd5d97626136c03af503))
* a pattern file read through its handle lets each row go as the pass moves on ([#471](https://github.com/mac4DSTEM/macTEM/issues/471)) ([5fbf725](https://github.com/mac4DSTEM/macTEM/commit/5fbf7258e729e47f25557896a134a10e15e87bab))
* a quit question asked from the background bounces the Dock icon, and File &gt; Close Map closes only the map shown ([#503](https://github.com/mac4DSTEM/macTEM/issues/503)) ([6b530ff](https://github.com/mac4DSTEM/macTEM/commit/6b530ff4c873fe3bc94f73cbe5e88fcb197c5c8e))
* an ended Indexing run lets go of the processed scan it read ([#504](https://github.com/mac4DSTEM/macTEM/issues/504)) ([1a09757](https://github.com/mac4DSTEM/macTEM/commit/1a09757191964f5ed6d5d7ec76d3ccc0dab45c81))
* an infinite NORDIF scaling factor scales every value to 0 again, as kikuchipy ([#450](https://github.com/mac4DSTEM/macTEM/issues/450)) ([471c3be](https://github.com/mac4DSTEM/macTEM/commit/471c3be064d1f8592538202903962515d0ffb4b3))
* an SEM TIFF's Info shows each acquisition field once, without the TEM-only "Not recorded" rows ([#418](https://github.com/mac4DSTEM/macTEM/issues/418)) ([a28a9b0](https://github.com/mac4DSTEM/macTEM/commit/a28a9b03034316a4ab77a2318aad016ea2533abc))
* closing an image or quitting asks before discarding unsaved marks or a running analysis ([#372](https://github.com/mac4DSTEM/macTEM/issues/372)) ([4927b8c](https://github.com/mac4DSTEM/macTEM/commit/4927b8c879ac2f94a69063364f4e16001bf03eb2))
* damaged SEM files are refused in words instead of quitting the app, Open Recent lists only files that opened, and a test that starts to skip fails CI ([#441](https://github.com/mac4DSTEM/macTEM/issues/441)) ([8e2f0ee](https://github.com/mac4DSTEM/macTEM/commit/8e2f0eec35de909dfb4775d1e7c9b087bb4b068b))
* **ebsd:** a NORDIF Pattern.dat whose Setting.txt cannot be read says so ([#360](https://github.com/mac4DSTEM/macTEM/issues/360)) ([66a0f3b](https://github.com/mac4DSTEM/macTEM/commit/66a0f3b8fc0b44c7e94575847ffd61a2bedc9547))
* **ebsd:** bad h5ebsd header numbers are refused, and pattern files on network volumes no longer crash when the volume goes away ([#366](https://github.com/mac4DSTEM/macTEM/issues/366)) ([91cfd0c](https://github.com/mac4DSTEM/macTEM/commit/91cfd0c21229209fa32b46131b756686d1f52e8a))
* **ebsd:** damaged .ang, .ctf and crystal-map coordinates are refused instead of crashing the Maps room ([#364](https://github.com/mac4DSTEM/macTEM/issues/364)) ([6b05064](https://github.com/mac4DSTEM/macTEM/commit/6b050640517e47892564c264b21a641f357c2429))
* **ebsd:** damaged .up1/.up2, NORDIF and .ebsp headers are refused instead of crashing the app ([#362](https://github.com/mac4DSTEM/macTEM/issues/362)) ([a561750](https://github.com/mac4DSTEM/macTEM/commit/a5617506a7e31c4ebdfea98ce3804c10e97a2746))
* **eds:** damaged Bruker, JEOL, EDAX and EMsoft files are refused instead of crashing or filling memory ([#370](https://github.com/mac4DSTEM/macTEM/issues/370)) ([341f7a0](https://github.com/mac4DSTEM/macTEM/commit/341f7a04a106d42e35d4f669e39da3a35192efe1))
* exported CSVs quote names, JEOL maps can be cancelled, the Patterns cache is bounded, and CI compiles the UI journeys ([#438](https://github.com/mac4DSTEM/macTEM/issues/438)) ([20a8fec](https://github.com/mac4DSTEM/macTEM/commit/20a8fecda20e2e1eef61ae1e29e9d15ee20b5ebd))
* exports write numbers the same in every locale, screen numbers round like the files, and long runs keep the Mac awake ([#419](https://github.com/mac4DSTEM/macTEM/issues/419)) ([63bc587](https://github.com/mac4DSTEM/macTEM/commit/63bc587c5c24108d85222a14c2d3af10a8881e4d))
* Help &gt; Open Demo Data works with no window open ([#443](https://github.com/mac4DSTEM/macTEM/issues/443)) ([a25ad20](https://github.com/mac4DSTEM/macTEM/commit/a25ad2096e2ececc1d9e8709f656b12d701a8b4d))
* huge or non-finite numbers in a SEM TIFF header or a typed processing field no longer crash the app ([#368](https://github.com/mac4DSTEM/macTEM/issues/368)) ([83f274d](https://github.com/mac4DSTEM/macTEM/commit/83f274dd935e55960e14591bea2159ca3d98574d))
* Maps reads an h5ebsd crystal map's length unit, so the Ni scale bar and grain sizes are in µm ([#390](https://github.com/mac4DSTEM/macTEM/issues/390)) ([ab0f15d](https://github.com/mac4DSTEM/macTEM/commit/ab0f15d3cedbc6a01e5e8c7c12ecf99a5f0536ef))
* NORDIF settings lines end and [Area] values read as kikuchipy reads them ([#456](https://github.com/mac4DSTEM/macTEM/issues/456)) ([028ae5a](https://github.com/mac4DSTEM/macTEM/commit/028ae5adf943ac05100f4237c0903d7a43b04291)), closes [#448](https://github.com/mac4DSTEM/macTEM/issues/448) [#452](https://github.com/mac4DSTEM/macTEM/issues/452)
* on a render, macTEM's scale bar starts hidden so it does not cover the render's own ([#483](https://github.com/mac4DSTEM/macTEM/issues/483)) ([ff5046a](https://github.com/mac4DSTEM/macTEM/commit/ff5046a6b6e027b8ee5b1cc4b6e1d7075c7ae976))
* Open Recent, drops, stack frames and Cancel answer what happened, Stop ends Segment and KAM, and Process uses every core ([#417](https://github.com/mac4DSTEM/macTEM/issues/417)) ([7dbb25e](https://github.com/mac4DSTEM/macTEM/commit/7dbb25e372be8b1cab65355272858cd47b5d2ac6))
* **parity:** pin numpy to its AVX2 kernels in the SEM emit so the texture bundles reproduce on every runner ([a8ddd37](https://github.com/mac4DSTEM/macTEM/commit/a8ddd3725e932edca33cfe2e11ffcb6efc5efcb6))
* **parity:** pin numpy's AVX2 kernels in the SEM emit so the texture bundles reproduce on every runner ([#223](https://github.com/mac4DSTEM/macTEM/issues/223)) ([a8ddd37](https://github.com/mac4DSTEM/macTEM/commit/a8ddd3725e932edca33cfe2e11ffcb6efc5efcb6))
* Particles, EELS and EDS no longer stay stale after a preview, a Stop or a same-named file ([#374](https://github.com/mac4DSTEM/macTEM/issues/374)) ([ac6f75a](https://github.com/mac4DSTEM/macTEM/commit/ac6f75a757556d027c8a0c395a244f65bca5f6fb))
* **patterns:** a new Grid or a Stop during a pass no longer blocks Process or drops the new run ([#389](https://github.com/mac4DSTEM/macTEM/issues/389)) ([a953970](https://github.com/mac4DSTEM/macTEM/commit/a9539701f425faccff16c0ad31ff25a740ab8597))
* **patterns:** NLPAR and averaging no longer copy the whole scan, and Process refuses a scan that would not fit in memory ([#400](https://github.com/mac4DSTEM/macTEM/issues/400)) ([ac028f0](https://github.com/mac4DSTEM/macTEM/commit/ac028f03cc8ba0c58c710ac1de4f95fe1c01a693))
* read real Tescan TIFF headers as NexusLIMS does ([#220](https://github.com/mac4DSTEM/macTEM/issues/220)) ([b4fea49](https://github.com/mac4DSTEM/macTEM/commit/b4fea49e87f501b8833bbb93a2980d7225933f9f))
* stopping the texture leaves the Pole figures and ODF panes saying what happened, with a way to compute it ([#499](https://github.com/mac4DSTEM/macTEM/issues/499)) ([09b4085](https://github.com/mac4DSTEM/macTEM/commit/09b40851900e95fb23e546cde827f5dd4ee12827))
* TEMCore builds with Xcode 27.1 again ([#444](https://github.com/mac4DSTEM/macTEM/issues/444)) ([a611894](https://github.com/mac4DSTEM/macTEM/commit/a611894bcad866be761fe9de32b1fc5d29ab892c))
* the diffraction readout keeps a crystal name holding a line break on its header line ([#462](https://github.com/mac4DSTEM/macTEM/issues/462)) ([44d2fd1](https://github.com/mac4DSTEM/macTEM/commit/44d2fd152be3734fb1bb67fff0273274eca507ab))
* the EDS room shows the SEM line table and window quantification for an SEM spectrum ([#249](https://github.com/mac4DSTEM/macTEM/issues/249)) ([f24204b](https://github.com/mac4DSTEM/macTEM/commit/f24204bc54c61be1e9d55d45fb3d1330b1590b10))
* the EELS Regions table writes a region's total counts without grouping ([#485](https://github.com/mac4DSTEM/macTEM/issues/485)) ([96e7ec5](https://github.com/mac4DSTEM/macTEM/commit/96e7ec5014464ac37f3772e8300225dc1ad26664)), closes [#481](https://github.com/mac4DSTEM/macTEM/issues/481)
* the EELS results pane shows every fitted edge before the regions, and Exact NNLS's Fit to reads in full ([#455](https://github.com/mac4DSTEM/macTEM/issues/455)) ([8a97f0f](https://github.com/mac4DSTEM/macTEM/commit/8a97f0f6d96abc00383692a18b1ee93a40bee7b9))
* the EELS spectrum follows a drawn, picked or cleared region at once and names it, not the drag's last live shape ([#494](https://github.com/mac4DSTEM/macTEM/issues/494)) ([8a97f0f](https://github.com/mac4DSTEM/macTEM/commit/8a97f0f6d96abc00383692a18b1ee93a40bee7b9))
* the File menu lists every room's exports, EELS windows can be set without dragging, and zoom and copy work in the FFT and Diffraction rooms ([#439](https://github.com/mac4DSTEM/macTEM/issues/439)) ([6f6d1ec](https://github.com/mac4DSTEM/macTEM/commit/6f6d1ec2bb3f68aaabb747582c06df46f1d42aae))
* the Indexing room writes its numbers one way and says Detector tilt ([#476](https://github.com/mac4DSTEM/macTEM/issues/476)) ([a67cd2b](https://github.com/mac4DSTEM/macTEM/commit/a67cd2b8b9607b13f6e3adf6cb158d57239de584))
* the Indexing room's detected bands draw on a solid dark track, as in mac4DSTEM ([#482](https://github.com/mac4DSTEM/macTEM/issues/482)) ([c21525f](https://github.com/mac4DSTEM/macTEM/commit/c21525f7252209ee8d0ff194ca30a7b1cfa4280b))
* the Indexing room's disorientation histogram draws only occupied bins, not a row of dots along zero ([#394](https://github.com/mac4DSTEM/macTEM/issues/394)) ([11e7389](https://github.com/mac4DSTEM/macTEM/commit/11e7389d3ae53d74479acb68985821f8d64dd1e6))
* the Maps and Patterns rooms write their numbers one way, grain lengths read alike, and the quality maps come before the tiles ([#451](https://github.com/mac4DSTEM/macTEM/issues/451)) ([01714c8](https://github.com/mac4DSTEM/macTEM/commit/01714c80f1accd829253591be3bb9af390d9762c))
* the Maps room's bottom tabs stay at the top of their pane, and the colour key and ODF sections read in full ([#393](https://github.com/mac4DSTEM/macTEM/issues/393)) ([e8ff992](https://github.com/mac4DSTEM/macTEM/commit/e8ff9928b371bc26ad5822dc1a054c0aaced788f))
* the planted comparison's inputs are normalised without BLAS, the same bits on every CPU ([#447](https://github.com/mac4DSTEM/macTEM/issues/447)) ([4eddab5](https://github.com/mac4DSTEM/macTEM/commit/4eddab586c2e184a0a9043e6a38da4edebd156eb))
* the SEM maps pick on click or drag, and hover only reads, as in mac4DSTEM ([#490](https://github.com/mac4DSTEM/macTEM/issues/490)) ([e9b66fc](https://github.com/mac4DSTEM/macTEM/commit/e9b66fcd03043ed28459b8d35dca162dbed8e06f))
* the SEM reference check no longer goes red when the Hough map comes back as another cubic twin ([#454](https://github.com/mac4DSTEM/macTEM/issues/454)) ([62a1cac](https://github.com/mac4DSTEM/macTEM/commit/62a1cace3eda31fc31d23ed1105389edf68719c2))
* the SEM rooms speak their bars, readout and headers, and the Grains table copies with ⌘C ([#477](https://github.com/mac4DSTEM/macTEM/issues/477)) ([67776be](https://github.com/mac4DSTEM/macTEM/commit/67776be8f36970d8e5ba5178c52964af82ce38e0))
* the SEM rooms speak their opening bars, pattern readout and column headers, and the Grains table copies with ⌘C ([67776be](https://github.com/mac4DSTEM/macTEM/commit/67776be8f36970d8e5ba5178c52964af82ce38e0))
* the SEM rooms write their remaining numbers through Num and UnitDisplay, never grouped ([#501](https://github.com/mac4DSTEM/macTEM/issues/501)) ([87489ea](https://github.com/mac4DSTEM/macTEM/commit/87489ea20b66f241280e521afbb8351150941934))
* the SEM rooms' status lines write their numbers in the reader's locale ([#484](https://github.com/mac4DSTEM/macTEM/issues/484)) ([ede69df](https://github.com/mac4DSTEM/macTEM/commit/ede69df554f840ff3872a1fb643f9dd954c6c684))
* the SEM tables take the keyboard when clicked, so ⌘C copies their rows, and their headers are spoken in words ([#502](https://github.com/mac4DSTEM/macTEM/issues/502)) ([2145ec5](https://github.com/mac4DSTEM/macTEM/commit/2145ec5d089d7ec093d3e69b54ab08bbdfbc24ac))
* the SEM-EDS rows drop the window composition and write their numbers in the locale they are given ([#414](https://github.com/mac4DSTEM/macTEM/issues/414)) ([d2e2065](https://github.com/mac4DSTEM/macTEM/commit/d2e2065425239a6f7997cc6ba076dc6c7bf7d0e4))
* the session record's refusals write their byte and entry counts ungrouped ([#300](https://github.com/mac4DSTEM/macTEM/issues/300)) ([8a97f0f](https://github.com/mac4DSTEM/macTEM/commit/8a97f0f6d96abc00383692a18b1ee93a40bee7b9))
* the session report and the dictionary method JSON write the Refine and energy words with a decimal point ([#458](https://github.com/mac4DSTEM/macTEM/issues/458)) ([f47813f](https://github.com/mac4DSTEM/macTEM/commit/f47813fa1adf363028f6f0e727909652a49b48d1))
* vendor EBSD pairs and EDAX EDS maps open with their companion files in the sandboxed app ([#395](https://github.com/mac4DSTEM/macTEM/issues/395)) ([418f2db](https://github.com/mac4DSTEM/macTEM/commit/418f2db7d2ef5aedd1e1b7d80b9cd349900869c0))
* VoiceOver names the image-opening spinner and the FFT spectrum pane's spinners ([#467](https://github.com/mac4DSTEM/macTEM/issues/467)) ([5a9ab7b](https://github.com/mac4DSTEM/macTEM/commit/5a9ab7b7cc0dcfebac0c3f92d56639218e64898b))
* VoiceOver reads the pixel under the pointer in the Image and Diffraction panes ([#457](https://github.com/mac4DSTEM/macTEM/issues/457)) ([515f6c6](https://github.com/mac4DSTEM/macTEM/commit/515f6c65552e2532a28602f31bec0f765a804b52))
* whole numbers on screen carry no grouping separator in the EELS room and the Image, FFT and Particles controls ([#488](https://github.com/mac4DSTEM/macTEM/issues/488)) ([8a97f0f](https://github.com/mac4DSTEM/macTEM/commit/8a97f0f6d96abc00383692a18b1ee93a40bee7b9))

## [1.3.0](https://github.com/mac4DSTEM/macTEM/compare/v1.2.0...v1.3.0) (2026-11-05)


### Features

* EELS Align signal range and crop are real controls ([#87](https://github.com/mac4DSTEM/macTEM/issues/87)) ([7a681d0](https://github.com/mac4DSTEM/macTEM/commit/7a681d0819743a2fb0e3d21c6ccb25fa310f76b4))
* Help &gt; Open Demo Data opens the generated demo documents ([#108](https://github.com/mac4DSTEM/macTEM/issues/108)) ([f9d7dfb](https://github.com/mac4DSTEM/macTEM/commit/f9d7dfb991487e5a9c78e52a21f0aa02cb310f46))


### Bug Fixes

* EELS fit notes popover and fit-quality line read cleanly ([#96](https://github.com/mac4DSTEM/macTEM/issues/96)) ([8855eee](https://github.com/mac4DSTEM/macTEM/commit/8855eee05b531c97516a00f41542c4bdc8ab633a))
* EELS spectrum legend no longer covers the low loss and core loss labels ([#93](https://github.com/mac4DSTEM/macTEM/issues/93)) ([4b68682](https://github.com/mac4DSTEM/macTEM/commit/4b6868258bbf0ad9159ca5b85a1fff15de6b3a24))
* Particles Export CSV writes into --export-dir and reports its result ([#98](https://github.com/mac4DSTEM/macTEM/issues/98)) ([d3c5cb8](https://github.com/mac4DSTEM/macTEM/commit/d3c5cb8350db3b0fa1bed2587fb0fb07c3190d7e))
* remember files the sandbox grants read-only ([#114](https://github.com/mac4DSTEM/macTEM/issues/114)) ([ec59da7](https://github.com/mac4DSTEM/macTEM/commit/ec59da7b1770bf0d09db9d92dc775998ebacf808))

## [1.2.0](https://github.com/mac4DSTEM/macTEM/compare/v1.1.1...v1.2.0) (2026-11-02)


### Features

* EELS keyboard regions, hovered pixel spectrum and profile labels ([#82](https://github.com/mac4DSTEM/macTEM/issues/82)) ([36aadd5](https://github.com/mac4DSTEM/macTEM/commit/36aadd518e6a7559ba4e00e5f9293d05ba1f629d))
* EELS Maps status line while maps are computed ([#78](https://github.com/mac4DSTEM/macTEM/issues/78)) ([3b3812d](https://github.com/mac4DSTEM/macTEM/commit/3b3812da73e01b22767b65f6503c9372bfeff7ae))
* EELS MLLS fit uses the reference spectra ([#90](https://github.com/mac4DSTEM/macTEM/issues/90)) ([903f3b9](https://github.com/mac4DSTEM/macTEM/commit/903f3b9608bedaf156adb7da65bf6924b4eb78ab))
* EELS results footer opens the fit notes, as the EDS room ([#81](https://github.com/mac4DSTEM/macTEM/issues/81)) ([124d663](https://github.com/mac4DSTEM/macTEM/commit/124d6632e3abe7d8ed520a2c2f9f64791e137810))
* EELS room keyboard regions, the hovered pixel's spectrum and profile labels ([36aadd5](https://github.com/mac4DSTEM/macTEM/commit/36aadd518e6a7559ba4e00e5f9293d05ba1f629d))
* EELS single spectrum and stage state on the section titles ([#77](https://github.com/mac4DSTEM/macTEM/issues/77)) ([521675d](https://github.com/mac4DSTEM/macTEM/commit/521675d1c7c32721f5df3bc998d80669d3b47139))
* EELS Spectrum MSA export, method JSON SHA-256, Info tilts and beam source ([#79](https://github.com/mac4DSTEM/macTEM/issues/79)) ([e2bd1f6](https://github.com/mac4DSTEM/macTEM/commit/e2bd1f6b7db8adacabd5b369c2981b69206229b1))


### Bug Fixes

* EELS profile lists only the shown maps; the hovered spectrum shows in light mode ([#84](https://github.com/mac4DSTEM/macTEM/issues/84)) ([d49acb1](https://github.com/mac4DSTEM/macTEM/commit/d49acb13514b2d23d2f1c61807dbdf9dcdc3923a))
* EELS results table shows at% and wt% without clipping ([#88](https://github.com/mac4DSTEM/macTEM/issues/88)) ([7383d0f](https://github.com/mac4DSTEM/macTEM/commit/7383d0f07414496d848cd790e9238d486d8f69c4))
* EELS ZLP shift tile contrast and the empty tooltip on the colour mix ([#91](https://github.com/mac4DSTEM/macTEM/issues/91)) ([1d43ad8](https://github.com/mac4DSTEM/macTEM/commit/1d43ad8cd2f329ae134456feae78a4569f4e3e30))
* Open Files shows the scan size of an EELS spectrum image ([#89](https://github.com/mac4DSTEM/macTEM/issues/89)) ([a701ded](https://github.com/mac4DSTEM/macTEM/commit/a701ded5083d0fb39410a1030c6dd6124488a980))
* the EELS room opens a single spectrum ([#85](https://github.com/mac4DSTEM/macTEM/issues/85)) ([77d81fc](https://github.com/mac4DSTEM/macTEM/commit/77d81fca95de9f0522cb655fac69b603e4d1bda5))

## [1.1.1](https://github.com/mac4DSTEM/macTEM/compare/v1.1.0...v1.1.1) (2026-11-02)


### Bug Fixes

* the app version comes from the release tag ([#75](https://github.com/mac4DSTEM/macTEM/issues/75)) ([5994de9](https://github.com/mac4DSTEM/macTEM/commit/5994de9bbe6fb5f0a5399ecd9c352db2667423c6))

## [1.1.0](https://github.com/mac4DSTEM/macTEM/compare/v1.0.0...v1.1.0) (2026-11-01)


### Features

* EELS results carry sigma on at% and wt%, the fit quality and an MLLS Fit to ([#61](https://github.com/mac4DSTEM/macTEM/issues/61)) ([e6ff757](https://github.com/mac4DSTEM/macTEM/commit/e6ff757a908c9e297474adba6672d0698e69b688))
* EELS room deconvolution stage, MLLS fit model and Fit only role ([#58](https://github.com/mac4DSTEM/macTEM/issues/58)) ([cd78122](https://github.com/mac4DSTEM/macTEM/commit/cd7812245e4e8bfab5d527c914da0493fc102778))
* EELS wt% maps and a display filter ([#67](https://github.com/mac4DSTEM/macTEM/issues/67)) ([0e736f3](https://github.com/mac4DSTEM/macTEM/commit/0e736f3723808b9f1b40b247c9d4e26b19fc1c10))
* Find Spots ranks by local contrast and shows it in the spot row ([#38](https://github.com/mac4DSTEM/macTEM/issues/38)) ([b1b1b3b](https://github.com/mac4DSTEM/macTEM/commit/b1b1b3b74b8b663e11134ba6621890160bafc274))
* particles take Otsu's threshold, remove objects below the minimum area and report the areal density ([#37](https://github.com/mac4DSTEM/macTEM/issues/37)) ([59f211f](https://github.com/mac4DSTEM/macTEM/commit/59f211f41c329d2eaa5329ad8c0e2d02fd3b9df5))
* results no longer carry an unvalidated badge ([#63](https://github.com/mac4DSTEM/macTEM/issues/63)) ([12c2b34](https://github.com/mac4DSTEM/macTEM/commit/12c2b34dad28676b9ff9a2005c4623bfd130dc61))
* the busy line shows elapsed time, and an ETA where the work reports progress ([#45](https://github.com/mac4DSTEM/macTEM/issues/45)) ([02bfc77](https://github.com/mac4DSTEM/macTEM/commit/02bfc77f567c1d7ab7d4276dbae3c65276e64790))
* the EDX room comes from MacEMUI ([#22](https://github.com/mac4DSTEM/macTEM/issues/22)) ([e1165e7](https://github.com/mac4DSTEM/macTEM/commit/e1165e7117544c8d570a8cda59ea6faa38e2c997))
* the EELS room no longer labels results as unvalidated ([#65](https://github.com/mac4DSTEM/macTEM/issues/65)) ([3fc255c](https://github.com/mac4DSTEM/macTEM/commit/3fc255c2041954c8f948f2c22a46aa3bc0e14093))
* the Particles object table is a window, the pointer names the object under it, and the section sits above Measure ([#42](https://github.com/mac4DSTEM/macTEM/issues/42)) ([242ff56](https://github.com/mac4DSTEM/macTEM/commit/242ff56b15f0a0851be077504b909ce4e96b6fe8))
* the Results room lists the EDS composition of the file ([#41](https://github.com/mac4DSTEM/macTEM/issues/41)) ([849c3ba](https://github.com/mac4DSTEM/macTEM/commit/849c3baa8fe00ee909e37eb72ebe9643e9f4e147))
* the Results room lists the EELS thickness and fitted edges of the file ([#50](https://github.com/mac4DSTEM/macTEM/issues/50)) ([113ccf5](https://github.com/mac4DSTEM/macTEM/commit/113ccf56c58179cac8bcaea5296f2cb8a91eff4d))


### Bug Fixes

* a lone spectrum file highlights only its own room in the sidebar ([#47](https://github.com/mac4DSTEM/macTEM/issues/47)) ([369d626](https://github.com/mac4DSTEM/macTEM/commit/369d6263228e592cd36f8d8cca56786b261b114f))
* a re-read with other pixels drops the particle report; ImagoKit 0.8.0 ([#26](https://github.com/mac4DSTEM/macTEM/issues/26)) ([add48f4](https://github.com/mac4DSTEM/macTEM/commit/add48f426b54c55390bf7d59793e1e198a04c7e6))
* a session re-save keeps another writer's lineage keys and refuses a rewritten or deleted sidecar ([#33](https://github.com/mac4DSTEM/macTEM/issues/33)) ([795ac30](https://github.com/mac4DSTEM/macTEM/commit/795ac30554aa01a56a50b8eb6e82e9c2402cbfe3))
* a single .msa spectrum opens from Finder, the Open panel and a drop ([#34](https://github.com/mac4DSTEM/macTEM/issues/34)) ([d7605fc](https://github.com/mac4DSTEM/macTEM/commit/d7605fcd8abae4fe6ed4c5c8b803bc01d12fa2bd))
* exports carry no milestone ids in their validation and lineage text ([#16](https://github.com/mac4DSTEM/macTEM/issues/16)) ([44edfdb](https://github.com/mac4DSTEM/macTEM/commit/44edfdb358f9a891fe99b0e7bae6e1ad57564029))
* macTEM texts drop the unvalidated wording ([cc778be](https://github.com/mac4DSTEM/macTEM/commit/cc778be64931eada4e5c4c37a5d31f51ad89d1fb))
* Particles numbers use the locale decimal mark ([#48](https://github.com/mac4DSTEM/macTEM/issues/48)) ([2f7d726](https://github.com/mac4DSTEM/macTEM/commit/2f7d726dfaa30a587e9ff4a89ff4e48c2de0a653))
* refuse a save after a re-read with other pixels, offer Save Anyway ([#27](https://github.com/mac4DSTEM/macTEM/issues/27)) ([2f07578](https://github.com/mac4DSTEM/macTEM/commit/2f0757843986332d55b1a378be6cfaab96b2075e))
* the busy line names the running operation, not the last status sentence ([#49](https://github.com/mac4DSTEM/macTEM/issues/49)) ([49c63aa](https://github.com/mac4DSTEM/macTEM/commit/49c63aa266956b318e78d04eddcb70b216f31d31))
* the Save to Session title follows a grant stored or dropped while the file is open ([#35](https://github.com/mac4DSTEM/macTEM/issues/35)) ([fd19a40](https://github.com/mac4DSTEM/macTEM/commit/fd19a4008aba3364f0d6c5fe407cebcbb3108fe2))
* turn Metal fast math off before the first compute kernel ([#28](https://github.com/mac4DSTEM/macTEM/issues/28)) ([3bffd96](https://github.com/mac4DSTEM/macTEM/commit/3bffd96616f740fd91350ce66c914814aa63d6f8))

## v1.0.0 — 2026-10-23

First release. macTEM analyses TEM images, EDS and EELS spectrum images and diffraction patterns on Apple silicon
Macs (macOS 27 at this release). The numbers come from the suite's kits (FormatoKit 0.11.0, DiffractoKit 0.10.0,
ImagoKit 0.7.0, SpectroKit 0.12.0) and the window from MacEMUI 0.3.0; anything not yet checked against known truth says
`validation: none`.

### Added

- **Opening files.** DigitalMicrograph (.dm3, .dm4), Velox (.emd), TIFF and MRC. The file's content decides the room,
  not its extension: an image opens in the Image room, a spectrum image in the EDS or EELS room (a Velox file with a
  HAADF image and a spectrum cube fills both), a single `.msa` spectrum in the EDS room. A room with no data for the
  open files is disabled in the sidebar with a one-line reason.
- **Rooms** in the order the work goes: Prepare, Image, FFT, EDS, EELS, Diffraction and Results (⌘1 to ⌘7).
- **Image room.** Calibration from the file, colormap, contrast window and gamma; zoom (⌘+, ⌘−, ⌘0) with the pixel
  under the pointer in the status line; distances, angles and line profiles measured on the file's pixels; marks saved
  in a session file next to the image.
- **Image stacks.** A multi-page TIFF or ImageJ stack opens frame by frame, read on demand (a 100-frame series shows a
  frame in about 2 MB of memory). ← and → step through the frames, Home and End go to the ends, and "Same contrast for
  every frame" holds the contrast window so brightness drift shows.
- **Particles.** Bright or dark objects found by a threshold in the image's own units, with optional smoothing, 4 or 8
  connectivity and a minimum area; each object outlined with its moments ellipse, a sortable table and a CSV export.
- **FFT room.** The transform of the image or a region with a window (Hann, Hamming, Blackman, Tukey), spots and their
  d-spacings, Find Spots with an editable threshold, distance and count, the radial profile, a masked inverse, and
  Gaussian, band-pass, ABSF and Wiener filters.
- **EDS room.** Velox and GMS spectrum images. Elements from the periodic table or from Auto ID (the published
  AutoEMX/NIST identification loop); net-count, wt%, at% and thickness maps; the pooled Cliff-Lorimer fit with
  computed or typed k-factors and the absorption correction when the file gives the detector geometry and a thickness
  is typed; zeta-factor and cross-section methods. Quantify is the toolbar's verb (⌘↩).
- **EELS room.** Dual-EELS spectrum images with their low loss and core loss. Run aligns the zero-loss peak, maps t/λ
  and fits the chosen edges; the periodic table offers 383 K, L and M edges of 95 elements (the generalised oscillator
  strengths of Segger, Guzzinati and Kohl, bundled; see NOTICE). Background and signal windows can be dragged on the
  spectrum; each edge's intensity carries its 1σ, and an edge at or under 3σ reads "below detection".
- **Regions** in the EDS and EELS rooms: rectangles, ellipses, polygons and lines, each numbered and coloured, with
  their spectra overlaid, a table row per region and line profiles across the maps.
- **Diffraction room.** Any image read as a pattern: a centre (image centre, typed, or a fitted ring's), a scale from a
  ring calibrated against Au, Al or Si (or the file's reciprocal axis, or a typed Δq), fitted rings and clicked spots
  indexed against a standard or an opened CIF, and a readout table and CSV.
- **Results room.** Every measurement of a file in one table, exported as CSV.
- **Exports.** PNG figures with the scale bar, CSV tables, and a method JSON for the spectroscopy rooms.
