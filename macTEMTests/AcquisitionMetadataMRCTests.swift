//
//  AcquisitionMetadataMRCTests.swift
//  The MRC reader of AcquisitionMetadata on FEI1/FEI2
//  files built in memory with known values: the planted truth is the bytes written here. The record's field table
//  below is mrcfile 1.5.4's (generated from `fei2_dtype_big_endian`, widths only); offsets and bitmask bits are
//  derived by walking it, so these tests do not share the production code's constants. Two real first records
//  (RosettaSciIO's HAADFscan.mrc and 4DSTEMscan.mrc, expected values from mrcfile) pin the offsets against Thermo
//  bytes. The parity against mrcfile on the whole files is tools/parity/metadata-parity.
//
//  Three notes ride on MRC readings, each pinned here by its literal text (a reader is told them beside the value):
//  the camera length "unvalidated: the mode is not checked" (rule c is an open deviation: the mode is undecoded),
//  the exposure and the mode "unvalidated: no published reader reads it", and the date "clock of the writer, zone
//  not stored" (the two pinned files disagree on the zone, so the note must not say "local time").
//

import XCTest
import FormatoCore
import FormatoMRC
import TEMCore
@testable import macTEM

nonisolated final class AcquisitionMetadataMRCTests: XCTestCase {

    // MARK: conversions

    func testHighTensionIsStoredInVoltsAndShownInKilovolts() throws {
        var f = FEIFile()
        f.put("HT", 200_000)
        XCTAssertEqual(try read(f).highTensionKV, MetadataReading(200))
        var g = FEIFile()
        g.put("HT", 80_000)
        XCTAssertEqual(try read(g).highTensionKV, MetadataReading(80))
    }

    func testCameraLengthIsStoredInMetresAndShownInMillimetresAndSaysItsModeIsNotChecked() throws {
        // Mutation (AcquisitionMetadata+MRC.swift): drop `note:` from the cameraLengthMM reading, or give it
        // unvalidatedNote / localTimeNote — the camera length would then carry no, or the wrong, label.
        var f = FEIFile()
        f.put("Camera length", 0.0911)
        XCTAssertEqual(try read(f).cameraLengthMM, MetadataReading(0.0911 * 1e3, note: Self.modeUnchecked))
        var g = FEIFile()
        g.put("Camera length", 0.2)
        XCTAssertEqual(try read(g).cameraLengthMM, MetadataReading(0.2 * 1e3, note: Self.modeUnchecked))
        // Shown as stored whatever the mode integers say: rule (c)'s guard is an open deviation, so a record in
        // Instrument mode 1 / Projection mode 1 (not decoded) keeps its camera length, with the same note.
        var imaging = FEIFile()
        imaging.put("Camera length", 0.2)
        imaging.put("Instrument mode", int: 1)
        imaging.put("Projection mode", int: 1)
        XCTAssertEqual(try read(imaging).cameraLengthMM, MetadataReading(0.2 * 1e3, note: Self.modeUnchecked))
        XCTAssertEqual(Self.modeUnchecked, "unvalidated: the mode is not checked")
    }

    func testDwellIsStoredInSecondsAndShownInMicroseconds() throws {
        var f = FEIFile()
        f.put("Dwell time", 0.01)
        XCTAssertEqual(try read(f).dwellUS, MetadataReading(0.01 * 1e6))
        var g = FEIFile()
        g.put("Dwell time", 3.5e-6)
        XCTAssertEqual(try read(g).dwellUS, MetadataReading(3.5e-6 * 1e6))
    }

    func testAQuantityThatConvertsToZeroOrInfinityIsNotRecordedAndOneThatStaysFiniteIs() throws {
        // Mutation (AcquisitionMetadata+MRC.swift): test positive() on the stored value, before the unit conversion
        // (V to kV, m to mm, s to µs) — the finite 5e-324 V then reads as 0.0 kV, 1e306 m as inf mm, 1e305 s as
        // inf µs. (A denormal camera length or dwell stays positive and finite after ×1e3 / ×1e6; only a huge
        // one overflows.)
        let gone: [(name: String, stored: Double, shown: (AcquisitionMetadata) -> Bool)] = [
            ("HT", 5e-324, { $0.highTensionKV != nil }),
            ("Camera length", 1e306, { $0.cameraLengthMM != nil }),
            ("Dwell time", 1e305, { $0.dwellUS != nil }),
        ]
        for (name, stored, shown) in gone {
            var f = FEIFile()
            f.put(name, stored)
            XCTAssertFalse(shown(try read(f)), "\(name) = \(stored) converts to 0 or infinity")
        }
        // The same quantities, still finite and positive after the conversion, are read, with the converted number.
        var big = FEIFile()
        big.put("HT", 1e300)
        big.put("Camera length", 1e305)
        big.put("Dwell time", 1e300)
        let m = try read(big)
        XCTAssertEqual(m.highTensionKV, MetadataReading(1e300 / 1e3))
        XCTAssertEqual(m.cameraLengthMM, MetadataReading(1e305 * 1e3, note: Self.modeUnchecked))
        XCTAssertEqual(m.dwellUS, MetadataReading(1e300 * 1e6))
        var small = FEIFile()
        small.put("Camera length", 5e-324)
        small.put("Dwell time", 5e-324)
        XCTAssertEqual(try read(small).cameraLengthMM, MetadataReading(5e-324 * 1e3, note: Self.modeUnchecked))
        XCTAssertEqual(try read(small).dwellUS, MetadataReading(5e-324 * 1e6))
    }

    // MARK: the bitmasks

    func testAClearBitIsNotRecordedWhateverTheBytesHold() throws {
        var f = FEIFile()
        f.plantEverything(recorded: false)
        // The bytes are there: the same record with the bits set reads every field.
        var set = f
        set.setMask(0, 0xFFFF_FFFF); set.setMask(1, 0xFFFF_FFFF); set.setMask(2, 0xFFFF_FFFF); set.setMask(3, 0xFFFF_FFFF)
        XCTAssertEqual(try read(set).highTensionKV, MetadataReading(300))
        XCTAssertEqual(try read(set).dwellUS, MetadataReading(2.5e-5 * 1e6))
        XCTAssertEqual(try read(set).detector, MetadataReading("STEMDET"))
        XCTAssertEqual(try read(f), AcquisitionMetadata(), "no bit set: nothing is recorded, nonzero bytes or not")
        // One bit set: that field only.
        f.setRecorded("HT")
        var only = AcquisitionMetadata()
        only.highTensionKV = MetadataReading(300)
        XCTAssertEqual(try read(f), only)
    }

    func testEveryFieldIsReadFromItsOwnBit() throws {
        let expected: [(field: String, label: String)] = [
            ("Timestamp", "acquired"), ("Microscope type", "instrument"), ("HT", "highTension"),
            ("Instrument mode", "mode"), ("Magnification", "magnification"), ("Camera length", "cameraLength"),
            ("Integration time", "exposure"), ("Camera name", "detector=CAM"),
            ("STEM Detector name", "detector=STEMDET"), ("Dwell time", "dwell"),
            ("Detector commercial name", "detector=COMM"),
        ]
        for (field, label) in expected {
            var f = FEIFile()
            f.plantEverything(recorded: false)
            f.setRecorded(field)
            XCTAssertEqual(summary(try read(f)), [label], "only the bit of \(field)")
        }
        // The six bits of "Unused range" are why Magnification is bit 31 of mask 1 and Instrument mode bit 25.
        XCTAssertEqual(FEIFile.place("Instrument mode").bit, 25)
        XCTAssertEqual(FEIFile.place("Magnification").bit, 31)
        XCTAssertEqual(FEIFile.place("Camera length").bit, 0)
        XCTAssertEqual(FEIFile.place("Camera length").mask, 1)
    }

    func testANonPositiveOrNonFiniteQuantityIsNotRecordedEvenWhenItsBitIsSet() throws {
        let fields: [(name: String, value: (AcquisitionMetadata) -> Bool)] = [
            ("HT", { $0.highTensionKV != nil }), ("Magnification", { $0.magnification != nil }),
            ("Camera length", { $0.cameraLengthMM != nil }), ("Dwell time", { $0.dwellUS != nil }),
            ("Integration time", { $0.exposureS != nil }),
        ]
        for (name, isRecorded) in fields {
            for bad in [0.0, -0.0, -1.0, -1e-9, Double.nan, Double.infinity, -Double.infinity] {
                var f = FEIFile()
                f.put(name, bad)
                XCTAssertFalse(isRecorded(try read(f)), "\(name) = \(bad)")
            }
            var f = FEIFile()
            f.put(name, 1.5)
            XCTAssertTrue(isRecorded(try read(f)), "\(name) = 1.5 is read")
        }
    }

    func testMagnificationZeroWithItsBitSetIsNotRecordedAsZero() throws {
        // A STEM record: HT recorded, Magnification written as 0.0 and flagged as written.
        var f = FEIFile()
        f.put("HT", 300_000)
        f.put("Magnification", 0.0)
        var expected = AcquisitionMetadata()
        expected.highTensionKV = MetadataReading(300)
        XCTAssertEqual(try read(f), expected)
        XCTAssertNil(try read(f).magnification)
        var g = FEIFile()
        g.put("Magnification", 25_000)
        XCTAssertEqual(try read(g).magnification, MetadataReading(25_000))
    }

    // MARK: the date

    func testTimestampIsAnOLEAutomationDateOnTheWritersClockTruncatedToTheSecond() throws {
        // Mutation (AcquisitionMetadata+MRC.swift): `note: localTimeNote` instead of writerClockNote — the pinned
        // files disagree on the zone (HAADFscan.mrc's OLE value is UTC, 4DSTEMscan.mrc's is UTC+1), so no MRC date
        // may be called local time. The digits are the same under both labels.
        let cases: [(days: Double, expected: String)] = [
            (1.25, "1899-12-31 06:00:00"),
            (2.0, "1900-01-01 00:00:00"),
            (61.0, "1900-03-01 00:00:00"),               // 1900 is not a leap year (no Excel day 60)
            (36585.5, "2000-02-29 12:00:00"),            // 2000 is
            (73109.0, "2100-02-28 00:00:00"),
            (73110.0, "2100-03-01 00:00:00"),            // 2100 is not
            (45657.99998842592, "2024-12-31 23:59:59"),
            (44900.50008680556, "2022-12-05 12:00:07"),  // 12:00:07.5: truncated, not rounded to :08
            (44900.509108796294, "2022-12-05 12:13:07"), // HAADFscan.mrc: 12:13:07 only after the µs rounding
            (44900.550779478755, "2022-12-05 13:13:07"), // 4DSTEMscan.mrc: 13:13:07.346964
            (0.9999999999999999, "1899-12-31 00:00:00"), // the µs rounding carries into the next day
            (2_958_465.0, "9999-12-31 00:00:00"),
        ]
        for (days, expected) in cases {
            var f = FEIFile()
            f.put("Timestamp", days)
            XCTAssertEqual(try read(f).acquired, MetadataReading(expected, note: Self.writerClock), "\(days)")
        }
        XCTAssertEqual(AcquisitionMetadata.writerClockNote, "clock of the writer, zone not stored")
        XCTAssertEqual(Self.writerClock, AcquisitionMetadata.writerClockNote)
        XCTAssertNotEqual(AcquisitionMetadata.writerClockNote, AcquisitionMetadata.localTimeNote, "Velox and DM keep theirs")
        for bad in [0.0, -3.0, Double.nan, Double.infinity, 2_958_466.0, 3e9] {
            var f = FEIFile()
            f.put("Timestamp", bad)
            XCTAssertNil(try read(f).acquired, "\(bad)")
        }
    }

    // MARK: byte order

    func testTheRecordFollowsTheHeadersByteOrderAndTheBitmasksStayLittleEndian() throws {
        // Mutations (AcquisitionMetadata+MRC.swift): the record always read in one byte order, or the bitmasks in the
        // record's order; and, for the labels this expectation carries, the date note localTimeNote, or the camera
        // length / mode / exposure reading without its note.
        var expected = AcquisitionMetadata()
        expected.highTensionKV = MetadataReading(300)
        expected.magnification = MetadataReading(50_000)
        expected.cameraLengthMM = MetadataReading(0.15 * 1e3, note: Self.modeUnchecked)
        expected.detector = MetadataReading("STEMDET")
        expected.dwellUS = MetadataReading(2.5e-5 * 1e6)
        expected.exposureS = MetadataReading(0.25, note: Self.unvalidated)
        expected.acquired = MetadataReading("2022-12-05 12:00:00", note: Self.writerClock)
        expected.instrument = MetadataReading("Titan Themis")
        expected.mode = MetadataReading("2", note: Self.unvalidated)
        let orders: [(big: Bool, stamp: [UInt8])] = [(false, [0x44, 0x44, 0, 0]), (false, [0x44, 0x41, 0, 0]), (true, [0x11, 0x11, 0, 0])]
        for (big, stamp) in orders {
            var f = FEIFile(bigEndian: big)
            f.plantEverything(recorded: true)
            XCTAssertEqual(try AcquisitionMetadata.mrc(data: f.file(stamp: stamp), convention: .app), expected, "big-endian \(big), stamp \(stamp)")
        }
    }

    // MARK: the two real records

    func testTheFirstRecordsOfTheTwoRealFEI2Files() throws {
        // Mutations (AcquisitionMetadata+MRC.swift): any offset or bit of a field read here moved; and, for the labels,
        // the date note localTimeNote, or the camera length / mode reading without its note.
        var haadf = AcquisitionMetadata()
        haadf.highTensionKV = MetadataReading(300)
        haadf.cameraLengthMM = MetadataReading(0.0911 * 1e3, note: Self.modeUnchecked)
        haadf.detector = MetadataReading("HAADF")
        haadf.dwellUS = MetadataReading(0.01 * 1e6)
        haadf.acquired = MetadataReading("2022-12-05 12:13:07", note: Self.writerClock)
        haadf.instrument = MetadataReading("Spectra")
        haadf.mode = MetadataReading("2", note: Self.unvalidated)
        XCTAssertEqual(try read(FEIFile(record: Self.haadfRecord)), haadf,
                       "HAADFscan.mrc: Magnification 0.0 unset, Integration time 0.0 set, STEM Detector name HAADF")
        var fourD = AcquisitionMetadata()
        fourD.highTensionKV = MetadataReading(300)
        fourD.cameraLengthMM = MetadataReading(0.08817938623311208 * 1e3, note: Self.modeUnchecked)
        fourD.detector = MetadataReading("Ceta-S speed")
        fourD.dwellUS = MetadataReading(0.01 * 1e6)
        fourD.acquired = MetadataReading("2022-12-05 13:13:07", note: Self.writerClock)
        XCTAssertEqual(try read(FEIFile(record: Self.fourDRecord)), fourD,
                       "4DSTEMscan.mrc: the detector is only in Detector commercial name; no instrument, no mode")        // The same bytes read the wrong way round are not these numbers (the records are little-endian).
        let wrong = FEIFile(record: Self.haadfRecord, bigEndian: true)
        XCTAssertNotEqual(try AcquisitionMetadata.mrc(data: wrong.file(), convention: .app), haadf, "a big-endian stamp over little-endian bytes")
    }

    // MARK: which files carry a record

    func testOnlyAnFEIExtendedHeaderWhoseRecordStatesItsSizeIsRead() throws {
        var f = FEIFile()
        f.put("HT", 200_000)
        let ht = MetadataReading(200.0)
        XCTAssertEqual(try AcquisitionMetadata.mrc(data: f.file(), convention: .app).highTensionKV, ht)
        // Not FEI: the same bytes under another or no EXTTYP, and no extended header at all.
        XCTAssertTrue(try AcquisitionMetadata.mrc(data: f.file(exttyp: "SERI"), convention: .app).isEmpty)
        XCTAssertTrue(try AcquisitionMetadata.mrc(data: f.file(exttyp: "fei2"), convention: .app).isEmpty)
        XCTAssertTrue(try AcquisitionMetadata.mrc(data: f.file(exttyp: "\0\0\0\0"), convention: .app).isEmpty)
        XCTAssertTrue(try AcquisitionMetadata.mrc(data: f.file(claimedExtended: 0), convention: .app).isEmpty)
        // FEI but shorter than one record, or a record that does not state its own size.
        XCTAssertTrue(try AcquisitionMetadata.mrc(data: f.file(claimedExtended: 887), convention: .app).isEmpty)
        var other = f
        other.put("Metadata size", int: 768)
        XCTAssertTrue(try AcquisitionMetadata.mrc(data: other.file(), convention: .app).isEmpty, "FEI2 type, FEI1 size")
        var zero = FEIFile(record: [UInt8](repeating: 0, count: 888))
        zero.put("Metadata size", int: 0)
        XCTAssertTrue(try AcquisitionMetadata.mrc(data: zero.file(), convention: .app).isEmpty)
        // The length of the extended header is not the test: RosettaSciIO's 128 × 1024 and HAADFscan.mrc's
        // 888 × 1024 both read, as does the bare 888-byte record.
        for total in [888, 128 * 1024, 888 * 1024] {
            XCTAssertEqual(try AcquisitionMetadata.mrc(data: f.file(padding: total - 888), convention: .app).highTensionKV, ht, "\(total) bytes")
        }
    }

    func testAnFEI1RecordIsReadAndHasNoCommercialName() throws {
        var f = FEIFile(fei2: false)
        f.plantEverything(recorded: true)
        f.setMask(3, 0xFFFF_FFFF)          // Bitmask 4's bit 7 says "Detector commercial name", a FEI2 field (byte 804)
        let m = try read(f)
        XCTAssertEqual(m.highTensionKV, MetadataReading(300))
        XCTAssertEqual(m.dwellUS, MetadataReading(2.5e-5 * 1e6))
        XCTAssertEqual(m.detector, MetadataReading("STEMDET"))
        f.setRecorded("STEM Detector name", false)
        f.setRecorded("Camera name", false)
        XCTAssertNil(try read(f).detector, "outside the 768-byte record: nothing, and no trap")
        f.setRecorded("Camera name")
        XCTAssertEqual(try read(f).detector, MetadataReading("CAM"))
    }

    // MARK: the texts

    func testDetectorIsTheSTEMDetectorElseTheCameraElseTheCommercialNameAndTextIsFixedWidth() throws {
        var f = FEIFile()
        f.put("Camera name", text: "BM-Ceta")
        f.put("Detector commercial name", text: "Ceta-S speed")
        XCTAssertEqual(try read(f).detector, MetadataReading("BM-Ceta"))
        f.put("STEM Detector name", text: "HAADF")
        XCTAssertEqual(try read(f).detector, MetadataReading("HAADF"), "the STEM detector comes first")
        f.put("STEM Detector name", text: "   ")          // recorded but blank: falls through to the camera
        XCTAssertEqual(try read(f).detector, MetadataReading("BM-Ceta"))
        f.put("Camera name", bytes: [0, 0, 0, 0])         // blank as well: falls through to the commercial name
        XCTAssertEqual(try read(f).detector, MetadataReading("Ceta-S speed"))
        f.put("Detector commercial name", bytes: Array("  \t ".utf8))
        XCTAssertNil(try read(f).detector, "nothing but blanks: not recorded, never an empty string")
        // Fixed width: padded with spaces and NULs, cut at the first NUL, 16 full bytes.
        f.put("STEM Detector name", bytes: Array("  HAADF  ".utf8) + [0, 0, 0])
        XCTAssertEqual(try read(f).detector, MetadataReading("HAADF"))
        f.put("STEM Detector name", bytes: Array("DF4".utf8) + [0] + Array("junk".utf8))
        XCTAssertEqual(try read(f).detector, MetadataReading("DF4"), "bytes after the first NUL are not text")
        f.put("STEM Detector name", bytes: Array("ABCDEFGHIJKLMNOP".utf8))
        XCTAssertEqual(try read(f).detector, MetadataReading("ABCDEFGHIJKLMNOP"))
        // The instrument is read the same way.
        f.put("Microscope type", text: "Spectra  ")
        XCTAssertEqual(try read(f).instrument, MetadataReading("Spectra"))
    }

    func testExposureIsTheIntegrationTimeAndSaysItIsUnvalidated() throws {
        // Mutation (AcquisitionMetadata+MRC.swift): the exposure reading without `note:`, or with modeUncheckedNote;
        // or Frame time (offset 579) read in place of Integration time.
        var f = FEIFile()
        f.put("Integration time", 0.5)
        f.put("Frame time", 2.72)           // a frame time is not an exposure
        f.put("Dwell time", 0.01)
        XCTAssertEqual(try read(f).exposureS, MetadataReading(0.5, note: Self.unvalidated))
        XCTAssertEqual(Self.unvalidated, "unvalidated: no published reader reads it")
        XCTAssertEqual(try read(f).dwellUS, MetadataReading(0.01 * 1e6), "and its dwell carries no such note")
    }

    func testModeIsTheInstrumentModeIntegerAsStoredAndSaysItIsUnvalidated() throws {
        // Mutation (AcquisitionMetadata+MRC.swift): drop `note:` from the mode reading — a bare "2" would then
        // look like a decoded mode name, though no published reader reads the enumeration.
        var f = FEIFile()
        f.put("Instrument mode", int: 2)
        f.put("Projection mode", int: 1)
        XCTAssertEqual(try read(f).mode, MetadataReading("2", note: Self.unvalidated))
        f.put("Instrument mode", int: 1)
        XCTAssertEqual(try read(f).mode, MetadataReading("1", note: Self.unvalidated))
        f.put("Instrument mode", int: 0)
        XCTAssertEqual(try read(f).mode, MetadataReading("0", note: Self.unvalidated), "0 is a stored value, not an absent one")
        f.put("Instrument mode", int: 2, recorded: false)
        XCTAssertNil(try read(f).mode)
    }

    // MARK: refusals and slices

    func testANonMRCHeaderIsRefusedInTheImageReadersWordsAndAHeaderAloneReads() throws {
        func refusal(_ data: Data) -> MRCImageReader.Refusal? {
            do { _ = try AcquisitionMetadata.mrc(data: data, convention: .app); return nil } catch { return (error as? MRCError).map(MRCImageReader.Refusal.init) }
        }
        func imageRefusal(_ data: Data) -> MRCImageReader.Refusal? {
            do { _ = try MRCImageReader.read(data: data, fileName: "x.mrc"); return nil } catch { return error as? MRCImageReader.Refusal }
        }
        let f = FEIFile()
        let cases: [(data: Data, expected: MRCImageReader.Refusal)] = [
            (Data(count: 100), .notMRC("100 bytes, shorter than an MRC header")),
            (f.file(map: "NOPE"), .notMRC("no \"MAP \" id")),
            (f.file(stamp: [0, 0, 0, 0]), .byteOrder(stamp: [0, 0, 0, 0])),
            (f.file(claimedExtended: 1_000_000), .truncated),
            (f.file(claimedExtended: -1), .truncated),
        ]
        for (data, expected) in cases {
            XCTAssertEqual(refusal(data), expected)
            XCTAssertEqual(imageRefusal(data), expected, "the image reader says the same")
        }
        // A header with no extended header and no pixels is not an error here: nothing recorded.
        XCTAssertEqual(try AcquisitionMetadata.mrc(data: f.headerOnly(), convention: .app), AcquisitionMetadata())
    }

    func testADataSliceReadsLikeTheWholeData() throws {
        var f = FEIFile()
        f.plantEverything(recorded: true)
        let whole = f.file()
        let padded = Data(repeating: 0xAB, count: 37) + whole
        let slice = padded.dropFirst(37)
        XCTAssertEqual(slice.startIndex, 37)
        let fromSlice = try AcquisitionMetadata.mrc(data: slice, convention: .app)
        XCTAssertFalse(fromSlice.isEmpty)
        XCTAssertEqual(fromSlice, try AcquisitionMetadata.mrc(data: whole, convention: .app))
    }

    // MARK: helpers

    /// The three notes an MRC reading can carry, as the reader must say them (literal text, not the production constants).
    private static let unvalidated = "unvalidated: no published reader reads it"
    private static let modeUnchecked = "unvalidated: the mode is not checked"
    private static let writerClock = "clock of the writer, zone not stored"

    private func read(_ f: FEIFile) throws -> AcquisitionMetadata { try AcquisitionMetadata.mrc(data: f.file(), convention: .app) }

    /// What is recorded, as sorted labels — a field that is read at the wrong bit shows as the wrong label.
    private func summary(_ m: AcquisitionMetadata) -> [String] {
        var labels: [String] = []
        if m.highTensionKV != nil { labels.append("highTension") }
        if m.magnification != nil { labels.append("magnification") }
        if m.cameraLengthMM != nil { labels.append("cameraLength") }
        if let d = m.detector { labels.append("detector=\(d.value)") }
        if m.dwellUS != nil { labels.append("dwell") }
        if m.exposureS != nil { labels.append("exposure") }
        if m.acquired != nil { labels.append("acquired") }
        if m.instrument != nil { labels.append("instrument") }
        if m.mode != nil { labels.append("mode") }
        return labels.sorted()
    }

    /// The first extended-header record of RosettaSciIO's HAADFscan.mrc (EXTTYP FEI2, NSYMBT 888 × 1024), bytes 0..<619
    /// (the rest is zero), as base64.
    private static let haadfRecord: [UInt8] = [UInt8](Data(base64Encoded: [
        "eAMAAAIAAAC/z8B+xoeeSpDs5UBTcGVjdHJhAAAAAAAAAAAAMzgxNAAAAAAAAAAAAAAAAFZlbG94AAAAAAAAAAAAAAAzLjcu",
        "MC44NzItYjBhN2JhAAAAAIBPEkEAAAAAAAAAANNfTg8vn4A/AAAAAAAAAABKcO5z4AP5PlztS7u93N2+AAbN1YpoHr4AAAAA",
        "AAAAAAAAAAAAAAAAHdz7WEVkOD4d3PtYRWQ4PgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAALKxt4eVN+Y+VP3eIVP2Vj8AAAAAAAAAAAIAAAABAAAASE0AAAAAAAAAAAAAAAAAAE5vbmUAAAAAAAAAAAAAAAACAAAA",
        "AAAAAAAAAAAAOwD/AMNkqmBUUrc/BgAAAAAAAAAAAAAA6tNpsOoH2T8PUdjupFeNP1Byb2JlAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAC",
        "AAAAQk0tQ2V0YQAAAAAAAAAAAIADAACAAwAAgAQAAIAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAICDfwAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAASEFBREYAAAAAAAAAAAAAAIsbka5dM0NA2HjpJjEI/L8AAAAAAAAAAAAAAAAAAAAAAAAAAHsUrkfh",
        "eoQ/w/UoXI/CBUAAAAAAAAAAAAABAAAAAQAAHdz7WEVkuD4d3PtYRWS4Pg==",
    ].joined(separator: "")) ?? Data())

    /// The first record of 4DSTEMscan.mrc (EXTTYP FEI2, 256 frames), bytes 0..<816 (the rest is zero).
    private static let fourDRecord: [UInt8] = [UInt8](Data(base64Encoded: [
        "eAMAAAIAAAAhwAAAEkn8n5Hs5UAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAIBPEkEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAMwilUEAAAAAzCKVQQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAQDwACp1DZzskrY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAHAAAABwAAAAkAAAAJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAfgAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHsUrkfh",
        "eoQ/AAAAAAAAAAAAAAAAAAAAABAAAAAQAAAAHdz7WEVkuD4d3PtYRWS4PgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABCbHz1XScKQAAAAAAAAAAA",
        "AAAAABTGL5wT7wUAQ2V0YS1TIHNwZWVk",
    ].joined(separator: "")) ?? Data())
}

