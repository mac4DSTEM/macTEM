//
//  AcquisitionMetadataReadTests.swift
//  The wiring of acquisition metadata (archive: roadmap-registrations-2026-10-15.md V1-4a, slice S-b): `AcquisitionMetadata.read(path:)` reaching the three
//  format readers by extension, the DM image object it describes being the one `ImageOpening.openNow` shows, a
//  DM-saved TIFF's tag 65027 read through mac4DSTEM's tag walker (precedence FEI SEM, Velox, DM), and the open's token
//  publishing the metadata with its image (`ImageSession.finishOpen(_:image:url:metadata:)`).
//
//  The rules themselves (kV from V, a date's order, a mode's camera length) are AcquisitionMetadataDMTests',
//  ...TIFFTests' and ...MRCTests'; the parity against ncempy, RosettaSciIO, tifffile and mrcfile on the real files is
//  tools/parity/metadata-parity (C1–C5). These files are planted here, so their truth is the bytes written below: a multi-
//  object DM4 with decoys (a thumbnail, a "Spectrum image", a later image) each stating another voltage, DM tag
//  streams written bare (root group = the ImageTags, as DigitalMicrograph stores them in tag 65027) and TIFFs with
//  exactly the tags a case needs. The real RosettaSciIO file is not used (licence and size; no test reads References/).
//
//  Every test names the production mutation meant to turn it red. The reproducible record of those mutations is
//  tools/parity/metadata-parity: run.sh's source mutants edit a copy of one file (the verbatim walker DM4Experiment.swift among
//  them; the repo's file is never edited) and require a failed check of the harness for each. A mutation named here that has no
//  source mutant there was applied by hand to a scratch copy of the package on 2026-10-13, when the test was written, and
//  went red there: a one-off run whose log is not in the repo, which nothing re-runs, so it is a statement and not a
//  record. The app-hosted `testAppStateReadHandsOverTheMetadataOfTheFileItOpened` is run by `tools/run-tests.sh unit`; the
//  session that wrote it showed its mutations red on a scratch copy of the call site compiled into a bare harness (2026-10-13),
//  not by running the test.
//

import XCTest
import FormatoCore
import FormatoTIFF
import TEMCore
import TEMSession
import FormatoDM
@testable import macTEM

