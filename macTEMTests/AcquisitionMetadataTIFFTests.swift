//
//  AcquisitionMetadataTIFFTests.swift
//  The TIFF reader of acquisition metadata (the compute core) on TIFFs built in memory with
//  known values: the planted truth is the bytes written here. The parity against the references and the real files is
//  tools/parity/metadata-parity; these pin the reader's own rules without Python — each unit conversion, camera length only
//  where the mode makes it real, FrameTime never a dwell, the named detector's exposure, a second start stamp kept
//  and an unset one (before 1990) not, the US date and the 12-hour clock, the FEI INI text read as tifffile reads it
//  (a repeated key, cp1252, NUL, Python's line breaks and spaces), and absent / empty / zero / unparseable always
//  "not recorded", never 0. The hostile XML (nesting, entities, length) is GuardedXMLTests'.
//  The Velox plant mirrors the owner's Ceta XML (Talos F200X); the FEI plant mirrors RosettaSciIO's Helios files
//  (CRLF lines, `Helios NanoLab" 660`), each with decoy elements the reader must not read.
//

import XCTest
import FormatoCore
import FormatoTIFF
import TEMCore
@testable import macTEM

nonisolated final class AcquisitionMetadataTIFFTests: XCTestCase {
    private static let local = "local time, zone not stored"
    private static let unvalidated = "unvalidated: no published reader reads it"
    /// A Velox date: no published reader reads the XML's text, so the note joins the two.
    private static let veloxLocal = local + "; " + unvalidated

    // MARK: Velox (tag 34683)

    func testAVeloxFileReadsEveryValueAsTheFileStatesIt() throws {
        let got = try VeloxPlant().read()
        var want = AcquisitionMetadata()
        want.highTensionKV = MetadataReading(200)
        want.magnification = MetadataReading(17749.325000000001, note: Self.unvalidated)
        want.detector = MetadataReading("BM-Ceta", note: Self.unvalidated)
        want.exposureS = MetadataReading(2, note: Self.unvalidated)
        want.acquired = MetadataReading("2026-06-05 13:05:31", note: Self.veloxLocal)
        want.instrument = MetadataReading("Talos F200X", note: Self.unvalidated)
        want.mode = MetadataReading("TEM", note: Self.unvalidated)
        XCTAssertEqual(got, want, "camera length and dwell are nil in a TEM imaging file; the rest as planted")
    }

    func testVeloxHighTensionIsKilovoltsFromVolts() throws {
        for (stored, kv) in [("200000", 200.0), ("300000", 300.0), ("80000", 80.0), ("120000.5", 120.0005)] {
            var plant = VeloxPlant()
            plant.voltage = stored
            assertValue(try plant.read().highTensionKV, kv, "\(stored) V")
        }
    }

    func testVeloxMagnificationIsTheNominalOneNeverTheActualOne() throws {
        var plant = VeloxPlant()
        plant.magnification = "17749.325000000001"
        plant.actualMagnification = "999"                          // a calibrated value would sit here: never read (rule g)
        assertValue(try plant.read().magnification, 17749.325000000001, note: Self.unvalidated)
        plant.magnification = nil
        XCTAssertNil(try plant.read().magnification, "no nominal magnification: not recorded, not the actual one")
    }

    func testVeloxCameraLengthIsMillimetresFromMetres() throws {
        var plant = VeloxPlant()
        plant.projector = "Diffraction"
        plant.cameraLength = "0.84399999999999997"
        assertValue(try plant.read().cameraLengthMM, 844, "TEM diffraction, 0.844 m")
        plant.operating = "STEM"
        plant.projector = "Imaging"
        plant.cameraLength = "1.365"
        assertValue(try plant.read().cameraLengthMM, 1365, "STEM, 1.365 m")
    }

    func testVeloxCameraLengthIsNotRecordedOutsideDiffractionAndSTEM() throws {
        // (OperatingMode, ProjectorMode) → whether the stored CameraLength is real (the six real Ceta files all store
        // one, 0.844 m in three and 1.365 m in the other three, all TEM / Imaging). Mutations that turn this red: the
        // gate opened (`if diffraction || stem` → `if true`: the TEM / Imaging cases read a camera length); the mode
        // compared case-sensitively (the "tem" / "DIFFRACTION" / "stem" cases are not read).
        let cases: [(String?, String?, Bool)] = [
            ("TEM", "Imaging", false),            // the six real files: a stale setting
            ("TEM", nil, false), (nil, nil, false), (nil, "Imaging", false), ("TEM", "", false),
            ("TEM", "Diffraction", true), ("STEM", "Imaging", true), ("STEM", "Diffraction", true),
            ("tem", "DIFFRACTION", true), ("stem", nil, true), (nil, "Diffraction", true),
        ]
        for (operating, projector, real) in cases {
            var plant = VeloxPlant()
            plant.operating = operating
            plant.projector = projector
            let label = "\(operating ?? "-") / \(projector ?? "-")"
            XCTAssertEqual(try plant.read().cameraLengthMM != nil, real, label)
        }
        var plant = VeloxPlant()
        plant.projector = "Diffraction"
        for stored in ["0", "-1", "", "notafloat", nil] {
            plant.cameraLength = stored
            XCTAssertNil(try plant.read().cameraLengthMM, "a diffraction file whose camera length is \(stored ?? "absent")")
        }
    }

    func testVeloxFrameTimeIsNeverADwell() throws {
        var plant = VeloxPlant()
        plant.frameTime = "36.945928000000002"
        plant.dwellDecoy = nil
        XCTAssertNil(try plant.read().dwellUS, "FrameTime is a frame time (these files store no dwell)")
        plant.operating = "STEM"
        XCTAssertNil(try plant.read().dwellUS, "not in STEM either")
        // Where a STEM dwell would sit is unobserved ("Owed"), so a DwellTime element is not guessed at.
        plant.dwellDecoy = "5e-06"
        XCTAssertNil(try plant.read().dwellUS, "dwell stays not recorded until a Velox STEM TIFF shows its path")
    }

    func testVeloxExposureIsTheNamedDetectorsNotAnotherOnes() throws {
        var plant = VeloxPlant()           // Detectors: HAADF (none), Other-Cam (7 s), BM-Ceta (2 s); BinaryResult names BM-Ceta
        assertValue(try plant.read().exposureS, 2, note: Self.unvalidated)
        plant.detector = "Other-Cam"
        assertValue(try plant.read().exposureS, 7, note: Self.unvalidated)
        plant.detector = "HAADF"           // a detector with no exposure: not recorded, not an imaging detector's
        XCTAssertNil(try plant.read().exposureS)
        XCTAssertEqual(try plant.read().detector?.value, "HAADF")
        plant.detector = nil               // BinaryResult names none: no detector, and no guess at an exposure
        let got = try plant.read()
        XCTAssertNil(got.detector)
        XCTAssertNil(got.exposureS)
    }

    func testVeloxDateIsTheLocalWallClockWithItsNote() throws {
        func acquired(_ stored: String?) throws -> MetadataReading<String>? {
            var plant = VeloxPlant()
            plant.start = stored
            plant.second = nil
            return try plant.read().acquired
        }
        XCTAssertEqual(try acquired("2026-06-05T13:05:31.000"), MetadataReading("2026-06-05 13:05:31", note: Self.veloxLocal))
        XCTAssertEqual(try acquired("2026-06-05T13:05:31")?.value, "2026-06-05 13:05:31")
        XCTAssertEqual(try acquired("2026-06-05 01:02:03.5")?.value, "2026-06-05 01:02:03", "a space for the T")
        XCTAssertEqual(try acquired("2024-02-29T23:59:59.999")?.value, "2024-02-29 23:59:59", "a leap day exists")
        for bad in [nil, "", "notadate", "2026-06-05", "2026-06-05T13:05:31Z", "2026-06-05T13:05:31+02:00",
                    "2026-06-05T13:05:31.000-05:00", "2026-13-05T13:05:31", "2026-02-30T13:05:31", "2025-02-29T00:00:00",
                    "0000-00-00T00:00:00", "2026-06-05T24:00:00", "2026-06-05T13:60:00", "2026-06-05T13:05:61"] {
            XCTAssertNil(try acquired(bad), "\(bad ?? "absent") is not a local wall-clock stamp")
        }
        var plant = VeloxPlant()
        plant.start = nil
        plant.second = "2026-06-05T13:05:31.000"
        XCTAssertNil(try plant.read().acquired, "AcquisitionDatetime is a second stamp, never a stand-in for the start")
    }

    func testVeloxSecondStartStampIsKeptWhenItDiffers() throws {
        func acquired(second: String?) throws -> MetadataReading<String>? {
            var plant = VeloxPlant()
            plant.second = second
            return try plant.read().acquired
        }
        XCTAssertEqual(try acquired(second: "2026-06-05T13:05:31.000"), MetadataReading("2026-06-05 13:05:31", note: Self.veloxLocal),
                       "equal stamps (all six real files): one date")
        XCTAssertNil(try acquired(second: "2026-06-05T13:05:31.900")?.otherCopy, "a different millisecond is the same shown second")
        XCTAssertNil(try acquired(second: nil)?.otherCopy)
        XCTAssertNil(try acquired(second: "notadate")?.otherCopy, "an unreadable second stamp is not shown")
        XCTAssertEqual(try acquired(second: "2026-06-05T13:05:40.000"),
                       MetadataReading("2026-06-05 13:05:31", note: Self.veloxLocal, otherCopy: "2026-06-05 13:05:40"),
                       "the start first, the other stamp beside it (rule f)")
    }

    func testAnUnsetSecondStampIsNotACopyOfTheFirst() throws {
        // Changed behaviour: a second stamp before 1990 is an unset field (RosettaSciIO's Velox EMDs
        // store an unset AcquisitionDatetime as unix 0), so no `otherCopy`. Mutations that turn this red: the year guard
        // removed (every stamp below is then a copy); the floor lowered to 1970 or below (the 1970 stamps, the local-zone
        // epoch 01:00:00 included, and 1989 are copies); the floor raised above 1990 (1990-01-01 is no longer kept).
        func other(_ second: String?) throws -> String? {
            var plant = VeloxPlant()
            plant.second = second
            return try plant.read().acquired?.otherCopy
        }
        for unset in ["0001-01-01T00:00:00.000", "1970-01-01T00:00:00.000", "1970-01-01T01:00:00",
                      "1969-12-31T23:00:00", "1989-12-31T23:59:59.999"] {
            XCTAssertNil(try other(unset), "\(unset) is an unset field, not a second date")
        }
        XCTAssertEqual(try other("1990-01-01T00:00:00"), "1990-01-01 00:00:00", "the floor is the year 1990 itself")
        XCTAssertEqual(try other("2026-06-05T13:05:40.000"), "2026-06-05 13:05:40", "a genuine differing stamp stays")
        // The floor is on the second stamp only: an old START stamp is still the start (no guard on it).
        var plant = VeloxPlant()
        plant.start = "1970-01-01T01:00:00"
        plant.second = "1970-01-01T01:00:00"
        XCTAssertEqual(try plant.read().acquired?.value, "1970-01-01 01:00:00")
    }

    func testVeloxAbsentEmptyZeroAndUnparseableAreNotRecordedNeverZero() throws {
        for stored in [nil, "", "   ", "notafloat", "0", "0.0", "-5", "nan", "inf", "1,5"] {
            var plant = VeloxPlant()
            plant.voltage = stored
            plant.magnification = stored
            plant.detectors = [("ImagingDetector", "BM-Ceta", stored)]
            let got = try plant.read()
            let label = stored ?? "absent"
            XCTAssertNil(got.highTensionKV, "high tension \(label)")
            XCTAssertNil(got.magnification, "magnification \(label)")
            XCTAssertNil(got.exposureS, "exposure \(label)")
        }
        var plant = VeloxPlant()
        plant.model = ""
        plant.detector = "  "
        plant.operating = nil
        plant.projector = nil
        plant.start = nil
        plant.second = nil
        let got = try plant.read()
        XCTAssertNil(got.instrument)
        XCTAssertNil(got.detector)
        XCTAssertNil(got.mode)
        XCTAssertNil(got.acquired)
    }

    func testVeloxAQuantityThatConvertsToZeroOrInfinityIsNotRecordedAndOneThatStaysFiniteIs() throws {
        // Rule (b) holds for the number as shown, after the unit conversion. Mutation (AcquisitionMetadata+TIFF.swift,
        // `velox`): positive() on the stored number BEFORE the conversion (`positive(number(…)).map { $0 / 1e3 }` and
        // `… { $0 * 1e3 }` in place of `positive(number(…).map { … })`) — the finite 5e-324 V then reads as 0.0 kV and
        // 1e306 m as inf mm. (A denormal camera length stays positive and finite after ×1e3, and a huge voltage after
        // /1e3: only a denormal voltage underflows and only a huge camera length overflows.)
        var plant = VeloxPlant()
        plant.projector = "Diffraction"                              // the camera length is real in this mode (rule c)
        plant.voltage = "5e-324"
        plant.cameraLength = "1e306"
        let gone = try plant.read()
        XCTAssertNil(gone.highTensionKV, "5e-324 V is 0.0 kV")
        XCTAssertNil(gone.cameraLengthMM, "1e306 m is inf mm")
        // The same quantities, still finite and positive after the conversion, are read with the converted number.
        plant.voltage = "1e300"
        plant.cameraLength = "5e-324"
        let kept = try plant.read()
        XCTAssertEqual(kept.highTensionKV, MetadataReading(1e300 / 1e3))
        XCTAssertEqual(kept.cameraLengthMM, MetadataReading(5e-324 * 1e3))
        plant.cameraLength = "1e305"
        XCTAssertEqual(try plant.read().cameraLengthMM, MetadataReading(1e305 * 1e3))
    }

    func testVeloxInstrumentIsTheModelAndModeIsTheOperatingModeAlone() throws {
        var plant = VeloxPlant()
        plant.model = "Talos F200X"
        plant.instrumentClass = "Talos"                            // a different element: never read
        let got = try plant.read()
        XCTAssertEqual(got.instrument, MetadataReading("Talos F200X", note: Self.unvalidated))
        XCTAssertEqual(got.mode, MetadataReading("TEM", note: Self.unvalidated), "OperatingMode, not 'TEM · Imaging'")
        // The projector mode decides the camera length (rule c) and is never part of the mode; no operating mode: none.
        for (operating, projector, shown) in [("STEM", nil, "STEM"), ("TEM", "Diffraction", "TEM"), ("STEM", "Diffraction", "STEM"),
                                              (nil, "Diffraction", nil), (nil, "Imaging", nil)] as [(String?, String?, String?)] {
            plant.operating = operating
            plant.projector = projector
            XCTAssertEqual(try plant.read().mode?.value, shown, "\(operating ?? "-") / \(projector ?? "-")")
        }
    }

    // MARK: FEI SEM (tags 34680 / 34682)

    func testFEIHighTensionAndDwellAreKilovoltsAndMicroseconds() throws {
        let got = try fei(helios())
        assertValue(got.highTensionKV, 5, "[Beam] HV = 5000 V")
        assertValue(got.dwellUS, 10, "[Scan] Dwelltime = 1e-005 s")
        let other = try fei(helios(hv: "30000", dwell: "2.5e-006"))
        assertValue(other.highTensionKV, 30)
        assertValue(other.dwellUS, 2.5)
    }

    func testFEIReadsTheSectionsMappingFEIReadsNotTheirNeighbours() throws {
        // [EBeam] HV and [EScan] Dwell sit beside [Beam] HV and [Scan] Dwelltime in the Helios files: RosettaSciIO's
        // `mapping_fei` reads Beam.HV and Scan.Dwelltime, so a file with only the neighbours records neither.
        let ini = crlf("[EBeam]", "HV=5000", "[EScan]", "Dwell=1e-005", "[Beam]", "HV=", "[Scan]", "FrameTime=2.62")
        let got = try fei(ini)
        XCTAssertNil(got.highTensionKV)
        XCTAssertNil(got.dwellUS)
        XCTAssertNil(got.exposureS, "a frame time is not an exposure")
    }

    func testFEIAbsentEmptyZeroAndUnparseableAreNotRecordedNeverZero() throws {
        // The Helios navcam files hold HV "" and "notafloat" (RosettaSciIO's own test data).
        for stored in [nil, "", "notafloat", "0", "0.0", "-1", "nan", "5,000"] {
            let got = try fei(helios(hv: stored, dwell: stored))
            XCTAssertNil(got.highTensionKV, "HV \(stored ?? "absent")")
            XCTAssertNil(got.dwellUS, "Dwelltime \(stored ?? "absent")")
        }
        let got = try fei(helios(date: nil, time: nil, detector: "", systemType: nil))
        XCTAssertNil(got.acquired)
        XCTAssertNil(got.detector)
        XCTAssertNil(got.instrument)
    }

    func testFEIAQuantityThatConvertsToZeroOrInfinityIsNotRecordedAndOneThatStaysFiniteIs() throws {
        // Rule (b) holds for the number as shown, after the unit conversion. Mutation (AcquisitionMetadata+TIFF.swift,
        // `fei`): positive() on the stored number BEFORE the conversion (V → kV, s → µs) — the finite 5e-324 V then
        // reads as 0.0 kV and 1e306 s as inf µs. (A denormal dwell stays positive and finite after ×1e6, and a huge HV
        // after /1e3: only a denormal HV underflows and only a huge dwell overflows.)
        let gone = try fei(helios(hv: "5e-324", dwell: "1e306"))
        XCTAssertNil(gone.highTensionKV, "5e-324 V is 0.0 kV")
        XCTAssertNil(gone.dwellUS, "1e306 s is inf µs")
        // The same quantities, still finite and positive after the conversion, are read with the converted number.
        let kept = try fei(helios(hv: "1e300", dwell: "5e-324"))
        XCTAssertEqual(kept.highTensionKV, MetadataReading(1e300 / 1e3))
        XCTAssertEqual(kept.dwellUS, MetadataReading(5e-324 * 1e6))
        XCTAssertEqual(try fei(helios(dwell: "1e300")).dwellUS, MetadataReading(1e300 * 1e6))
    }

    func testFEIDateIsTheUSDateAndTheTwelveHourClock() throws {
        func acquired(_ date: String?, _ time: String?) throws -> MetadataReading<String>? {
            try fei(helios(date: date, time: time)).acquired
        }
        XCTAssertEqual(try acquired("06/13/2016", "05:06:40 PM"), MetadataReading("2016-06-13 17:06:40", note: Self.local))
        // The 12-hour clock's edges: 12 AM is hour 0, 12 PM is hour 12.
        let clock = [("12:00:00 AM", "00:00:00"), ("12:30:15 PM", "12:30:15"), ("12:59:59 AM", "00:59:59"),
                     ("01:00:00 AM", "01:00:00"), ("11:59:59 AM", "11:59:59"), ("01:00:00 PM", "13:00:00"),
                     ("11:59:59 PM", "23:59:59"), ("09:07:08 AM", "09:07:08"), ("5:06:40 pm", "17:06:40")]
        for (stored, shown) in clock {
            XCTAssertEqual(try acquired("06/13/2016", stored)?.value, "2016-06-13 \(shown)", stored)
        }
        XCTAssertEqual(try acquired("06/13/2016", "17:06:40")?.value, "2016-06-13 17:06:40", "a 24-hour clock has no suffix")
        for (date, time) in [("06/13/2016", nil), (nil, "05:06:40 PM"), ("06/13/2016", "13:00:00 PM"),
                             ("06/13/2016", "00:30:00 AM"), ("06/13/2016", "05:06:40 XM"), ("06/13/2016", "05:06 PM"),
                             ("06/13/2016", "25:00:00"), ("06/13/2016", "05:61:00 PM"), ("02/30/2016", "05:06:40 PM"),
                             ("13/13/2016", "05:06:40 PM"), ("06-13-2016", "05:06:40 PM"), ("06/13/16", "05:06:40 PM"),
                             ("notadate", "05:06:40 PM"), ("06/13/2016", "notatime")] as [(String?, String?)] {
            XCTAssertNil(try acquired(date, time), "\(date ?? "absent") \(time ?? "absent") is not a date and time")
        }
    }

    func testFEIDateIsMonthFirstAndCarriesOnlyTheLocalTimeNote() throws {
        // Changed behaviour: the FEI INI date is month-first by format, as mapping_fei's dateutil
        // reads it, so an ambiguous date is no guess and carries no "month-first order assumed" note (that note is the
        // DM date's). Mutation that turns this red: appending a month-first note to an ambiguous FEI date (as the
        // reader did before), which fails the exact-note comparison of the 05/06/2016 and 5/6/2016 cases.
        func acquired(_ date: String) throws -> MetadataReading<String>? {
            try fei(helios(date: date, time: "05:06:40 PM")).acquired
        }
        XCTAssertEqual(try acquired("06/13/2016"), MetadataReading("2016-06-13 17:06:40", note: Self.local))
        XCTAssertEqual(try acquired("13/06/2016"), MetadataReading("2016-06-13 17:06:40", note: Self.local),
                       "a first field above 12 can only be the day")
        XCTAssertEqual(try acquired("05/06/2016"), MetadataReading("2016-05-06 17:06:40", note: Self.local),
                       "both fields could be the month: month first, the format's order, no note")
        XCTAssertEqual(try acquired("5/6/2016"), MetadataReading("2016-05-06 17:06:40", note: Self.local))
    }

    func testFEIARepeatedKeyTakesItsLastLineEvenWhenItIsEmpty() throws {
        // tifffile's read_fei_metadata stores `Key=` as the empty string, replacing an earlier value of the key (checked
        // against tifffile 2026.9.20 on `[Beam] HV=5000` then `HV=`: HV is ''). New. Mutation that
        // turns this red: `line.split(separator: "=", maxSplits: 1)` with the default omittingEmptySubsequences, which
        // skips `HV=` so the earlier 5000 survives (5 kV shown for a file whose last word on HV is empty).
        XCTAssertNil(try fei(crlf("[Beam]", "HV=5000", "HV=", "[Scan]", "Dwelltime=1e-005", "Dwelltime=")).highTensionKV,
                     "the later, empty HV replaces the earlier 5000: not recorded")
        XCTAssertNil(try fei(crlf("[Beam]", "HV=5000", "HV=", "[Scan]", "Dwelltime=1e-005", "Dwelltime=")).dwellUS)
        assertValue(try fei(crlf("[Beam]", "HV=", "HV=5000")).highTensionKV, 5, "a later value replaces an earlier empty one")
        assertValue(try fei(crlf("[Beam]", "HV=5000", "HV=30000")).highTensionKV, 30, "the last of two values")
        // A repeated key in a repeated section: the section is replaced whole, its keys with it.
        XCTAssertNil(try fei(crlf("[Beam]", "HV=5000", "[Beam]", "Spot=1")).highTensionKV)
    }

    func testFEITextIsUTF8ElseCp1252AndEndsAtTheFirstNUL() throws {
        // tifffile's bytes2str: the bytes up to the first NUL, decoded as UTF-8 and, failing that, as cp1252. New (Gate B
        // 2026-10-12). Mutations that turn this red: decoding with String(decoding:as: UTF8.self) (cp1252 bytes become
        // U+FFFD in the first assertions); dropping only TRAILING NULs, as TIFFFile.string does (the text after an
        // interior NUL is parsed: HV becomes the unparseable "5000\0junk" and the [Scan] after it is read); accepting a
        // cp1252-undefined byte by replacing it (the second tag is then read and wins).
        func ini(_ pieces: [UInt8]...) -> [UInt8] { Array(pieces.joined()) }
        let cp1252 = ini(Array("[System]\r\nSystemType=Helios NanoLab".utf8), [0x99], Array(" 660\r\n[Detectors]\r\nName=".utf8), [0xB5],
                         Array("-Det\r\n".utf8))
        let a = try feiBytes(cp1252)
        XCTAssertEqual(a.instrument?.value, "Helios NanoLab\u{2122} 660", "0x99 is the trade mark sign in cp1252")
        XCTAssertEqual(a.detector?.value, "\u{B5}-Det", "0xB5 is the micro sign in cp1252")
        let utf8 = try feiBytes(Array("[System]\r\nSystemType=Helios NanoLab\u{2122} 660\r\n[Detectors]\r\nName=\u{B5}-Det\r\n".utf8))
        XCTAssertEqual(utf8.instrument?.value, "Helios NanoLab\u{2122} 660")
        XCTAssertEqual(utf8.detector?.value, "\u{B5}-Det")

        let cut = try feiBytes(Array("[Beam]\r\nHV=5000".utf8) + [0] + Array("junk\r\n[Scan]\r\nDwelltime=1e-005\r\n".utf8))
        assertValue(cut.highTensionKV, 5, "the text ends at the first NUL: HV=5000")
        XCTAssertNil(cut.dwellUS, "and nothing after the NUL is read")

        // 0x81 is undefined in cp1252: tifffile raises while decoding that tag and has no sections for it, the other tag stays.
        var tiff = PlantedTIFF()
        tiff.extra[34680] = .ascii(crlf("[Beam]", "HV=5000"))
        tiff.extra[34682] = .bytes(Array("[Beam]\r\nHV=30000\r\n[System]\r\nSystemType=A".utf8) + [0x81] + Array("B\r\n".utf8))
        let both = try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app)
        assertValue(both.highTensionKV, 5, "the second tag holds an undefined cp1252 byte and is skipped")
        XCTAssertNil(both.instrument)
    }

    func testFEILinesSplitAndTrimWherePythonSplitsAndTrims() throws {
        // tifffile uses str.splitlines (which also splits at U+001C..U+001E, U+0085, U+2028, U+2029) and str.strip (which
        // also strips U+001F, U+00A0 and the Unicode spaces). New. Mutations that turn this red:
        // splitting with Character.isNewline alone (the U+001C..U+001E cases read nothing); trimming with
        // CharacterSet.whitespaces or whitespacesAndNewlines (the U+001F case keeps the separator in the value).
        for separator in ["\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}", "\r", "\n"] {
            let got = try fei(["[Beam]", "HV=5000", "[Scan]", "Dwelltime=1e-005"].joined(separator: separator))
            assertValue(got.highTensionKV, 5, "lines separated by U+\(String(separator.unicodeScalars.first!.value, radix: 16))")
            assertValue(got.dwellUS, 10, "second line after U+\(String(separator.unicodeScalars.first!.value, radix: 16))")
        }
        assertValue(try fei(crlf("[Beam]", "\u{1F}HV\u{A0}=\u{1F}5000\u{3000}")).highTensionKV, 5, "Python's strip on key and value")
        assertValue(try fei(crlf("\u{2003}[Beam]\u{1F}", " HV = 5000 ")).highTensionKV, 5, "and on the section line")
    }

    func testFEIATagOfByteTypeIsNotRead() throws {
        // The documented DEVIATION from tifffile, which reads the INI whatever the tag's type: only ASCII or UNDEFINED
        // reads here, as TIFFImageReader.calibration gates the same tag. New. Mutation that turns
        // this red: iniText accepting `entry.type == 1`.
        var tiff = PlantedTIFF()
        tiff.extra[34682] = .byteArray(Array(crlf("[Beam]", "HV=5000").utf8))
        XCTAssertTrue(try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app).isEmpty)
    }

    func testFEIDetectorAndInstrumentAreAsStoredAndNothingIsMadeUpForTheRest() throws {
        let got = try fei(helios())
        XCTAssertEqual(got.detector, MetadataReading("ETD", note: Self.unvalidated), "mapping_fei does not map [Detectors] Name")
        XCTAssertEqual(got.instrument, MetadataReading("Helios NanoLab\" 660"), "kept as stored, quote and all; mapped")
        // The INI stores no magnification: [Image] MagCanvasRealWidth and [EBeam] HFW are widths in metres, and
        // [Scan] FrameTime a frame time. None of them becomes a magnification, camera length, exposure or mode.
        XCTAssertNil(got.magnification)
        XCTAssertNil(got.cameraLengthMM)
        XCTAssertNil(got.exposureS)
        XCTAssertNil(got.mode)
    }

    func testFEISectionsFromBothTagsMergeAndALaterSectionReplacesAnEarlierOne() throws {
        // Tag 34680 (SFEG) then 34682 (Helios), as tifffile's fei_metadata: the later [Beam] replaces the earlier whole.
        var tiff = PlantedTIFF()
        tiff.extra[34680] = .ascii(crlf("[Beam]", "HV=5000", "[Scan]", "Dwelltime=1e-005"))
        tiff.extra[34682] = .ascii(crlf("[Beam]", "HV=30000"))
        let got = try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app)
        assertValue(got.highTensionKV, 30, "the later tag's [Beam]")
        assertValue(got.dwellUS, 10, "[Scan] only in the earlier tag survives the merge")
        // A section repeated inside one INI also replaces the earlier one; spaces and CRLF are trimmed.
        let repeated = try fei("  [Beam]  \r\n  HV = 5000  \r\n[Beam]\r\nSpot=1\r\n")
        XCTAssertNil(repeated.highTensionKV)
        assertValue(try fei("\r\n  [Beam]  \r\n  HV = 5000  \r\n").highTensionKV, 5)
    }

    // MARK: Nothing recorded, and files that are not read

    func testATIFFWithoutAConventionReadsEmptyWhateverElseItHolds() throws {
        // Changed: the old comment said a Digital Micrograph export holds "none of it an acquisition
        // value", which is false of a DM-saved TIFF as a whole. The tags planted here hold none: the calibration tags
        // (65003..65010) and ImageJ's description hold calibration only, and the standard DateTime / Model / Software tags
        // describe the file's writer. What a DM-saved TIFF may also carry is its whole DM tag tree in tag 65027 (a DM4
        // serialisation; RosettaSciIO's test_loading_image_saved_with_DM.tif holds 10,585 bytes of it, stating 200 kV, 51x
        // and a 0.5 s exposure): slice S-a does NOT read it, that is V1-4a slice S-b's, so such a file reads empty
        // here although it states values. It is not planted below: a block that is not a real tree catches no mutation
        // in S-a, and S-b is where a real one is built. Mutation that turns this red: a reader that returns a value from
        // 272, 305, 306 or 65003..65010.
        var tiff = PlantedTIFF()
        tiff.extra[65003] = .ascii("nm")
        tiff.extra[65004] = .ascii("nm")
        tiff.extra[65009] = .double(0.5)
        tiff.extra[65010] = .double(0.5)
        tiff.extra[270] = .ascii("ImageJ=1.11a\nunit=micron\n")
        tiff.extra[272] = .ascii("Talos F200X")
        tiff.extra[305] = .ascii("Velox 2.15")
        tiff.extra[306] = .ascii("2026:06:05 13:05:31")
        tiff.extra[282] = .rational(4, 1)
        XCTAssertTrue(try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app).isEmpty)
        XCTAssertTrue(try AcquisitionMetadata.tiff(data: PlantedTIFF().build(), convention: .app).isEmpty, "a bare TIFF")
    }

    func testAConventionWithNothingInItReadsEmpty() throws {
        for (tag, text) in [(34683, "<Metadata/>"), (34683, "<?xml version=\"1.0\"?><Metadata><Optics/></Metadata>"),
                            (34682, "[Beam]\r\n"), (34680, ""), (34683, "")] as [(UInt16, String)] {
            var tiff = PlantedTIFF()
            tiff.extra[tag] = .ascii(text)
            XCTAssertTrue(try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app).isEmpty, "\(tag): \(text)")
        }
    }

    func testXMLThatIsNotVeloxMetadataReadsEmptyAndNeverTraps() throws {
        for xml in ["<<<", "not xml at all", "<Metadata><Optics>", "\u{0}\u{1}\u{2}",
                    "<?xml version=\"1.0\"?><Other><Optics><AccelerationVoltage>200000</AccelerationVoltage></Optics></Other>"] {
            var tiff = PlantedTIFF()
            tiff.extra[34683] = .ascii(xml)
            XCTAssertTrue(try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app).isEmpty, xml)
        }
    }

    func testAnExternalEntityNamedInTheXMLIsNeverLoaded() throws {
        // With XMLDocument's default options a DOCTYPE that names a local file puts that file's text into the element
        // (measured 2026-10-12): a TIFF must not be able to read the viewer's files into the metadata panel. Changed
        // : GuardedXML now refuses a document whose DTD declares any entity, so the whole tag reads as
        // no tag (the old test asserted only that the sentinel was absent, which also passed when the XML failed to parse;
        // `isEmpty` below needs the document to have been parsed AND refused: the 200 kV beside the entity is not shown).
        // That each defence stands alone is pinned in GuardedXMLTests (the tree check; the file never opened). Mutation
        // that turns this red: the DTD check removed from GuardedXML.document (the 200 kV is shown); with the
        // `.nodeLoadExternalEntitiesNever` option dropped as well, the sentinel is read into the instrument and detector.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("v14a-entity-\(UUID().uuidString).txt")
        try "SENTINEL-FROM-A-LOCAL-FILE".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE Metadata [<!ENTITY leak SYSTEM \"\(url.absoluteString)\">]>"
            + "<Metadata><Instrument><InstrumentModel>&leak;</InstrumentModel></Instrument>"
            + "<Optics><AccelerationVoltage>200000</AccelerationVoltage></Optics>"
            + "<BinaryResult><Detector>&leak;</Detector></BinaryResult></Metadata>"
        var tiff = PlantedTIFF()
        tiff.extra[34683] = .ascii(xml)
        let got = try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app)
        XCTAssertFalse(got.instrument?.value.contains("SENTINEL") ?? false)
        XCTAssertFalse(got.detector?.value.contains("SENTINEL") ?? false)
        XCTAssertTrue(got.isEmpty, "a document that declares an entity is refused whole")
    }

    func testANonTIFFThrowsAndATruncatedOneThrowsRatherThanTrapping() throws {
        XCTAssertThrowsError(try AcquisitionMetadata.tiff(data: Data("GIF89a.......".utf8), convention: .app)) {
            XCTAssertEqual(($0 as? TIFFError).map(Self.isNotTIFF), true)
        }
        XCTAssertThrowsError(try AcquisitionMetadata.tiff(data: Data(), convention: .app)) {
            XCTAssertEqual(($0 as? TIFFError).map(Self.isNotTIFF), true)
        }
        let whole = VeloxPlant().tiff()
        for length in [8, 9, 10, 11, 20, 40, 100] {
            XCTAssertThrowsError(try AcquisitionMetadata.tiff(data: whole.prefix(length), convention: .app), "cut at \(length)") {
                XCTAssertNotNil($0 as? TIFFError)
            }
        }
        // A string entry that points past the end of the file: FormatoTIFF refuses the file as truncated (the app's former walker
        // read it as an absent tag; the kit switch, 2026-10-20, made it stricter, and `read(path:)` still shows "not recorded").
        var lying = PlantedTIFF()
        lying.extra[34683] = .ascii(String(repeating: "x", count: 64))
        let cut = lying.build()
        XCTAssertThrowsError(try AcquisitionMetadata.tiff(data: cut.prefix(cut.count - 10), convention: .app)) {
            guard case TIFFError.truncated = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: Helpers

    /// FormatoTIFF's `TIFFError.notTIFF` (the metadata reader's refusal; the image reader's is `TIFFImageReader.Refusal.notTIFF`).
    private static func isNotTIFF(_ error: TIFFError) -> Bool { if case .notTIFF = error { true } else { false } }

    /// `reading` is nil when `value` is nil; otherwise it holds `value` to 1e-9 relative, exactly `note`, no second copy.
    private func assertValue(_ reading: MetadataReading<Double>?, _ value: Double?, _ message: String = "", note: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let value else { return XCTAssertNil(reading, message, file: file, line: line) }
        guard let reading else { return XCTFail("not recorded, expected \(value). \(message)", file: file, line: line) }
        XCTAssertEqual(reading.value, value, accuracy: 1e-9 * abs(value), message, file: file, line: line)
        XCTAssertEqual(reading.note, note, message, file: file, line: line)
        XCTAssertNil(reading.otherCopy, message, file: file, line: line)
    }

    /// A Helios-shaped INI (CRLF lines, as the real files): [Beam] HV, [Scan] Dwelltime, [User] Date / Time,
    /// [Detectors] Name and [System] SystemType, each omitted when nil, beside decoys the reader must not read.
    private func helios(hv: String? = "5000", dwell: String? = "1e-005", date: String? = "06/13/2016",
                        time: String? = "05:06:40 PM", detector: String? = "ETD",
                        systemType: String? = "Helios NanoLab\" 660") -> String {
        func line(_ key: String, _ value: String?) -> [String] { value.map { ["\(key)=\($0)"] } ?? [] }
        let lines = ["[User]"] + line("Date", date) + line("Time", time)
            + ["[System]"] + line("SystemType", systemType)
            + ["[Beam]"] + line("HV", hv)
            + ["[EBeam]", "HV=999", "HFW=0.00172667"]
            + ["[Scan]"] + line("Dwelltime", dwell) + ["FrameTime=2.62"]
            + ["[EScan]", "Dwell=2e-005"]
            + ["[Image]", "MagCanvasRealWidth=0.20720", "ResolutionX=512"]
            + ["[Detectors]", "Number=1"] + line("Name", detector) + ["Mode=SE"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func crlf(_ lines: String...) -> String { lines.joined(separator: "\r\n") + "\r\n" }

    private func fei(_ ini: String) throws -> AcquisitionMetadata {
        var tiff = PlantedTIFF()
        tiff.extra[34682] = .ascii(ini)
        return try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app)
    }

    /// The same, with the INI's bytes exactly as given (an ASCII-typed tag; no terminator is added).
    private func feiBytes(_ bytes: [UInt8]) throws -> AcquisitionMetadata {
        var tiff = PlantedTIFF()
        tiff.extra[34682] = .bytes(bytes)
        return try AcquisitionMetadata.tiff(data: tiff.build(), convention: .app)
    }
}

/// A Ceta-shaped Velox XML: the owner's Talos F200X values by default (a TEM imaging file), each element omitted when
/// nil. `actualMagnification` and `instrumentClass` are decoys the reader must not read; the detector list puts an
/// unnamed imaging detector before the named one.
private nonisolated struct VeloxPlant {
    var model: String? = "Talos F200X"
    var instrumentClass: String? = "Talos"
    var start: String? = "2026-06-05T13:05:31.000"
    var second: String? = "2026-06-05T13:05:31.000"
    var voltage: String? = "200000"
    var magnification: String? = "17749.325000000001"
    var actualMagnification: String? = "999"
    var operating: String? = "TEM"
    var projector: String? = "Imaging"
    var cameraLength: String? = "0.84399999999999997"
    var frameTime: String? = "36.945928000000002"
    var dwellDecoy: String? = "5e-06"                         // never read: no Velox STEM TIFF has shown where a dwell sits
    var detector: String? = "BM-Ceta"
    var detectors: [(element: String, name: String, exposure: String?)] = [
        ("ScanningDetector", "HAADF", nil), ("ImagingDetector", "Other-Cam", "7"), ("ImagingDetector", "BM-Ceta", "2"),
    ]

    var xml: String {
        func e(_ name: String, _ value: String?) -> String { value.map { "<\(name)>\($0)</\(name)>" } ?? "" }
        let listed = detectors.map { "<\($0.element)>\(e("DetectorName", $0.name))\(e("ExposureTime", $0.exposure))</\($0.element)>" }
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<Metadata xmlns:nil=\"http://schemas.fei.com/Metadata/v1/2013/07\">"
            + "<Instrument>\(e("InstrumentModel", model))\(e("InstrumentClass", instrumentClass))</Instrument>"
            + "<Acquisition>\(e("AcquisitionStartDatetime", start))\(e("AcquisitionDatetime", second))</Acquisition>"
            + "<Optics>\(e("AccelerationVoltage", voltage))\(e("NominalMagnification", magnification))"
            + "\(e("ActualMagnification", actualMagnification))\(e("OperatingMode", operating))\(e("ProjectorMode", projector))"
            + "\(e("CameraLength", cameraLength))</Optics>"
            + "<ScanSettings>\(e("FrameTime", frameTime))\(e("DwellTime", dwellDecoy))</ScanSettings>"
            + "<Scan>\(e("DwellTime", dwellDecoy))\(e("FrameTime", frameTime))</Scan>"
            + "<Detectors>\(listed.joined())</Detectors>"
            + "<BinaryResult>\(e("Detector", detector))</BinaryResult></Metadata>"
    }

    func tiff() -> Data {
        var file = PlantedTIFF()
        file.extra[34683] = .ascii(xml)
        return file.build()
    }

    func read() throws -> AcquisitionMetadata { try AcquisitionMetadata.tiff(data: tiff(), convention: .app) }
}

/// A minimal little-endian TIFF: a 1 × 1 grey image plus the tags a case plants. The metadata reader reads only the
/// first directory, so this is all it needs. ASCII values are NUL-terminated (as a TIFF stores them).
private nonisolated struct PlantedTIFF {
    enum Value {
        case ascii(String), short(UInt16), long(UInt32), rational(UInt32, UInt32), double(Double)
        /// An ASCII-typed tag holding exactly these bytes (the planted truth for text a UTF-8 String cannot hold).
        case bytes([UInt8])
        /// A BYTE-typed (type 1) tag holding these bytes.
        case byteArray([UInt8])
    }
    var extra: [UInt16: Value] = [:]

    func build() -> Data {
        var tags: [UInt16: Value] = [
            256: .long(1), 257: .long(1), 258: .short(8), 259: .short(1), 262: .short(1),
            273: .long(8), 277: .short(1), 278: .long(1), 279: .long(1),
        ]
        for (tag, value) in extra { tags[tag] = value }
        // Layout: header (8) | the pixel and a pad byte (offset 8, 9) | IFD (offset 10) | out-of-line values.
        let ifdStart = 10
        let keys = tags.keys.sorted()
        let heapStart = ifdStart + 2 + 12 * keys.count + 4
        var ifd = le16(keys.count)
        var heap: [UInt8] = []
        for key in keys {
            guard let value = tags[key] else { continue }
            let (type, count, payload) = encode(value)
            ifd += le16(Int(key)) + le16(type) + le32(count)
            if payload.count <= 4 {
                ifd += payload + [UInt8](repeating: 0, count: 4 - payload.count)
            } else {
                ifd += le32(heapStart + heap.count)
                heap += payload
                if heap.count % 2 == 1 { heap.append(0) }
            }
        }
        ifd += le32(0)
        return Data([0x49, 0x49] + le16(42) + le32(ifdStart) + [0x80, 0] + ifd + heap)
    }

    private func encode(_ value: Value) -> (type: Int, count: Int, payload: [UInt8]) {
        switch value {
        case .short(let v): (3, 1, le16(Int(v)))
        case .long(let v): (4, 1, le32(Int(v)))
        case .ascii(let s): (2, s.utf8.count + 1, Array(s.utf8) + [0])
        case .bytes(let b): (2, b.count, b)
        case .byteArray(let b): (1, b.count, b)
        case .rational(let n, let d): (5, 1, le32(Int(n)) + le32(Int(d)))
        case .double(let v): (12, 1, (0..<8).map { UInt8((v.bitPattern >> (8 * UInt64($0))) & 0xFF) })
        }
    }

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
}
