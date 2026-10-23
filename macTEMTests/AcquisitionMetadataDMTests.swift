//
//  AcquisitionMetadataDMTests.swift
//  archive: roadmap-registrations-2026-10-15.md V1-4a, slice S-a: the DM rules of `AcquisitionMetadata.dm(numbers:strings:)` on ImageTags maps written
//  here (keys relative to `ImageList.N.ImageTags.`), most of them the values ncempy 1.16 reads from the real
//  RosettaSciIO files (the plan: archive: v14a-plan-2026-10-12.md). Each test names the production mutation it
//  must turn red. The parity of the same rules over ncempy's maps of every real file is tools/parity/metadata-parity.
//

import XCTest
import FormatoCore
import FormatoDM
import TEMCore
@testable import macTEM

nonisolated final class AcquisitionMetadataDMTests: XCTestCase {

    private typealias Tags = (numbers: [String: Double], strings: [String: String])

    private func read(_ t: Tags) -> AcquisitionMetadata {
        AcquisitionMetadata.dm(numbers: t.numbers, strings: t.strings, convention: .app)
    }

    private let localTime = "local time, zone not stored"
    private let monthFirst = "month-first order assumed"
    private let unvalidated = "unvalidated: no published reader reads it"

    /// test_STEM_image.dm3 (RosettaSciIO), as ncempy reads it.
    private func stemImage() -> Tags {
        ([
            "Microscope Info.Voltage": 200000, "Microscope Info.Indicated Magnification": 225000,
            "Microscope Info.STEM Camera Length": 135, "DigiScan.Sample Time": 3.5,
        ], [
            "Microscope Info.Illumination Mode": "STEM NANOPROBE", "Microscope Info.Imaging Mode": "DIFFRACTION",
            "Microscope Info.Name": "FEI Tecnai Remote", "Session Info.Microscope": "FEI Titan",
            "DataBar.Acquisition Date": "8/8/2016", "DataBar.Acquisition Time": "4:26:37 PM",
        ])
    }

    /// test_diffraction_pattern.dm3: TEM diffraction, where Indicated Magnification holds the camera length.
    private func temDiffraction() -> Tags {
        ([
            "Microscope Info.Voltage": 200000, "Microscope Info.Indicated Magnification": 320,
            "Microscope Info.Actual Magnification": 32, "Microscope Info.STEM Camera Length": 0,
            "Acquisition.Parameters.Detector.exposure (s)": 0.2, "DataBar.Exposure Time (s)": 0.2,
        ], [
            "Microscope Info.Illumination Mode": "TEM", "Microscope Info.Imaging Mode": "DIFFRACTION",
            "Microscope Info.Name": "FEI Tecnai", "Acquisition.Device.Name": "BM-UltraScan",
            "DataBar.Acquisition Date": "7/9/2014", "DataBar.Acquisition Time": "6:56:37 PM",
        ])
    }

    // MARK: - Camera length and magnification by mode (rules c, g)

    func testSTEMImageReadsEveryValueInItsStatedUnit() {
        let m = read(stemImage())
        // Mutation: drop the /1e3 on Microscope Info.Voltage -> 200000, red.
        XCTAssertEqual(m.highTensionKV, MetadataReading<Double>(200))
        XCTAssertEqual(m.magnification, MetadataReading<Double>(225000))
        // Mutation: read the camera length only in TEM modes (or leave out the "mm (assumed)" note) -> red.
        XCTAssertEqual(m.cameraLengthMM, MetadataReading<Double>(135, note: "mm (assumed)"))
        // Mutation: multiply or divide the dwell (DM stores microseconds) -> red.
        XCTAssertEqual(m.dwellUS, MetadataReading<Double>(3.5))
        XCTAssertEqual(m.acquired, MetadataReading<String>("2016-08-08 16:26:37", note: "\(localTime); \(monthFirst)"))
        // Mutation: read Microscope Info.Name first (GMS's interface name) -> "FEI Tecnai Remote", red.
        XCTAssertEqual(m.instrument, MetadataReading<String>("FEI Titan"))
        // Mutation: join with another separator, or keep only the Illumination Mode -> red.
        XCTAssertEqual(m.mode, MetadataReading<String>("STEM NANOPROBE · DIFFRACTION"))
        XCTAssertNil(m.detector, "a STEM file names no camera")
        XCTAssertNil(m.exposureS)
    }

    func testTEMDiffractionTakesTheCameraLengthFromTheIndicatedMagnification() {
        let m = read(temDiffraction())
        // Mutation: read STEM Camera Length (0.0 here) instead of Indicated Magnification -> nil, red.
        XCTAssertEqual(m.cameraLengthMM, MetadataReading<Double>(320, note: "mm (assumed)"))
        // Mutation: show Indicated Magnification as the magnification here too -> 320, red.
        XCTAssertNil(m.magnification)
        XCTAssertEqual(m.highTensionKV, MetadataReading<Double>(200))
        XCTAssertEqual(m.detector, MetadataReading<String>("BM-UltraScan", note: unvalidated))
        XCTAssertNil(m.dwellUS)
    }

    func testTEMImagingIgnoresTheStaleSTEMCameraLengthAndUsesIndicatedNotActualMagnification() {
        // test_dm_image_um_unit.dm3: Indicated 51, Actual 83, STEM Camera Length 255 (a stale value).
        let t: Tags = ([
            "Microscope Info.Voltage": 200000, "Microscope Info.Indicated Magnification": 51,
            "Microscope Info.Actual Magnification": 83, "Microscope Info.STEM Camera Length": 255,
        ], [
            "Microscope Info.Illumination Mode": "TEM", "Microscope Info.Imaging Mode": "IMAGING",
        ])
        let m = read(t)
        // Mutation: read STEM Camera Length in TEM mode -> 255, red.
        XCTAssertNil(m.cameraLengthMM)
        // Mutation: read Actual Magnification in place of Indicated -> 83, red.
        XCTAssertEqual(m.magnification, MetadataReading<Double>(51))
    }

    func testAnActualMagnificationAloneIsNotAMagnification() {
        let m = read((["Microscope Info.Actual Magnification": 83], ["Microscope Info.Illumination Mode": "TEM"]))
        // Mutation: fall back to Actual Magnification when Indicated is absent -> 83, red.
        XCTAssertNil(m.magnification)
        XCTAssertEqual(m.mode, MetadataReading<String>("TEM"), "the rest of the file is still read")
    }

    func testSEMJunkCameraLengthIsNotACameraLength() {
        // test-MonarcCL_mono-image.dm4: SEM, STEM Camera Length 1.0; test-MonoCL_spectrum-SI.dm4: 0.0.
        for junk in [1.0, 0.0] {
            let t: Tags = ([
                "Microscope Info.Voltage": 3000, "Microscope Info.Indicated Magnification": 2500,
                "Microscope Info.STEM Camera Length": junk, "DigiScan.Sample Time": 10,
            ], [
                "Microscope Info.Illumination Mode": "SEM", "Microscope Info.Imaging Mode": "IMAGING",
                "Microscope Info.Name": "Zeiss SEM COM",
            ])
            let m = read(t)
            // Mutation: map STEM Camera Length in every mode but TEM (RosettaSciIO's rule) -> 1.0, red for 1.0.
            XCTAssertNil(m.cameraLengthMM, "STEM Camera Length \(junk) in an SEM file")
            XCTAssertEqual(m.highTensionKV, MetadataReading<Double>(3))
            XCTAssertEqual(m.magnification, MetadataReading<Double>(2500))
            XCTAssertEqual(m.dwellUS, MetadataReading<Double>(10))
        }
    }

    func testNoIlluminationModeMeansNoCameraLength() {
        // Rule (c): a camera length only where the mode makes it real. Without a mode nothing says it is.
        let t: Tags = (["Microscope Info.STEM Camera Length": 135, "Microscope Info.Indicated Magnification": 320],
                       ["Microscope Info.Imaging Mode": "DIFFRACTION"])
        let m = read(t)
        // Mutation: treat a missing Illumination Mode as STEM -> 135, red.
        XCTAssertNil(m.cameraLengthMM)
        XCTAssertEqual(m.magnification, MetadataReading<Double>(320), "a mode that is not TEM diffraction")
    }

    func testModeIsTheStoredStringsJoined() {
        XCTAssertEqual(read(([:], ["Microscope Info.Illumination Mode": "STEM"])).mode, MetadataReading<String>("STEM"))
        XCTAssertEqual(read(([:], ["Microscope Info.Imaging Mode": "IMAGING"])).mode, MetadataReading<String>("IMAGING"))
        XCTAssertEqual(read(([:], ["Microscope Info.Illumination Mode": "TEM", "Microscope Info.Imaging Mode": "IMAGING"])).mode,
                       MetadataReading<String>("TEM · IMAGING"))
        // Mutation: an empty or blank Imaging Mode is joined as " · " -> red.
        XCTAssertEqual(read(([:], ["Microscope Info.Illumination Mode": "SEM", "Microscope Info.Imaging Mode": "  "])).mode,
                       MetadataReading<String>("SEM"))
    }

    // MARK: - The date (rule e)

    private func acquired(_ date: String, _ time: String) -> MetadataReading<String>? {
        read(([:], ["DataBar.Acquisition Date": date, "DataBar.Acquisition Time": time])).acquired
    }

    func testTheDateIsMonthFirstUnlessTheFirstFieldExceedsTwelve() {
        // test_diffraction_pattern.dm3 "7/9/2014": July 9th, and both fields could be a month.
        // Mutation: swap the order (always day first) -> 2014-09-07, red.
        XCTAssertEqual(acquired("7/9/2014", "6:56:37 PM"),
                       MetadataReading<String>("2014-07-09 18:56:37", note: "\(localTime); \(monthFirst)"))
        // 13 cannot be a month: day first, and nothing was assumed.
        // Mutation: always month first -> 13 is no month, nil, red.
        XCTAssertEqual(acquired("13/5/2020", "6:56:37 PM"),
                       MetadataReading<String>("2020-05-13 18:56:37", note: localTime))
        // The second field cannot be a day-first month: month first, nothing assumed.
        // Mutation: the order note whenever month-first is chosen -> red.
        XCTAssertEqual(acquired("5/17/2015", "5:00:16 PM"),
                       MetadataReading<String>("2015-05-17 17:00:16", note: localTime))
        XCTAssertEqual(acquired("9/16/2021", "12:06:16 PM"),
                       MetadataReading<String>("2021-09-16 12:06:16", note: localTime))
        // Both fields are 12 or less and differ, so either could be the month: the note stays.
        XCTAssertEqual(acquired("12/10/2019", "3:32:41 PM"),
                       MetadataReading<String>("2019-12-10 15:32:41", note: "\(localTime); \(monthFirst)"))
    }

    func testTheDateLayoutsOfTheRealFilesAreRead() {
        // Fei HAADF-DE: "27.08.2016" "20:54:33" (dots, 24-hour); FR / UK: "27/08/2016" "20:55:20"; MX: "08:55:59 p.m.".
        XCTAssertEqual(acquired("27.08.2016", "20:54:33"), MetadataReading<String>("2016-08-27 20:54:33", note: localTime))
        XCTAssertEqual(acquired("27/08/2016", "20:55:20"), MetadataReading<String>("2016-08-27 20:55:20", note: localTime))
        // Mutation: ignore the p.m. marker -> 08:55:59, red.
        XCTAssertEqual(acquired("27/08/2016", "08:55:59 p.m."), MetadataReading<String>("2016-08-27 20:55:59", note: localTime))
        // A narrow no-break space before PM (newer systems) and a lower-case marker.
        XCTAssertEqual(acquired("8/27/2016", "4:26:37\u{202F}PM")?.value, "2016-08-27 16:26:37")
        XCTAssertEqual(acquired("8/27/2016", "4:26:37 pm")?.value, "2016-08-27 16:26:37")
    }

    func testTwelveAMIsHourZeroAndTwelvePMIsNoon() {
        // Mutation: add 12 for every PM / drop the `% 12` -> 12 AM reads 12 and 12 PM reads 24, red.
        XCTAssertEqual(acquired("9/16/2021", "12:00:01 AM")?.value, "2021-09-16 00:00:01")
        XCTAssertEqual(acquired("9/16/2021", "12:06:16 PM")?.value, "2021-09-16 12:06:16")
        XCTAssertEqual(acquired("9/16/2021", "1:00:00 AM")?.value, "2021-09-16 01:00:00")
        XCTAssertEqual(acquired("9/16/2021", "11:59:59 PM")?.value, "2021-09-16 23:59:59")
    }

    func testADateThatCannotBeReadExactlyIsNil() {
        // Mutation: read a date without a time as midnight, or a time without a date -> not nil, red.
        XCTAssertNil(read(([:], ["DataBar.Acquisition Date": "8/8/2016"])).acquired, "a date without a time")
        XCTAssertNil(read(([:], ["DataBar.Acquisition Time": "4:26:37 PM"])).acquired, "a time without a date")
        XCTAssertNil(acquired("notadate", "4:26:37 PM"))
        XCTAssertNil(acquired("", "4:26:37 PM"))
        XCTAssertNil(acquired("8/8/2016", "  "))
        // Layouts not seen on any file are not guessed: year first, a two-digit year, no seconds, no such day.
        XCTAssertNil(acquired("2016-08-08", "4:26:37 PM"))
        XCTAssertNil(acquired("8/8/16", "4:26:37 PM"))
        XCTAssertNil(acquired("8/8/2016", "4:26 PM"))
        XCTAssertNil(acquired("8/8/2016", "4:26:37 XM"))
        // Mutation: no days-in-month check -> 2021-02-29 and 2020-04-31 are read, red.
        XCTAssertNil(acquired("2/29/2021", "4:26:37 PM"))
        XCTAssertNil(acquired("31/04/2020", "4:26:37 PM"))
        XCTAssertEqual(acquired("2/29/2020", "4:26:37 PM")?.value, "2020-02-29 16:26:37", "2020 is a leap year")
        // A 12-hour clock needs an hour of 1 to 12; a 24-hour one 0 to 23; minutes and seconds under 60.
        XCTAssertNil(acquired("8/8/2016", "13:00:00 PM"))
        XCTAssertNil(acquired("8/8/2016", "0:30:00 AM"))
        XCTAssertNil(acquired("8/8/2016", "24:00:00"))
        XCTAssertNil(acquired("8/8/2016", "10:60:00"))
        XCTAssertNil(acquired("8/8/2016", "10:00:61"))
        XCTAssertNil(acquired("13/13/2020", "10:00:00"))
    }

    // MARK: - Two stored copies of the exposure (rule f)

    func testDifferingExposureCopiesAreBothKeptAndEqualOnesAreNot() {
        func exposure(detector: Double?, dataBar: Double?) -> MetadataReading<Double>? {
            var n: [String: Double] = [:]
            if let detector { n["Acquisition.Parameters.Detector.exposure (s)"] = detector }
            if let dataBar { n["DataBar.Exposure Time (s)"] = dataBar }
            return read((n, [:])).exposureS
        }
        // Mutation: otherCopy always nil -> red.
        XCTAssertEqual(exposure(detector: 0.2, dataBar: 0.25), MetadataReading<Double>(0.2, otherCopy: 0.25))
        // Mutation: the DataBar copy listed first -> value 0.25, red.
        XCTAssertEqual(exposure(detector: 0.25, dataBar: 0.2), MetadataReading<Double>(0.25, otherCopy: 0.2))
        // Mutation: otherCopy whenever the second exists (no 1e-6 test) -> red on the next two.
        XCTAssertEqual(exposure(detector: 0.2, dataBar: 0.2), MetadataReading<Double>(0.2))
        XCTAssertEqual(exposure(detector: 0.2, dataBar: 0.2 * (1 + 1e-7)), MetadataReading<Double>(0.2))
        XCTAssertEqual(exposure(detector: 0.2, dataBar: 0.2 * (1 + 1e-5)), MetadataReading<Double>(0.2, otherCopy: 0.2 * (1 + 1e-5)))
        // One alone is used. Only the DataBar copy is unread by RosettaSciIO, so only it is labelled.
        XCTAssertEqual(exposure(detector: 0.5, dataBar: nil), MetadataReading<Double>(0.5))
        XCTAssertEqual(exposure(detector: nil, dataBar: 0.05), MetadataReading<Double>(0.05, note: unvalidated))
        // A copy stored as zero is no copy (rule b): the other one stands alone.
        XCTAssertEqual(exposure(detector: 0, dataBar: 0.3), MetadataReading<Double>(0.3, note: unvalidated))
        XCTAssertEqual(exposure(detector: 0.3, dataBar: 0), MetadataReading<Double>(0.3))
        XCTAssertNil(exposure(detector: nil, dataBar: nil))
        XCTAssertNil(exposure(detector: 0, dataBar: -1))
    }

    // MARK: - GMS stack builder: source.Tags at creation.

    func testTheStackBuildersCopyFillsOnlyAnAbsentDirectKey() {
        // test_stackbuilder_imagestack.dm3: every tag lives under "source.Tags at creation.".
        let p = "source.Tags at creation."
        let copy: Tags = ([
            p + "Microscope Info.Voltage": 200000, p + "Microscope Info.Indicated Magnification": 200000,
            p + "Microscope Info.STEM Camera Length": 15, p + "DigiScan.Sample Time": 30000.05078125,
        ], [
            p + "Microscope Info.Illumination Mode": "STEM", p + "Microscope Info.Imaging Mode": "MAG",
            p + "Microscope Info.Name": "JEOL COM",
            p + "DataBar.Acquisition Date": "5/17/2015", p + "DataBar.Acquisition Time": "5:00:16 PM",
        ])
        let m = read(copy)
        // Mutation: the fallback removed -> every field nil, red.
        XCTAssertEqual(m.highTensionKV, MetadataReading<Double>(200))
        XCTAssertEqual(m.magnification, MetadataReading<Double>(200000))
        XCTAssertEqual(m.cameraLengthMM, MetadataReading<Double>(15, note: "mm (assumed)"))
        XCTAssertEqual(m.dwellUS, MetadataReading<Double>(30000.05078125))
        XCTAssertEqual(m.acquired, MetadataReading<String>("2015-05-17 17:00:16", note: localTime))
        XCTAssertEqual(m.instrument, MetadataReading<String>("JEOL COM"))
        XCTAssertEqual(m.mode, MetadataReading<String>("STEM · MAG"))

        // The direct key wins when both exist and disagree, and the copy is not shown as a second copy.
        // Mutation: the copy read first -> 200 kV, red.
        var both = copy
        both.numbers["Microscope Info.Voltage"] = 300000
        XCTAssertEqual(read(both).highTensionKV, MetadataReading<Double>(300))
        // A direct key that is present but unusable is the file's own statement: not replaced from the copy.
        // Mutation: fall back when the direct value is zero (or empty) rather than absent -> 200 kV / "JEOL COM", red.
        var zero = copy
        zero.numbers["Microscope Info.Voltage"] = 0
        zero.strings["Microscope Info.Name"] = ""
        XCTAssertNil(read(zero).highTensionKV)
        XCTAssertNil(read(zero).instrument)
    }

    // MARK: - The instrument: RosettaSciIO's order (get_mapping :820-837 behind the :963 gate)

    private func instrument(_ strings: [String: String], numbers: [String: Double] = [:]) -> MetadataReading<String>? {
        read((numbers, strings)).instrument
    }

    func testTheSessionMicroscopeWinsOverTheInterfaceNameAndThatOverTheThirdLocation() {
        // test_STEM_image.dm3 and the four Fei HAADF files: "FEI Titan" typed into GMS beside the COM name.
        // Mutation: Microscope Info.Name read first (the archived plan's order) -> "FEI Tecnai Remote", red.
        XCTAssertEqual(instrument(["Session Info.Microscope": "FEI Titan", "Microscope Info.Name": "FEI Tecnai Remote"]),
                       MetadataReading<String>("FEI Titan"))
        // multi_signal.dm3.
        XCTAssertEqual(instrument(["Session Info.Microscope": "Example Microscope", "Microscope Info.Name": "FEI Tecnai Remote"]),
                       MetadataReading<String>("Example Microscope"))
        // Name before Microscope Info.Microscope.
        // Mutation: Microscope Info.Microscope read before Microscope Info.Name -> "Third Scope", red.
        XCTAssertEqual(instrument(["Microscope Info.Name": "FEI Tecnai", "Microscope Info.Microscope": "Third Scope"]),
                       MetadataReading<String>("FEI Tecnai"))
        // The session name alone, trimmed (rule a), with no note: it is the one RosettaSciIO reads.
        XCTAssertEqual(instrument(["Session Info.Microscope": "  FEI Titan\n", "Microscope Info.Name": ""]),
                       MetadataReading<String>("FEI Titan"))
    }

    func testAnAbsentOrEmptySessionMicroscopeFallsBackToTheName() {
        // test_diffraction_pattern.dm3 and test_dm_image_um_unit.dm3: no Session Info.Microscope at all.
        // Mutation: Session Info.Microscope read alone (the Name fallback removed) -> nil, red.
        XCTAssertEqual(instrument(["Microscope Info.Name": "FEI Tecnai", "Microscope Info.Microscope": ""]),
                       MetadataReading<String>("FEI Tecnai"))
        // test-MonarcCL_mono-image.dm4: the key is there and empty.
        // Mutation: take the first PRESENT location instead of the first non-empty one -> nil, red.
        XCTAssertEqual(instrument(["Session Info.Microscope": "", "Microscope Info.Name": "Zeiss SEM COM"]),
                       MetadataReading<String>("Zeiss SEM COM"))
        // The text "[]" is passed over like an empty one (:834).
        // Mutation: "[]" accepted as a name -> "[]", red.
        XCTAssertEqual(instrument(["Session Info.Microscope": "[]", "Microscope Info.Name": "Zeiss SEM COM"]),
                       MetadataReading<String>("Zeiss SEM COM"))
        // A whitespace-only value is empty here (rule a; the DEVIATION in the header).
        // Mutation: emptiness tested before the text is trimmed -> a reading of "", red.
        XCTAssertEqual(instrument(["Session Info.Microscope": " \t\n", "Microscope Info.Name": "Zeiss SEM COM"]),
                       MetadataReading<String>("Zeiss SEM COM"))
        XCTAssertEqual(instrument(["Session Info.Microscope": "FEI Titan", "Microscope Info.Name": " [] "]),
                       MetadataReading<String>("FEI Titan"), "the session name still wins")
    }

    func testTheThirdLocationIsReadAndAnEmptyChainIsNil() {
        // Mutation: Microscope Info.Microscope not read -> nil, red.
        XCTAssertEqual(instrument(["Session Info.Microscope": "", "Microscope Info.Name": "[]",
                                   "Microscope Info.Microscope": "Third Scope"]),
                       MetadataReading<String>("Third Scope"))
        // Nothing usable anywhere: not recorded, never "" or "[]" (rule a).
        // Mutation: the last location's text returned unchecked -> "[]", red.
        XCTAssertNil(instrument(["Session Info.Microscope": "[]", "Microscope Info.Name": "",
                                 "Microscope Info.Microscope": "[]"]))
        XCTAssertNil(instrument(["Session Info.Microscope": "  ", "Microscope Info.Name": "\t"]))
    }

    func testTheInstrumentIsReadOnlyWhereTheFileHasAMicroscopeInfoGroup() {
        // get_mapping maps the microscope inside `if "Microscope Info" in image_tags_dict.keys()` (:963).
        // Mutation: the gate removed -> "FEI Titan", red.
        XCTAssertNil(instrument(["Session Info.Microscope": "FEI Titan", "Session Info.Operator": "someone"]))
        XCTAssertNil(read((["DigiScan.Sample Time": 10], ["Session Info.Microscope": "FEI Titan"])).instrument)
        // Any scalar tag of the group opens it, a number as well as a string.
        XCTAssertEqual(read((["Microscope Info.Voltage": 200000], ["Session Info.Microscope": "FEI Titan"])).instrument,
                       MetadataReading<String>("FEI Titan"))
        XCTAssertEqual(instrument(["Microscope Info.Illumination Mode": "TEM", "Session Info.Microscope": "FEI Titan"]),
                       MetadataReading<String>("FEI Titan"))
        // The group's name is matched whole: a neighbour's prefix does not open it.
        // Mutation: the prefix test without the closing "." -> "FEI Titan", red.
        XCTAssertNil(instrument(["Microscope Information.Name": "x", "Session Info.Microscope": "FEI Titan"]))
    }

    func testTheStackBuildersSessionMicroscopeIsResolvedKeyByKey() {
        // test_stackbuilder_imagestack.dm3: both names live under the copy ("JEM-ARM200F", "JEOL COM").
        let p = "source.Tags at creation."
        let copy = [p + "Session Info.Microscope": "JEM-ARM200F", p + "Microscope Info.Name": "JEOL COM"]
        // Mutation: Session Info.Microscope not looked up under the copy -> "JEOL COM", red.
        XCTAssertEqual(instrument(copy), MetadataReading<String>("JEM-ARM200F"))
        // The direct key wins when both exist.
        // Mutation: the copy read first -> "JEM-ARM200F", red.
        XCTAssertEqual(instrument(copy.merging(["Session Info.Microscope": "FEI Titan"]) { $1 }),
                       MetadataReading<String>("FEI Titan"))
        // A direct key that is present but empty is the file's statement and is not replaced from the copy; the next
        // location is then tried (itself resolved direct, else copy).
        // Mutation: fall back to the copy when the direct value is empty -> "JEM-ARM200F", red.
        XCTAssertEqual(instrument(copy.merging(["Session Info.Microscope": ""]) { $1 }),
                       MetadataReading<String>("JEOL COM"))
        // Only the copy has the group: it opens the gate.
        XCTAssertEqual(instrument([p + "Microscope Info.Illumination Mode": "STEM", p + "Session Info.Microscope": "JEM-ARM200F"]),
                       MetadataReading<String>("JEM-ARM200F"))
    }

    // MARK: - Nothing recorded (rules a, b)

    func testAbsentEmptyAndNonPositiveTagsAreNilNeverZero() {
        // Mutation: nil as 0 (e.g. `?? 0` on any numeric tag) -> a 0 kV reading, red.
        XCTAssertTrue(read(([:], [:])).isEmpty, "no tags at all (the test-N.dm3 files carry no ImageTags)")
        XCTAssertEqual(read(([:], [:])), AcquisitionMetadata())

        // Every string present but empty or blank.
        let blank = ["Microscope Info.Illumination Mode", "Microscope Info.Imaging Mode", "Microscope Info.Name",
                     "Acquisition.Device.Name", "DataBar.Acquisition Date", "DataBar.Acquisition Time"]
        XCTAssertTrue(read(([:], Dictionary(uniqueKeysWithValues: blank.map { ($0, " \t") }))).isEmpty)

        // Rule (b): zero, negative or non-finite quantities, in a STEM file so the camera length is eligible.
        let quantities = ["Microscope Info.Voltage", "Microscope Info.Indicated Magnification",
                          "Microscope Info.STEM Camera Length", "DigiScan.Sample Time",
                          "Acquisition.Parameters.Detector.exposure (s)", "DataBar.Exposure Time (s)"]
        for bad in [0.0, -0.0, -1.0, -1e-30, .nan, .infinity, -.infinity] {
            let numbers = Dictionary(uniqueKeysWithValues: quantities.map { ($0, bad) })
            let m = read((numbers, ["Microscope Info.Illumination Mode": "STEM"]))
            XCTAssertNil(m.highTensionKV, "\(bad)")
            XCTAssertNil(m.magnification, "\(bad)")
            XCTAssertNil(m.cameraLengthMM, "\(bad)")
            XCTAssertNil(m.dwellUS, "\(bad)")
            XCTAssertNil(m.exposureS, "\(bad)")
        }
        // TEM diffraction whose Indicated Magnification is zero: no camera length either.
        let diffraction = read((["Microscope Info.Indicated Magnification": 0],
                                ["Microscope Info.Illumination Mode": "TEM", "Microscope Info.Imaging Mode": "DIFFRACTION"]))
        XCTAssertNil(diffraction.cameraLengthMM)
        XCTAssertNil(diffraction.magnification)
    }

    func testAVoltageThatConvertsToZeroKilovoltsIsNotRecordedAndOneThatStaysFiniteIs() {
        // Rule (b) holds for the number as shown, after the unit conversion. Mutation (AcquisitionMetadata+DM.swift):
        // positive() on the stored Voltage BEFORE the /1e3 (`positive(tags.number(…)).map { $0 / 1e3 }` in place of
        // `positive(tags.number(…).map { $0 / 1e3 })`) — the finite 5e-324 V then reads as 0.0 kV. (A huge voltage
        // stays finite after /1e3; the other DM quantities are stored in the unit shown and convert nothing.)
        let prefix = "source.Tags at creation."
        for key in ["Microscope Info.Voltage", prefix + "Microscope Info.Voltage"] {
            XCTAssertNil(read(([key: 5e-324], [:])).highTensionKV, "\(key) = 5e-324 V is 0.0 kV")
            XCTAssertEqual(read(([key: 1e306], [:])).highTensionKV, MetadataReading<Double>(1e306 / 1e3), key)
            XCTAssertEqual(read(([key: 1e-320], [:])).highTensionKV, MetadataReading<Double>(1e-320 / 1e3), "\(key) = 1e-320 V")
        }
    }

    func testSurroundingWhitespaceIsTrimmedFromText() {
        let m = read(([:], ["Microscope Info.Name": " FEI Tecnai\n", "Acquisition.Device.Name": "\tBM-UltraScan "]))
        // Mutation: text() not trimming -> " FEI Tecnai\n" and "\tBM-UltraScan " kept as written, red.
        XCTAssertEqual(m.instrument, MetadataReading<String>("FEI Tecnai"))
        XCTAssertEqual(m.detector, MetadataReading<String>("BM-UltraScan", note: unvalidated))
    }
}