nonisolated final class AcquisitionMetadataReadTests: XCTestCase {
    private static let local = "local time, zone not stored"
    private static let unvalidated = "unvalidated: no published reader reads it"
    private typealias Node = DM4TestFile.Node

    // MARK: DM: the object described is the object shown

    /// A DM4 of four objects, each stating another voltage: 1 the thumbnail (11 kV), 2 a "Spectrum image" the open skips
    /// (80 kV), 3 the STEM image the open shows (200 kV: `shownSTEM`), 4 a later image (300 kV).
    private func multiObjectDM4(named file: String) throws -> String {
        let nm = DM4TestFile.Axis(origin: 0, scale: 0.5, units: "nm")
        let object = { (name: String, dims: [Int32], tags: [Node], format: String?) in
            Plant.withTags(DM4TestFile.object(name: name, dims: dims, axes: [nm, nm]), tags, format: format)
        }
        let data = DM4TestFile.file([
            object("preview", [8, 6], Plant.imageTags(voltage: 11_000, magnification: 11), nil),            // 1: named the thumbnail below
            object("SI", [4, 3], Plant.imageTags(voltage: 80_000, magnification: 80), "Spectrum image"),     // 2: skipped by the open
            object("STEM", [3, 2], Plant.imageTags(voltage: 200_000, magnification: 50_000), "Image"),       // 3: shown
            object("Later", [3, 2], Plant.imageTags(voltage: 300_000, magnification: 300), nil),             // 4: a later image
        ], extraRoot: [DM4TestFile.thumbnailList(0)])
        return try DM4TestFile.write(data, named: file, for: self)
    }

    /// The expected reading of `Plant.imageTags(voltage: 200_000, magnification: 50_000)`: every field stated once.
    private static var shownSTEM: AcquisitionMetadata {
        var want = AcquisitionMetadata()
        want.highTensionKV = MetadataReading(200)
        want.magnification = MetadataReading(50_000)
        want.cameraLengthMM = MetadataReading(150, note: "mm (assumed)")
        want.detector = MetadataReading("BM-UltraScan", note: unvalidated)
        want.dwellUS = MetadataReading(2)
        want.exposureS = MetadataReading(0.5)
        want.acquired = MetadataReading("2016-08-27 20:54:33", note: local)
        want.instrument = MetadataReading("FEI Titan")
        want.mode = MetadataReading("STEM · DIFFRACTION")
        return want
    }

    /// Mutations (each red): `dm-wrong-object` in three forms in `read(path:)` — `objects.first` (the thumbnail's 11 kV),
    /// the first non-thumbnail (the "Spectrum image" decoy's 80 kV), `objects.last` (the later image's 300 kV) — and, in
    /// a scratch copy of the verbatim walker, `dm-prefix-kept` (keys keep `ImageList.3.ImageTags.`, so no rule finds a
    /// tag), `dm-strings-lost` (no string map: mode, date, instrument, detector go) and `dm-zero-units-kept` (the trailing
    /// NUL of the date stays, so the date does not read).
    func testTheMetadataReadIsTheObjectOpenNowShowsAndNoOther() throws {
        let path = try multiObjectDM4(named: "multi.dm4")

        let shown = try ImageOpening.openNow(path: path)
        XCTAssertEqual(shown.source, "ImageList.3 · STEM", "the open shows object 3: not the thumbnail, not the SI, not the later image")
        XCTAssertEqual(ImageOpening.primaryImageObject(in: try DM4Experiment.list(path: path))?.index, 3)

        XCTAssertEqual(AcquisitionMetadata.read(path: path), Self.shownSTEM,
                       "the metadata is object 3's, every field (200 kV, not 11, 80 or 300)")
    }

    /// Mutation: `read(path:)` falling back to `objects.first` when the open's rule picks no object (red: it would
    /// describe the stack's tags).
    func testAFileTheOpenRefusesReadsEmpty() throws {
        let nm = DM4TestFile.Axis(origin: 0, scale: 0.5, units: "nm")
        let stack = Plant.withTags(DM4TestFile.object(name: "Stack", dims: [4, 3, 2], axes: [nm, nm, nm]),
                                   Plant.imageTags(voltage: 200_000, magnification: 50_000), format: nil)
        let path = try DM4TestFile.write(DM4TestFile.file([stack]), named: "stack.dm4", for: self)
        XCTAssertThrowsError(try ImageOpening.openNow(path: path), "a [4, 3, 2] stack is no 2D image: the open refuses it")
        XCTAssertTrue(AcquisitionMetadata.read(path: path).isEmpty, "nothing is shown, so nothing is described")
    }

    /// The GMS stack builder keeps the source image's tags under `source.Tags at creation.`; the walker's keys are
    /// relative to `ImageList.N.ImageTags.`, so they arrive as `source.Tags at creation.Microscope Info.Voltage` and
    /// the DM rules read them where the direct tag is absent. Mutations (scratch copy of the walker, each red):
    /// `dm-creation-dropped` (no `source.Tags at creation.` key reaches the maps), `dm-prefix-kept`.
    func testAStackBuildersCreationCopyIsReadWhereTheDirectTagIsAbsent() throws {
        let nm = DM4TestFile.Axis(origin: 0, scale: 0.5, units: "nm")
        let twin: [Node] = [.group("source", [.group("Tags at creation", [.group("Microscope Info", [
            .double("Voltage", 120_000), .double("Indicated Magnification", 25_000)])])])]
        let path = try DM4TestFile.write(DM4TestFile.file([
            Plant.withTags(DM4TestFile.object(name: "Aligned", dims: [3, 2], axes: [nm, nm]), twin, format: nil),
        ]), named: "twin.dm4", for: self)
        var want = AcquisitionMetadata()
        want.highTensionKV = MetadataReading(120)
        want.magnification = MetadataReading(25_000)
        XCTAssertEqual(AcquisitionMetadata.read(path: path), want)
    }

    // MARK: The extension decides the reader

    /// Every extension `ImageOpening` reads has a metadata reader: a plant per format states a high tension, and each
    /// must read it back. A new `readableExtensions` entry fails here until its metadata reader is decided. Mutations
    /// (each red): a case dropped from the dispatch ("tiff", "mrc", "dm3"), `read(path:)` returning empty for all.
    func testEveryExtensionTheOpenReadsReachesItsReader() throws {
        for ext in ImageOpening.readableExtensions {
            let plant: Data
            switch ext {
            case "dm3", "dm4":
                // DM4 content under .dm3 too: the walker reads the version field, as the open's does.
                plant = DM4TestFile.file([Plant.withTags(DM4TestFile.object(name: "A", dims: [3, 2], axes: nil),
                                                         Plant.imageTags(voltage: 200_000, magnification: 50_000), format: nil)])
            case "tif", "tiff":
                plant = TIFFPlant([34683: .ascii(Plant.velox(voltage: 300_000))]).build()
            case "mrc":
                plant = Plant.fei2MRC(voltage: 300_000)
            case "emd":
                // HDF5 cannot be written from Swift here: the planted Velox file h5py wrote (tools/parity/velox-image-parity),
                // 200 kV, its HAADF last in key order.
                let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "velox-haadf-last", withExtension: "emd"),
                                        "velox-haadf-last.emd is not in the test bundle")
                plant = try Data(contentsOf: url)
            default:
                XCTFail("ImageOpening reads .\(ext) but this test has no plant for it: decide its metadata reader in AcquisitionMetadata.read(path:) and plant it here")
                continue
            }
            let path = try DM4TestFile.write(plant, named: "scan." + ext, for: self)
            let kv = AcquisitionMetadata.read(path: path).highTensionKV?.value
            XCTAssertEqual(kv, ext == "mrc" || ext.hasPrefix("tif") ? 300 : 200, ".\(ext)")
        }
    }

    /// The open lower-cases the extension (`SCAN.TIF` opens); so does the metadata read. A file whose extension no
    /// reader claims reads empty whatever it holds: the extension decides, as it does for the open. Mutations (each
    /// red): `lowercased()` dropped; a `default:` that tries the content as a TIFF.
    func testTheExtensionIsMatchedLikeTheOpenMatchesIt() throws {
        let velox = TIFFPlant([34683: .ascii(Plant.velox(voltage: 300_000))]).build()
        for name in ["SCAN.TIF", "Scan.Tiff", "scan.tIf"] {
            let path = try DM4TestFile.write(velox, named: name, for: self)
            XCTAssertEqual(AcquisitionMetadata.read(path: path).highTensionKV?.value, 300, name)
        }
        let dm = DM4TestFile.file([Plant.withTags(DM4TestFile.object(name: "A", dims: [3, 2], axes: nil),
                                                  Plant.imageTags(voltage: 200_000, magnification: 50_000), format: nil)])
        XCTAssertEqual(AcquisitionMetadata.read(path: try DM4TestFile.write(dm, named: "SCAN.DM4", for: self)).highTensionKV?.value, 200)
        XCTAssertEqual(AcquisitionMetadata.read(path: try DM4TestFile.write(Plant.fei2MRC(voltage: 300_000), named: "SCAN.MRC", for: self))
            .highTensionKV?.value, 300)
        for name in ["scan.ser", "scan.txt", "scan"] {
            let path = try DM4TestFile.write(velox, named: name, for: self)
            XCTAssertTrue(AcquisitionMetadata.read(path: path).isEmpty, "\(name): a Velox TIFF's bytes under an extension no reader claims")
        }
        // Under .emd the Velox reader takes it, finds no HDF5, and reads nothing: the extension decides, not the bytes.
        XCTAssertTrue(AcquisitionMetadata.read(path: try DM4TestFile.write(velox, named: "scan.emd", for: self)).isEmpty)
    }

    /// The open succeeded when the app asks, so a file that cannot be read for its metadata is "not recorded", never an
    /// error: bytes that are no container of the extension's kind, a header of no size, a file that is gone. Mutation:
    /// a `try` that rethrows or a `try!` for `try?` (red: this test throws or crashes).
    func testAFileThatCannotBeReadForItsMetadataReadsEmpty() throws {
        let junk = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        for ext in ImageOpening.readableExtensions {
            XCTAssertTrue(AcquisitionMetadata.read(path: try DM4TestFile.write(junk, named: "junk." + ext, for: self)).isEmpty, ".\(ext) junk")
            XCTAssertTrue(AcquisitionMetadata.read(path: try DM4TestFile.write(Data(), named: "empty." + ext, for: self)).isEmpty, ".\(ext) empty")
            XCTAssertTrue(AcquisitionMetadata.read(path: "/nonexistent-mactem-folder/missing." + ext).isEmpty, ".\(ext) missing")
        }
    }

    // MARK: A DM-saved TIFF: tag 65027

    /// A DM-saved TIFF's tag 65027 is a bare DM4 stream; its tags are read with the DM rules and equal what the same
    /// ImageTags give inside a .dm4. Planted to mirror what the registration predicted for RosettaSciIO's
    /// test_loading_image_saved_with_DM.tif (200 kV, 51× — Actual 83 ignored —, no camera length in TEM imaging whatever
    /// `STEM Camera Length` (255) says, 0.5 s, the day-first date, "FEI Tecnai"), written here, not copied from the file.
    /// Mutations (each red): `tiff-65027-skipped` (the branch removed or the tag id patched), `tiff-65027-strings-lost`
    /// (the strings map passed empty: instrument, detector, date and mode go), `tiff-65027-prefixed` (the keys handed on
    /// under `ImageList.1.ImageTags.`: no rule finds a tag).
    func testATIFFSavedByDMReadsTheTagTreeOfTag65027() throws {
        let tags = Plant.temImagingTags
        let tiff = TIFFPlant([65027: .bytes(type: 1, BareDM4.stream(tags))]).build()
        var want = AcquisitionMetadata()
        want.highTensionKV = MetadataReading(200)
        want.magnification = MetadataReading(51)
        want.detector = MetadataReading("BM-UltraScan", note: Self.unvalidated)
        want.exposureS = MetadataReading(0.5)
        want.acquired = MetadataReading("2015-07-20 18:48:25", note: Self.local)
        want.instrument = MetadataReading("FEI Tecnai")
        want.mode = MetadataReading("TEM · IMAGING")
        XCTAssertEqual(try AcquisitionMetadata.tiff(data: tiff, convention: .app), want, "tiff(data:)")
        XCTAssertNil(want.cameraLengthMM, "the plant's STEM Camera Length is 255 and the mode is TEM imaging")

        // Through a path: the same bytes under .tif, and the same ImageTags as a .dm4's shown image, give the same reading.
        let tifPath = try DM4TestFile.write(tiff, named: "saved-with-dm.tif", for: self)
        XCTAssertEqual(AcquisitionMetadata.read(path: tifPath), want, "tif path")
        let dm4 = DM4TestFile.file([Plant.withTags(DM4TestFile.object(name: "A", dims: [3, 2], axes: nil), tags, format: nil)])
        XCTAssertEqual(AcquisitionMetadata.read(path: try DM4TestFile.write(dm4, named: "same.dm4", for: self)), want, "dm4 path")
    }

    /// FEI SEM first, Velox second, DM third. Each source states another voltage (5 kV, 300 kV, 120 kV). A tag that
    /// exists but cannot be read still closes the later ones: 34683 of the wrong type, or 34682 of a type the INI reader
    /// refuses, reads empty and the DM tree behind it is not tried. Mutations (each red): `tiff-dm-before-velox` (DM tried
    /// before Velox), DM before FEI SEM, DM tried when 34683 exists but is not text (`tags[34683] == nil` dropped), DM
    /// tried when the FEI tags read empty.
    func testPrecedenceIsFEISEMThenVeloxThenDM() throws {
        let dmBlock = TIFFPlant.Value.bytes(type: 1, BareDM4.stream(Plant.voltageOnly(120_000)))
        let veloxXML = TIFFPlant.Value.ascii(Plant.velox(voltage: 300_000))
        let feiINI = TIFFPlant.Value.ascii("[Beam]\r\nHV=5000\r\n")
        func kv(_ tags: [UInt16: TIFFPlant.Value]) throws -> Double? {
            try AcquisitionMetadata.tiff(data: TIFFPlant(tags).build(), convention: .app).highTensionKV?.value
        }
        XCTAssertEqual(try kv([34682: feiINI, 34683: veloxXML, 65027: dmBlock]), 5, "all three: FEI SEM")
        XCTAssertEqual(try kv([34680: feiINI, 65027: dmBlock]), 5, "FEI SEM (tag 34680) before DM")
        XCTAssertEqual(try kv([34683: veloxXML, 65027: dmBlock]), 300, "Velox and DM: Velox")
        XCTAssertEqual(try kv([65027: dmBlock]), 120, "DM alone")
        // Present but unreadable: the later conventions are not tried.
        XCTAssertTrue(try AcquisitionMetadata.tiff(data: TIFFPlant([34683: .short(1), 65027: dmBlock]).build(), convention: .app).isEmpty,
                      "34683 exists (a SHORT, no text): empty, not the DM tree behind it")
        XCTAssertTrue(try AcquisitionMetadata.tiff(data: TIFFPlant([34682: .short(1), 65027: dmBlock]).build(), convention: .app).isEmpty,
                      "34682 exists (a SHORT, no INI): empty, not the DM tree behind it")
    }

    /// A 65027 that is not a tag stream the walker accepts reads empty, never throws: bytes of no format, a stream cut
    /// mid-tag, a DM version the walker refuses, a tag of another type (UNDEFINED, ASCII) holding a good stream, and the
    /// stack file's empty tree (0 tags, padded). Mutations (each red): `try` for `try?` on `tagTree` (the junk, cut and
    /// version cases throw), the `entry.type == 1` test dropped (the UNDEFINED and ASCII cases read).
    func testATag65027ThatIsNotADMTagStreamReadsEmpty() throws {
        let good = BareDM4.stream(Plant.voltageOnly(120_000))
        let cases: [(String, TIFFPlant.Value)] = [
            ("junk", .bytes(type: 1, (0..<600).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })),
            ("cut mid-tag", .bytes(type: 1, Array(good.prefix(good.count - 20)))),
            ("DM version 5", .bytes(type: 1, [0, 0, 0, 5] + Array(good.dropFirst(4)))),
            ("UNDEFINED type", .bytes(type: 7, good)),
            ("ASCII type", .bytes(type: 2, good)),
            ("an empty tree, padded to 512 B", .bytes(type: 1, BareDM4.stream([], paddedTo: 512))),
        ]
        for (label, value) in cases {
            let got = try AcquisitionMetadata.tiff(data: TIFFPlant([65027: value]).build(), convention: .app)
            XCTAssertTrue(got.isEmpty, label)
        }
        // The good stream itself reads, so the empties above are not a plant that never could.
        XCTAssertEqual(try AcquisitionMetadata.tiff(data: TIFFPlant([65027: .bytes(type: 1, good)]).build(), convention: .app).highTensionKV?.value, 120)
    }

    /// The block is read up to 16 MiB (1 << 24 bytes) and not beyond: a good stream padded with zeros to exactly the cap
    /// reads, one byte more reads empty. Mutations (each red): the cap removed or raised, `<=` for `<` at the cap.
    func testTag65027IsReadUpToTheCapAndNotBeyond() throws {
        let cap = 1 << 24
        let stream = BareDM4.stream(Plant.voltageOnly(120_000))
        let atCap = try AcquisitionMetadata.tiff(data: TIFFPlant([65027: .bytes(type: 1, BareDM4.pad(stream, to: cap))]).build(), convention: .app)
        XCTAssertEqual(atCap.highTensionKV?.value, 120, "exactly 16 MiB reads")
        let beyond = try AcquisitionMetadata.tiff(data: TIFFPlant([65027: .bytes(type: 1, BareDM4.pad(stream, to: cap + 1))]).build(), convention: .app)
        XCTAssertTrue(beyond.isEmpty, "16 MiB + 1 byte is not read")
    }

    /// The block must lie wholly inside the file. FormatoTIFF's `TIFFFile` (since the kit switch, 2026-10-20) refuses a file whose
    /// tag value runs past the last byte: `tiff(data:)` THROWS `TIFFError.truncated` where the app's former walker read the file
    /// and ignored that tag (the block was no block, the rest of the metadata still read). `AcquisitionMetadata.read(path:)`
    /// swallows the throw, so the user sees "not recorded" as before; the one change is that the other tags of such a file
    /// are no longer read either (the same files now fail to open as an image: `TIFFAppImage` throws `truncated`). Never a trap
    /// (the process survives every overrun below); a block that fits exactly still reads. Three overruns of one stream: one
    /// byte, two, 4096; the geometry the Gate B review made the unguarded reader trap on (a 100-byte file, count 5000 at
    /// offset 26); and an offset past the end of the file.
    func testATag65027WhoseCountRunsPastTheEndOfTheFileThrowsTruncatedAndReadsEmptyThroughAPath() throws {
        var stream = BareDM4.stream(Plant.voltageOnly(120_000))
        if stream.count % 2 == 1 { stream.append(0) }       // TIFFPlant pads an odd out-of-line value: keep the block the file's last bytes
        let headerAndDirectory = 8 + 2 + 12 + 4             // the plant's one entry, so the value starts at offset 26
        func kv(_ data: Data) throws -> Double? { try AcquisitionMetadata.tiff(data: data, convention: .app).highTensionKV?.value }
        func isTruncated(_ error: Error) -> Bool { if case TIFFError.truncated = error { true } else { false } }

        let exact = TIFFPlant([65027: .bytes(type: 1, stream)]).build()
        XCTAssertEqual(exact.count, headerAndDirectory + stream.count, "the plant ends exactly with the block")
        XCTAssertEqual(try kv(exact), 120, "a block that ends exactly at the last byte of the file reads")

        for over in [1, 2, 4096] {
            let data = TIFFPlant([65027: .claiming(count: stream.count + over, type: 1, stream)]).build()
            XCTAssertEqual(data.count, headerAndDirectory + stream.count, "the file is the same bytes: only the count grew")
            XCTAssertThrowsError(try kv(data), "a count \(over) byte(s) past the end of the file is no block") { XCTAssertTrue(isTruncated($0), "+\(over): \($0)") }
        }

        let far = TIFFPlant([65027: .claiming(count: 5000, type: 1, [UInt8](repeating: 0, count: 74))]).build()
        XCTAssertEqual(far.count, 100, "the review's reproducer: a 100-byte file, count 5000 at offset 26")
        XCTAssertThrowsError(try AcquisitionMetadata.tiff(data: far, convention: .app)) { XCTAssertTrue(isTruncated($0), "\($0)") }

        // An offset past the end of the file (the entry's value field is bytes 18 ..< 22 of this plant), the count small.
        var pointed = exact
        pointed.replaceSubrange(18 ..< 22, with: [0xE8, 0x03, 0, 0])        // 1000, little-endian
        XCTAssertGreaterThan(1000, pointed.count)
        XCTAssertThrowsError(try AcquisitionMetadata.tiff(data: pointed, convention: .app), "an offset past the end of the file") { XCTAssertTrue(isTruncated($0), "\($0)") }

        // Through a path (the app's way): the same bytes under .tif read empty: the throw is swallowed.
        let overrunning = TIFFPlant([65027: .claiming(count: stream.count + 1, type: 1, stream)]).build()
        XCTAssertTrue(AcquisitionMetadata.read(path: try DM4TestFile.write(overrunning, named: "overruns.tif", for: self)).isEmpty)
    }

    // MARK: The app hands the metadata over

    /// `AppState.read`, the one read the app makes of a file it opens, returns beside the image the metadata of THAT file:
    /// `AcquisitionMetadata.read(path:)` of the path it opened, which for the four-object file is the shown object's (200 kV,
    /// every field: `shownSTEM`; the decoys state 11, 80 and 300), and not empty. A second file of another voltage follows,
    /// so a read of a stale or fixed path cannot pass. Mutations (each red): `read` returns `AcquisitionMetadata()` for the
    /// metadata (the `isEmpty` and `shownSTEM` assertions), or reads another path — `url.deletingLastPathComponent().path`,
    /// `url.lastPathComponent` — (empty). A read of the wrong OBJECT of the right file is
    /// `testTheMetadataReadIsTheObjectOpenNowShowsAndNoOther`'s, not this test's.
    func testAppStateReadHandsOverTheMetadataOfTheFileItOpened() async throws {
        let path = try multiObjectDM4(named: "handed-over.dm4")
        let (opened, _, metadata) = try await AppState.read(URL(fileURLWithPath: path))
        XCTAssertEqual(opened.source, "ImageList.3 · STEM", "the image shown is object 3")
        XCTAssertFalse(metadata.isEmpty, "the file records its acquisition: it must arrive")
        XCTAssertEqual(metadata, AcquisitionMetadata.read(path: path), "what read(path:) gives for the file that was opened")
        XCTAssertEqual(metadata, Self.shownSTEM, "object 3's, every field: 200 kV, not the thumbnail's, the SI's or the later image's")

        let other = DM4TestFile.file([Plant.withTags(DM4TestFile.object(name: "B", dims: [3, 2], axes: nil),
                                                     Plant.imageTags(voltage: 120_000, magnification: 25_000), format: nil)])
        let otherPath = try DM4TestFile.write(other, named: "handed-over-too.dm4", for: self)
        let (_, _, second) = try await AppState.read(URL(fileURLWithPath: otherPath))
        XCTAssertEqual(second.highTensionKV?.value, 120, "the second file's own metadata, not the first's")
        XCTAssertEqual(second, AcquisitionMetadata.read(path: otherPath))
        XCTAssertNotEqual(second, metadata)
    }

    // MARK: ImageSession publishes the metadata with its image

    private static func image(_ name: String) -> CalibratedImage {
        CalibratedImage(width: 2, height: 1, pixels: [1, 2], x: nil, y: nil, fileName: name, source: "ImageList.1", voltage: nil)
    }
    private static func metadata(kV: Double) -> AcquisitionMetadata {
        var m = AcquisitionMetadata()
        m.highTensionKV = MetadataReading(kV)
        return m
    }
    private static let urlA = URL(fileURLWithPath: "/data/a.dm4")
    private static let urlB = URL(fileURLWithPath: "/data/b.dm4")

    /// Only the latest open publishes its metadata, with its image. Mutations (each red): `metadata` never stored,
    /// stored before the token guard (a superseded open would leave its values under the newer image).
    @MainActor func testTheMetadataIsPublishedWithItsImageUnderTheOpenToken() {
        let session = ImageSession()
        XCTAssertTrue(session.metadata.isEmpty, "no image, nothing recorded")
        let first = session.beginOpen()
        let second = session.beginOpen()
        XCTAssertFalse(session.finishOpen(first, image: Self.image("a"), url: Self.urlA, metadata: Self.metadata(kV: 100)))
        XCTAssertTrue(session.metadata.isEmpty, "a superseded open changes nothing, its metadata included")
        XCTAssertTrue(session.finishOpen(second, image: Self.image("b"), url: Self.urlB, metadata: Self.metadata(kV: 200)))
        XCTAssertEqual(session.metadata, Self.metadata(kV: 200))
        XCTAssertFalse(session.finishOpen(first, image: Self.image("a"), url: Self.urlA, metadata: Self.metadata(kV: 100)))
        XCTAssertEqual(session.metadata, Self.metadata(kV: 200), "a slower, earlier read never replaces the newer image's metadata")
    }

    /// A new image replaces the old image's metadata wholesale, even with an empty one: nothing of the previous file
    /// stays under the new image. Mutation: `if !metadata.isEmpty { self.metadata = metadata }` (red).
    @MainActor func testANewImageNeverKeepsThePreviousFilesMetadata() {
        let session = ImageSession()
        XCTAssertTrue(session.finishOpen(session.beginOpen(), image: Self.image("a"), url: Self.urlA, metadata: Self.metadata(kV: 300)))
        XCTAssertEqual(session.metadata, Self.metadata(kV: 300))
        XCTAssertTrue(session.finishOpen(session.beginOpen(), image: Self.image("b"), url: Self.urlB, metadata: AcquisitionMetadata()))
        XCTAssertTrue(session.metadata.isEmpty, "the second file records nothing: nothing is shown, not the first file's 300 kV")
    }

    /// A failed open keeps the image already shown and so its metadata. Mutation: `failOpen` resetting `metadata` (red).
    @MainActor func testAFailedOpenKeepsTheMetadataOfTheImageShown() {
        let session = ImageSession()
        XCTAssertTrue(session.finishOpen(session.beginOpen(), image: Self.image("a"), url: Self.urlA, metadata: Self.metadata(kV: 300)))
        XCTAssertTrue(session.failOpen(session.beginOpen()))
        XCTAssertEqual(session.image, Self.image("a"))
        XCTAssertEqual(session.metadata, Self.metadata(kV: 300), "the image on screen is still a.dm4's, with a.dm4's metadata")
    }
}