/// A planted FEI1/FEI2 MRC file: one extended-header record in the header's byte order (the four bitmasks always
/// little-endian, as mrcfile's dtype has them), the fields of mrcfile 1.5.4 by name.
private nonisolated struct FEIFile {
    /// mrcfile 1.5.4 dtypes.py `fei2_dtype_big_endian` (lines 104-226): field name and width in bytes. FEI1 is its
    /// first 99 fields (768 bytes, through "Alpha tilt max"); a "Bitmask n" starts the bit count of the fields after it.
    static let layout: [(name: String, width: Int)] = [
        ("Metadata size", 4), ("Metadata version", 4), ("Bitmask 1", 4),
        ("Timestamp", 8), ("Microscope type", 16), ("D-Number", 16),
        ("Application", 16), ("Application version", 16), ("HT", 8),
        ("Dose", 8), ("Alpha tilt", 8), ("Beta tilt", 8),
        ("X-Stage", 8), ("Y-Stage", 8), ("Z-Stage", 8),
        ("Tilt axis angle", 8), ("Dual axis rotation", 8), ("Pixel size X", 8),
        ("Pixel size Y", 8), ("Unused range", 48), ("Defocus", 8),
        ("STEM Defocus", 8), ("Applied defocus", 8), ("Instrument mode", 4),
        ("Projection mode", 4), ("Objective lens mode", 16), ("High magnification mode", 16),
        ("Probe mode", 4), ("EFTEM On", 1), ("Magnification", 8),
        ("Bitmask 2", 4), ("Camera length", 8), ("Spot index", 4),
        ("Illuminated area", 8), ("Intensity", 8), ("Convergence angle", 8),
        ("Illumination mode", 16), ("Wide convergence angle range", 1), ("Slit inserted", 1),
        ("Slit width", 8), ("Acceleration voltage offset", 8), ("Drift tube voltage", 8),
        ("Energy shift", 8), ("Shift offset X", 8), ("Shift offset Y", 8),
        ("Shift X", 8), ("Shift Y", 8), ("Integration time", 8),
        ("Binning Width", 4), ("Binning Height", 4), ("Camera name", 16),
        ("Readout area left", 4), ("Readout area top", 4), ("Readout area right", 4),
        ("Readout area bottom", 4), ("Ceta noise reduction", 1), ("Ceta frames summed", 4),
        ("Direct detector electron counting", 1), ("Direct detector align frames", 1), ("Camera param reserved 0", 4),
        ("Camera param reserved 1", 4), ("Camera param reserved 2", 4), ("Camera param reserved 3", 4),
        ("Bitmask 3", 4), ("Camera param reserved 4", 4), ("Camera param reserved 5", 4),
        ("Camera param reserved 6", 4), ("Camera param reserved 7", 4), ("Camera param reserved 8", 4),
        ("Camera param reserved 9", 4), ("Phase Plate", 1), ("STEM Detector name", 16),
        ("Gain", 8), ("Offset", 8), ("STEM param reserved 0", 4),
        ("STEM param reserved 1", 4), ("STEM param reserved 2", 4), ("STEM param reserved 3", 4),
        ("STEM param reserved 4", 4), ("Dwell time", 8), ("Frame time", 8),
        ("Scan size left", 4), ("Scan size top", 4), ("Scan size right", 4),
        ("Scan size bottom", 4), ("Full scan FOV X", 8), ("Full scan FOV Y", 8),
        ("Element", 16), ("Energy interval lower", 8), ("Energy interval higher", 8),
        ("Method", 4), ("Is dose fraction", 1), ("Fraction number", 4),
        ("Start frame", 4), ("End frame", 4), ("Input stack filename", 80),
        ("Bitmask 4", 4), ("Alpha tilt min", 8), ("Alpha tilt max", 8),
        ("Scan rotation", 8), ("Diffraction pattern rotation", 8), ("Image rotation", 8),
        ("Scan mode enumeration", 4), ("Acquisition time stamp", 8), ("Detector commercial name", 16),
        ("Start tilt angle", 8), ("End tilt angle", 8), ("Tilt per image", 8),
        ("Tilt speed", 8), ("Beam center X pixel", 4), ("Beam center Y pixel", 4),
        ("CFEG flash timestamp", 8), ("Phase plate position index", 4), ("Objective aperture name", 16),
    ]
    static let fei1FieldCount = 99

    struct Place { let offset: Int; let width: Int; let mask: Int?; let bit: Int }

    /// Offsets and (mask, bit) of every field, walked from `layout`: one bit per field, six for "Unused range".
    static let places: [String: Place] = {
        var result: [String: Place] = [:]
        var offset = 0, mask = -1, bit = 0
        for (name, width) in layout {
            if name.hasPrefix("Bitmask ") {
                mask += 1; bit = 0
                result[name] = Place(offset: offset, width: width, mask: nil, bit: 0)
            } else {
                result[name] = Place(offset: offset, width: width, mask: mask < 0 ? nil : mask, bit: bit)
                bit += name == "Unused range" ? 6 : 1
            }
            offset += width
        }
        precondition(offset == 888, "the planted FEI2 layout is 888 bytes")
        precondition(layout[..<fei1FieldCount].reduce(0, { $0 + $1.width }) == 768, "the planted FEI1 layout is 768 bytes")
        return result
    }()

    static func place(_ name: String) -> Place {
        guard let p = places[name] else { preconditionFailure("no field \(name)") }
        return p
    }

    var fei2 = true
    var bigEndian = false
    /// The record: 888 bytes (FEI2) or 768 (FEI1).
    var bytes: [UInt8]

    init(fei2: Bool = true, bigEndian: Bool = false) {
        self.fei2 = fei2
        self.bigEndian = bigEndian
        bytes = [UInt8](repeating: 0, count: fei2 ? 888 : 768)
        put("Metadata size", int: Int32(bytes.count), recorded: false)
        put("Metadata version", int: fei2 ? 2 : 1, recorded: false)
    }

    /// A real record (zero-padded to 888 bytes) as a FEI2 file.
    init(record: [UInt8], bigEndian: Bool = false) {
        self.fei2 = true
        self.bigEndian = bigEndian
        bytes = record + [UInt8](repeating: 0, count: 888 - record.count)
    }

    private func ordered(_ raw: [UInt8]) -> [UInt8] { bigEndian ? raw.reversed() : raw }

    private mutating func store(_ name: String, _ raw: [UInt8], recorded: Bool) {
        let p = Self.place(name)
        precondition(raw.count == p.width && p.offset + p.width <= bytes.count, "\(name) does not fit this record")
        bytes.replaceSubrange(p.offset ..< p.offset + p.width, with: raw)
        if p.mask != nil { setRecorded(name, recorded) }
    }

    mutating func put(_ name: String, _ value: Double, recorded: Bool = true) {
        store(name, ordered((0..<8).map { UInt8((value.bitPattern >> (8 * UInt64($0))) & 0xFF) }), recorded: recorded)
    }

    mutating func put(_ name: String, int value: Int32, recorded: Bool = true) {
        let bits = UInt32(bitPattern: value)
        store(name, ordered((0..<4).map { UInt8((bits >> (8 * UInt32($0))) & 0xFF) }), recorded: recorded)
    }

    mutating func put(_ name: String, bytes raw: [UInt8], recorded: Bool = true) {
        let width = Self.place(name).width
        store(name, Array((raw + [UInt8](repeating: 0, count: width)).prefix(width)), recorded: recorded)
    }

    mutating func put(_ name: String, text: String, recorded: Bool = true) {
        put(name, bytes: Array(text.utf8), recorded: recorded)
    }

    /// Set or clear a field's bit in its bitmask (always written little-endian).
    mutating func setRecorded(_ name: String, _ on: Bool = true) {
        let p = Self.place(name)
        guard let mask = p.mask else { return }
        let at = Self.place("Bitmask \(mask + 1)").offset
        var word = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
        if on { word |= 1 << UInt32(p.bit) } else { word &= ~(1 << UInt32(p.bit)) }
        setMask(mask, word)
    }

    mutating func setMask(_ mask: Int, _ word: UInt32) {
        let at = Self.place("Bitmask \(mask + 1)").offset
        for i in 0..<4 { bytes[at + i] = UInt8((word >> (8 * UInt32(i))) & 0xFF) }
    }

    /// Every field the metadata reads, with values that differ from one another and are never zero.
    mutating func plantEverything(recorded: Bool) {
        put("Timestamp", 44900.5, recorded: recorded)               // 2022-12-05 12:00:00
        put("Microscope type", text: "Titan Themis", recorded: recorded)
        put("HT", 300_000, recorded: recorded)
        put("Instrument mode", int: 2, recorded: recorded)
        put("Projection mode", int: 1, recorded: recorded)
        put("Magnification", 50_000, recorded: recorded)
        put("Camera length", 0.15, recorded: recorded)
        put("Integration time", 0.25, recorded: recorded)
        put("Frame time", 2.72, recorded: recorded)
        put("Camera name", text: "CAM", recorded: recorded)
        put("STEM Detector name", text: "STEMDET", recorded: recorded)
        put("Dwell time", 2.5e-5, recorded: recorded)
        if fei2 { put("Detector commercial name", text: "COMM", recorded: recorded) }
    }

    /// The 1024-byte MRC2014 header alone (no extended header, no pixels).
    func headerOnly() -> Data { Data(header(claimedExtended: 0, exttyp: nil, map: "MAP ", stamp: nil)) }

    /// The whole file: header, `padding` zero bytes after the record inside the extended header, two mode-0 pixels.
    func file(exttyp: String? = nil, stamp: [UInt8]? = nil, map: String = "MAP ", claimedExtended: Int? = nil,
              padding: Int = 0) -> Data {
        let extended = bytes + [UInt8](repeating: 0, count: padding)
        return Data(header(claimedExtended: claimedExtended ?? extended.count, exttyp: exttyp, map: map, stamp: stamp)
                    + extended + [5, 6])
    }

    private func header(claimedExtended: Int, exttyp: String?, map: String, stamp: [UInt8]?) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 1024)
        func word(_ index: Int, _ v: Int) {
            let b = (0..<4).map { UInt8((UInt32(bitPattern: Int32(v)) >> (8 * UInt32($0))) & 0xFF) }
            h.replaceSubrange((4 * index)..<(4 * index + 4), with: bigEndian ? b.reversed() : b)
        }
        word(0, 2); word(1, 1); word(2, 1); word(3, 0)            // 2 × 1 × 1, mode 0
        word(7, 2); word(8, 1); word(9, 1)
        word(16, 1); word(17, 2); word(18, 3)
        word(23, claimedExtended)
        h.replaceSubrange(104..<108, with: Array((exttyp ?? (fei2 ? "FEI2" : "FEI1")).utf8.prefix(4)))
        h.replaceSubrange(208..<212, with: Array(map.utf8))
        h.replaceSubrange(212..<216, with: stamp ?? (bigEndian ? [0x11, 0x11, 0, 0] : [0x44, 0x44, 0, 0]))
        return h
    }
}