// MARK: - Plants

/// The tags the planted files hold, and the other bytes (a Velox XML, an FEI2 MRC).
private nonisolated enum Plant {
    typealias Node = DM4TestFile.Node

    /// A STEM image's ImageTags with every value the DM rules read, the stack builder's decoys (`Actual Magnification`,
    /// `Microscope Info.Name`) and a date whose uint16 string ends in a NUL (GMS writes some so): read by
    /// `AcquisitionMetadataReadTests.shownSTEM`.
    static func imageTags(voltage: Double, magnification: Double) -> [Node] {
        [
            .group("Microscope Info", [
                .double("Voltage", voltage),
                .double("Indicated Magnification", magnification),
                .double("Actual Magnification", 51_234),               // never read (rule g)
                .text("Illumination Mode", "STEM"),
                .text("Imaging Mode", "DIFFRACTION"),
                .double("STEM Camera Length", 150),
                .text("Name", "FEI Tecnai Remote"),                    // GMS's interface name: Session Info.Microscope comes first
            ]),
            .group("Session Info", [.text("Microscope", "FEI Titan")]),
            .group("DigiScan", [.double("Sample Time", 2)]),
            .group("DataBar", [.text("Acquisition Date", "27.08.2016\u{0}"), .text("Acquisition Time", "20:54:33")]),
            .group("Acquisition", [
                .group("Device", [.text("Name", "BM-UltraScan")]),
                .group("Parameters", [.group("Detector", [.double("exposure (s)", 0.5)])]),
            ]),
        ]
    }

    /// A TEM imaging image's tags, as the DM-saved TIFF of RosettaSciIO's test data is predicted to state them.
    static var temImagingTags: [Node] {
        [
            .group("Microscope Info", [
                .double("Voltage", 200_000),
                .double("Indicated Magnification", 51),
                .double("Actual Magnification", 83),                   // never read (rule g)
                .double("STEM Camera Length", 255),                    // DM writes 0, 1 or 255 outside STEM: not a length
                .text("Illumination Mode", "TEM"),
                .text("Imaging Mode", "IMAGING"),
                .text("Name", "FEI Tecnai"),
            ]),
            .group("Acquisition", [.group("Device", [.text("Name", "BM-UltraScan")]),
                                   .group("Parameters", [.group("Detector", [.double("exposure (s)", 0.5)])])]),
            .group("DataBar", [.text("Acquisition Date", "20/07/2015"), .text("Acquisition Time", "18:48:25")]),
        ]
    }

    static func voltageOnly(_ volts: Double) -> [Node] {
        [.group("Microscope Info", [.double("Voltage", volts)])]
    }

    /// `object` with `tags` appended to its ImageTags, and `Meta Data.Format` = `format` when given.
    static func withTags(_ object: Node, _ tags: [Node], format: String?) -> Node {
        guard case .group(let label, let kids) = object else { preconditionFailure("not an object") }
        let extra = format.map { [Node.group("Meta Data", [.text("Format", $0)])] } ?? []
        return .group(label, kids.map { kid in
            guard case .group("ImageTags", let existing) = kid else { return kid }
            return .group("ImageTags", existing + tags + extra)
        })
    }

    /// A minimal Velox XML stating only the acceleration voltage (V).
    static func velox(voltage: Double) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Metadata><Optics><AccelerationVoltage>\(Int(voltage))</AccelerationVoltage></Optics></Metadata>"
    }

    /// An MRC2014 file with a FEI2 extended header whose first record states only HT (volts, little-endian machine
    /// stamp, mrcfile's layout: HT f8 at record byte 84, bit 5 of Bitmask 1 at byte 8). No pixel data: the metadata
    /// reader reads headers only.
    static func fei2MRC(voltage: Double) -> Data {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> UInt32(8 * $0)) & 0xFF) } }
        var header = [UInt8](repeating: 0, count: 1024)
        header.replaceSubrange(92..<96, with: le32(888))                        // NSYMBT
        header.replaceSubrange(104..<108, with: Array("FEI2".utf8))             // EXTTYP
        header.replaceSubrange(208..<212, with: Array("MAP ".utf8))
        header.replaceSubrange(212..<216, with: [0x44, 0x44, 0, 0])             // little-endian
        var record = [UInt8](repeating: 0, count: 888)
        record.replaceSubrange(0..<4, with: le32(888))                          // "Metadata size": the record states its own size
        record.replaceSubrange(8..<12, with: le32(1 << 5))                      // Bitmask 1: HT
        record.replaceSubrange(84..<92, with: (0..<8).map { UInt8((voltage.bitPattern >> UInt64(8 * $0)) & 0xFF) })
        return Data(header + record)
    }
}

/// A bare DM4 tag stream: the grammar of `DM4TestFile.file` (version 4, big-endian tag headers, 8-byte sizes, strings
/// as ushort arrays), its root group the tags themselves with no `ImageList`, as DM stores an image's ImageTags in
/// TIFF tag 65027. Written here because `DM4TestFile` always wraps an `ImageList`.
private nonisolated enum BareDM4 {
    typealias Node = DM4TestFile.Node

    static func stream(_ tags: [Node], paddedTo size: Int = 0) -> [UInt8] {
        pad([0, 0, 0, 4] + u64be(0) + [0, 0, 0, 1] + [1, 0] + u64be(UInt64(tags.count)) + tags.flatMap(encode), to: size)
    }

    /// `bytes` followed by zeros up to `size` bytes (unchanged when already that long).
    static func pad(_ bytes: [UInt8], to size: Int) -> [UInt8] {
        bytes.count >= size ? bytes : bytes + [UInt8](repeating: 0, count: size - bytes.count)
    }

    private static func u16be(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func u64be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) } }
    private static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> UInt64(8 * $0)) & 0xFF) } }
    private static let delimiter: [UInt8] = [37, 37, 37, 37]

    private static func head(_ tag: UInt8, _ label: String) -> [UInt8] {
        [tag] + u16be(label.utf8.count) + Array(label.utf8) + u64be(0)
    }

    private static func encode(_ node: Node) -> [UInt8] {
        switch node {
        case .int(let l, let v):
            return head(21, l) + delimiter + u64be(1) + u64be(3) + le(UInt64(UInt32(bitPattern: v)), 4)
        case .float(let l, let v):
            return head(21, l) + delimiter + u64be(1) + u64be(6) + le(UInt64(v.bitPattern), 4)
        case .double(let l, let v):
            return head(21, l) + delimiter + u64be(1) + u64be(7) + le(v.bitPattern, 8)
        case .text(let l, let s):
            let units = Array(s.utf16)
            return head(21, l) + delimiter + u64be(3) + u64be(20) + u64be(4) + u64be(UInt64(units.count))
                + units.flatMap { le(UInt64($0), 2) }
        case .group(let l, let kids):
            return head(20, l) + [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        case .blob:
            preconditionFailure("BareDM4: a tag stream holds no blob in these tests")
        }
    }
}

/// A little-endian TIFF with exactly the tags a case plants: a header, one directory at offset 8, out-of-line values
/// after it. The metadata reader reads only the first directory's entries, so no image tag is needed.
private nonisolated struct TIFFPlant {
    enum Value {
        /// An ASCII (type 2) tag, NUL-terminated as TIFF stores text.
        case ascii(String)
        /// A tag of `type` (1 BYTE, 2 ASCII, 7 UNDEFINED) holding exactly these bytes, count = bytes.count.
        case bytes(type: Int, [UInt8])
        /// A tag of `type` that SAYS it holds `count` bytes while the file holds only these: a count that runs past the end
        /// of the file (the entry's count is the claim, the bytes are written as `.bytes` writes them).
        case claiming(count: Int, type: Int, [UInt8])
        case short(UInt16)
    }
    let tags: [UInt16: Value]

    init(_ tags: [UInt16: Value]) { self.tags = tags }

    func build() -> Data {
        let keys = tags.keys.sorted()
        let heapStart = 8 + 2 + 12 * keys.count + 4
        var directory = le16(keys.count)
        var heap: [UInt8] = []
        for key in keys {
            guard let value = tags[key] else { continue }
            let (type, count, payload) = encode(value)
            directory += le16(Int(key)) + le16(type) + le32(count)
            if payload.count <= 4 {
                directory += payload + [UInt8](repeating: 0, count: 4 - payload.count)
            } else {
                directory += le32(heapStart + heap.count)
                heap += payload
                if heap.count % 2 == 1 { heap.append(0) }
            }
        }
        directory += le32(0)
        return Data([0x49, 0x49] + le16(42) + le32(8) + directory + heap)
    }

    private func encode(_ value: Value) -> (type: Int, count: Int, payload: [UInt8]) {
        switch value {
        case .ascii(let s): (2, s.utf8.count + 1, Array(s.utf8) + [0])
        case .bytes(let type, let b): (type, b.count, b)
        case .claiming(let count, let type, let b): (type, count, b)
        case .short(let v): (3, 1, le16(Int(v)))
        }
    }

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
}

/// What a Velox file says about its acquisition reaches the Info panel under the kit's `.rosettaSciIO` reading: the magnification, the camera length, the exposure and
/// the mode are read (the `.app` reading left them "not read from .emd files yet"). Red under: `convention: .app` for an `.emd`.
nonisolated final class VeloxAcquisitionReadTests: XCTestCase {
    func testAVeloxFileNowReadsMagnificationCameraLengthExposureAndMode() throws {
        let path = try FileRoutingTests.reference("mac4DSTEM/velox-parity/velox_emd_version11/Test SI 16x16 215 kx.emd")
        let m = AcquisitionMetadata.read(path: path)
        XCTAssertTrue(m.unread.isEmpty, "nothing is left as not read: \(m.unread)")
        XCTAssertEqual(m.highTensionKV?.value, 300)
        XCTAssertEqual(m.magnification?.value, 225_000, "the magnification the file stores (StemMagnification)")
        XCTAssertEqual(m.cameraLengthMM?.value ?? 0, 115.9, accuracy: 1e-9, "metres in the file, millimetres shown")
        XCTAssertEqual(m.detector?.value, "HAADF")
    }

    func testTheFixtureFilesStillReadTheirHighTension() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "velox-haadf-last", withExtension: "emd"))
        let m = AcquisitionMetadata.read(path: url.path)
        XCTAssertEqual(m.highTensionKV?.value, 200)
        XCTAssertTrue(m.unread.isEmpty)
    }
}
