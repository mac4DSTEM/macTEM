//
//  NORDIFReaderTests.swift
//  The NORDIF readers (Sources/TEMCore/SEM/NORDIF) against kikuchipy 0.13.1 on the in-package NORDIF folder
//  (Fixtures/sem/nordif, kikuchipy's `data/nordif`): reference.json is written by tools/parity/sem/nordif/reference.py
//  from `kikuchipy.load` and holds the settings, the detector, the SHA-256 of every pattern block in map order with its
//  corner rows, the calibration positions and their scaled forms, and the sentence each damaged settings file is
//  refused with. Settings exact, patterns bit-exact, positions exact; a number is compared with XCTAssertEqual, no
//  tolerance, because every one is read from text or an integer header.
//

import XCTest
import CryptoKit
import TEMCore

nonisolated final class NORDIFReaderTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sem/nordif")
    /// reference.json, read per test (37 KB): a shared static of `[String: Any]` is not Sendable under Swift 6.
    private var reference: [String: Any] {
        let data = try! Data(contentsOf: Self.folder.appendingPathComponent("reference.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func path(_ name: String) -> String { Self.folder.appendingPathComponent(name).path }
    private var scratch: [URL] = []
    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    /// A file in a fresh temporary folder, removed at tearDown.
    private func scratchFile(named name: String, contents: Data) -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nordif-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scratch.append(folder)
        let url = folder.appendingPathComponent(name)
        try! contents.write(to: url)
        return url.path
    }
    private func acquisition(_ file: String) -> [String: Any] { (reference["acquisition"] as! [String: Any])[file] as! [String: Any] }
    private func calibration(_ file: String) -> [String: Any] { (reference["calibration"] as! [String: Any])[file] as! [String: Any] }
    private func ints(_ any: Any?) -> [Int]? { (any as? [NSNumber])?.map(\.intValue) }
    private func pairs(_ any: Any?) -> [[Int]]? { (any as? [[NSNumber]])?.map { $0.map(\.intValue) } }
    private func sha256(_ bytes: some Sequence<UInt8>) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Shape, hash and the four corner rows of a pattern block, against `array_block` in reference.py.
    private func assertBlock(_ block: [String: Any], bytes: [UInt8], shape: [Int], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ints(block["shape"]), shape, file: file, line: line)
        XCTAssertEqual(block["dtype"] as? String, "uint8", file: file, line: line)
        XCTAssertEqual(sha256(bytes), block["sha256"] as? String, "bit-exact block", file: file, line: line)
        let width = shape[shape.count - 1], pixels = width * shape[shape.count - 2]
        func row(_ from: Int) -> [Int] { bytes[from ..< from + width].map(Int.init) }
        XCTAssertEqual(row(0), ints(block["first_pattern_first_row"]), file: file, line: line)
        XCTAssertEqual(row(pixels - width), ints(block["first_pattern_last_row"]), file: file, line: line)
        XCTAssertEqual(row(bytes.count - pixels), ints(block["last_pattern_first_row"]), file: file, line: line)
        XCTAssertEqual(row(bytes.count - width), ints(block["last_pattern_last_row"]), file: file, line: line)
    }

    private func assertDetector(_ detector: NORDIFSettings.Detector, _ expected: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual([detector.rows, detector.columns], ints(expected["shape"]), file: file, line: line)
        XCTAssertEqual([detector.pcx, detector.pcy, detector.pcz], (expected["pc"] as? [NSNumber])?.map(\.doubleValue), file: file, line: line)
        XCTAssertEqual(detector.sampleTiltDeg, (expected["sample_tilt"] as? NSNumber)?.doubleValue, file: file, line: line)
        XCTAssertEqual(detector.tiltDeg, (expected["tilt"] as? NSNumber)?.doubleValue, file: file, line: line)
        XCTAssertEqual(detector.tiltDeg.sign, .plus, "never -0.0", file: file, line: line)
        XCTAssertEqual(detector.azimuthalDeg, (expected["azimuthal"] as? NSNumber)?.doubleValue, file: file, line: line)
        XCTAssertEqual(detector.binning, (expected["binning"] as? NSNumber)?.intValue, file: file, line: line)
        XCTAssertEqual(detector.pixelSizeUM, (expected["px_size"] as? NSNumber)?.doubleValue, file: file, line: line)
    }

    // MARK: - The fixtures are the reference's

    func testTheFixtureFilesAreTheOnesTheReferenceRead() throws {
        let files = try XCTUnwrap(reference["files"] as? [String: String])
        XCTAssertEqual(files.count, 9)
        for (name, hash) in files {
            XCTAssertEqual(sha256(try Data(contentsOf: Self.folder.appendingPathComponent(name))), hash, name)
        }
        let reference = try XCTUnwrap(reference["reference"] as? [String: String])
        XCTAssertEqual(reference["package"], "kikuchipy")
        XCTAssertEqual(reference["version"], "0.13.1")
    }

    // MARK: - Setting.txt

    func testSettingsReadEveryFieldKikuchipyReads() throws {
        let s = try NORDIFSettings.read(path: path("Setting.txt"))
        let r = acquisition("Setting.txt")
        XCTAssertEqual(s.microscope, r["microscope"] as? String)
        XCTAssertEqual(s.manufacturer, "Hitachi")
        XCTAssertEqual(s.model, "SU-6600")
        XCTAssertEqual(s.acceleratingVoltageKV, (r["beam_energy_kv"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(s.magnification, (r["magnification"] as? NSNumber)?.intValue)
        XCTAssertEqual(s.workingDistanceMM, (r["working_distance_mm"] as? NSNumber)?.doubleValue)
        XCTAssertEqual([s.area.rows, s.area.columns], ints(r["navigation_shape_yx"]))
        XCTAssertEqual([s.area.stepUM, s.area.stepUM], (r["step_um"] as? [NSNumber])?.map(\.doubleValue))
        XCTAssertEqual([s.acquisition.resolution.height, s.acquisition.resolution.width], ints(r["pattern_shape_yx"]))
        assertDetector(s.detector, try XCTUnwrap(r["detector"] as? [String: Any]))
        // Beyond kikuchipy's metadata: the lines the app shows.
        XCTAssertEqual(s.softwareVersion, "3.1.2")
        XCTAssertEqual(s.scanDirection, "Direct")
        XCTAssertEqual(s.tiltAngleDeg, 70)
        XCTAssertEqual(s.electronImageResolution, NORDIFSettings.Resolution(width: 1000, height: 1000))
        XCTAssertEqual(s.detectorModel, "UF1100")
        XCTAssertEqual(s.eulerDeg, [0, 0, 0])
        XCTAssertEqual(s.acquisition.frameRateFPS, 202)
        XCTAssertEqual(s.acquisition.exposureUS, 3500)
        XCTAssertEqual(s.acquisition.gain, 0)
        XCTAssertEqual(s.calibration?.resolution, NORDIFSettings.Resolution(width: 60, height: 60))
        XCTAssertEqual(s.calibration?.frameRateFPS, 10)
        XCTAssertEqual(s.calibration?.exposureUS, 99950)
        XCTAssertEqual(s.calibration?.gain, 8)
        XCTAssertEqual(s.specimenName, "Ni")
        XCTAssertEqual(s.area.top, NORDIFSettings.Measure(micrometres: 89.2, pixels: 223))
        XCTAssertEqual(s.area.left, NORDIFSettings.Measure(micrometres: 60.384, pixels: 152))
        XCTAssertEqual(s.area.width, NORDIFSettings.Measure(micrometres: 4.5, pixels: 11))
        XCTAssertEqual(s.area.height, NORDIFSettings.Measure(micrometres: 4.5, pixels: 11))
        XCTAssertEqual(s.area.scanTime, "00:02:28")
        XCTAssertEqual(s.acquisitionPositions, [NORDIFSettings.Position(x: 507, y: 500), .init(x: 393, y: 501), .init(x: 440, y: 448)])
        XCTAssertEqual(s.calibrationPositions, [NORDIFSettings.Position(x: 425, y: 447), .init(x: 294, y: 532)])
        XCTAssertEqual(s.lines.count, 92, "kikuchipy's nordif_header has 92 lines")
        XCTAssertEqual(s.lines[10], "Tilt angle\t70\t°", "Latin-1, as kikuchipy decodes it")
    }

    func testTheDetectorTiltIsMinusTheElevationAndNeverMinusZero() throws {
        var lines = try NORDIFSettings.read(path: path("Setting.txt")).lines
        XCTAssertEqual(try NORDIFSettings.parse(lines: lines, fileName: "Setting.txt").detector.tiltDeg.sign, .plus)
        lines[43] = "Elevation\t12.5\t°"
        let tilted = try NORDIFSettings.parse(lines: lines, fileName: "Setting.txt")
        XCTAssertEqual(tilted.elevationDeg, 12.5)
        XCTAssertEqual(tilted.detector.tiltDeg, -12.5)
    }

    func testAFileWithoutAMicroscopeSectionIsNotASettingsFile() throws {
        XCTAssertThrowsError(try NORDIFSettings.parse(Data("[Area]\t\t\nStep size\t1\tµm\n".utf8), fileName: "notes.txt")) { error in
            XCTAssertEqual(error as? NORDIFSettings.Refusal, .notSettings("notes.txt"))
            XCTAssertEqual((error as? NORDIFSettings.Refusal)?.reason, "notes.txt is not a NORDIF settings file (no [Microscope] section).")
        }
    }

    func testAMissingRequiredLineIsRefusedByItsSectionAndKey() throws {
        let lines = try NORDIFSettings.read(path: path("Setting.txt")).lines
        XCTAssertThrowsError(try NORDIFSettings.parse(lines: lines.filter { !$0.hasPrefix("Number of samples") }, fileName: "Setting.txt")) { error in
            XCTAssertEqual(error as? NORDIFSettings.Refusal, .missing(section: "Area", key: "Number of samples"))
            XCTAssertEqual((error as? NORDIFSettings.Refusal)?.reason, "its [Area] section has no 'Number of samples' line.")
        }
        XCTAssertThrowsError(try NORDIFSettings.parse(lines: lines.map { $0 == "Step size\t1.500\tµm" ? "Step size\tfast\tµm" : $0 }, fileName: "Setting.txt")) { error in
            XCTAssertEqual(error as? NORDIFSettings.Refusal, .notANumber(section: "Area", key: "Step size", value: "fast"))
        }
    }

    func testAZeroOrNegativeSizeIsRefusedByItsSectionAndKeyBeforeAnyReaderUsesIt() throws {
        let lines = try NORDIFSettings.read(path: path("Setting.txt")).lines
        XCTAssertEqual(lines[47], "Resolution\t60x60\tpx", "[Acquisition settings]")
        XCTAssertEqual(lines[53], "Resolution\t60x60\tpx", "[Calibration settings]")
        XCTAssertEqual(lines[79], "Number of samples\t3x3\t#")
        var flat = lines
        flat[47] = "Resolution\t0x0\tpx"
        var backwards = lines
        backwards[79] = "Number of samples\t-2x3\t#"
        XCTAssertThrowsError(try NORDIFSettings.parse(lines: flat, fileName: "Setting.txt")) { error in
            XCTAssertEqual(error as? NORDIFSettings.Refusal, .notPositive(section: "Acquisition settings", key: "Resolution", value: "0x0"))
            XCTAssertEqual((error as? NORDIFSettings.Refusal)?.reason, "its [Acquisition settings] 'Resolution' value '0x0' has a size below 1.")
        }
        XCTAssertThrowsError(try NORDIFSettings.parse(lines: backwards, fileName: "Setting.txt")) { error in
            XCTAssertEqual(error as? NORDIFSettings.Refusal, .notPositive(section: "Area", key: "Number of samples", value: "-2x3"))
        }
        // The door divided by the record size and the scan took a negative prefix of the file: both now stop at the settings, in words.
        let flatFile = scratchFile(named: "Setting.txt", contents: try XCTUnwrap(flat.joined(separator: "\r\n").data(using: .isoLatin1)))
        XCTAssertThrowsError(try NORDIFOpening.open(url: URL(fileURLWithPath: path("Pattern.dat")), settingsFile: URL(fileURLWithPath: flatFile))) { error in
            XCTAssertEqual(error as? EBSDReadError,
                           EBSDReadError(text: "Setting.txt cannot be read: its [Acquisition settings] 'Resolution' value '0x0' has a size below 1."))
        }
        let backwardsFile = scratchFile(named: "Setting.txt", contents: try XCTUnwrap(backwards.joined(separator: "\r\n").data(using: .isoLatin1)))
        XCTAssertThrowsError(try NORDIFScan.read(patternFile: path("Pattern.dat"), settingsFile: backwardsFile)) { error in
            XCTAssertEqual(error as? NORDIFSettings.Refusal, .notPositive(section: "Area", key: "Number of samples", value: "-2x3"))
        }
        // The calibration resolution sizes nothing and is kept as written.
        var calibration = lines
        calibration[53] = "Resolution\t0x0\tpx"
        let kept = try NORDIFSettings.parse(lines: calibration, fileName: "Setting.txt")
        XCTAssertEqual(kept.calibration?.resolution, NORDIFSettings.Resolution(width: 0, height: 0))
    }

    /// A scan whose bytes (rows x columns x width x height, uint8) no Int counts is refused at the settings, with both lines as
    /// written, so the routing and the door say so in words. Red before: the parse read on, and the door's and the scan's products
    /// overflowed and trapped.
    func testASizeTooLargeToCountIsRefusedAtTheSettings() throws {
        let lines = try NORDIFSettings.read(path: path("Setting.txt")).lines
        XCTAssertEqual(lines[47], "Resolution\t60x60\tpx", "[Acquisition settings]")
        XCTAssertEqual(lines[79], "Number of samples\t3x3\t#")
        var manySamples = lines
        manySamples[79] = "Number of samples\t4000000000x4000000000\t#"
        var largePatterns = lines
        largePatterns[47] = "Resolution\t4000000000x4000000000\tpx"
        let cases: [([String], NORDIFSettings.Refusal)] = [
            (manySamples, .tooLarge(samples: "4000000000x4000000000", resolution: "60x60")),
            (largePatterns, .tooLarge(samples: "3x3", resolution: "4000000000x4000000000")),
        ]
        for (edited, refusal) in cases {
            XCTAssertThrowsError(try NORDIFSettings.parse(lines: edited, fileName: "Setting.txt")) { error in
                XCTAssertEqual(error as? NORDIFSettings.Refusal, refusal)
            }
            let file = scratchFile(named: "Setting.txt", contents: try XCTUnwrap(edited.joined(separator: "\r\n").data(using: .isoLatin1)))
            let sentence = "Setting.txt cannot be read: \(refusal.reason)"
            XCTAssertThrowsError(try NORDIFOpening.open(url: URL(fileURLWithPath: path("Pattern.dat")), settingsFile: URL(fileURLWithPath: file))) { error in
                XCTAssertEqual(error as? EBSDReadError, EBSDReadError(text: sentence))
            }
            XCTAssertThrowsError(try NORDIFScan.read(patternFile: path("Pattern.dat"), settingsFile: file)) { error in
                XCTAssertEqual(error as? NORDIFSettings.Refusal, refusal)
            }
            // The routing refuses the scan with the same sentence, before any open.
            let pattern = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Pattern.dat")
            try FileManager.default.copyItem(at: Self.folder.appendingPathComponent("Pattern.dat"), to: pattern)
            XCTAssertEqual(EBSDOpening.vendorRefusal(url: pattern), sentence)
        }
        XCTAssertEqual(NORDIFSettings.Refusal.tooLarge(samples: "4000000000x4000000000", resolution: "60x60").reason,
                       "its [Area] 'Number of samples' value '4000000000x4000000000' with its [Acquisition settings] 'Resolution' value "
                           + "'60x60' is more bytes than can be counted.")
    }

    // MARK: - Pattern.dat

    func testPatternDatReadsBitExactInMapOrder() throws {
        let scan = try NORDIFScan.read(patternFile: path("Pattern.dat"))
        let r = acquisition("Setting.txt")
        XCTAssertEqual([scan.rows, scan.columns], ints(r["navigation_shape_yx"]))
        XCTAssertEqual([scan.patternRows, scan.patternColumns], ints(r["pattern_shape_yx"]))
        XCTAssertEqual(scan.stepUM, 1.5)
        XCTAssertNil(scan.note)
        assertBlock(try XCTUnwrap(r["data"] as? [String: Any]), bytes: scan.patterns,
                    shape: [scan.rows, scan.columns, scan.patternRows, scan.patternColumns])
        assertDetector(scan.detector, try XCTUnwrap(r["detector"] as? [String: Any]))
        // pattern(row:column:) walks the block in map order: (0,0) first, (ny-1, nx-1) last.
        XCTAssertEqual(scan.pattern(row: 0, column: 0).prefix(60).map(Int.init), ints((r["data"] as? [String: Any])?["first_pattern_first_row"]))
        XCTAssertEqual(scan.pattern(row: 2, column: 2).suffix(60).map(Int.init), ints((r["data"] as? [String: Any])?["last_pattern_last_row"]))
        XCTAssertEqual(Array(scan.pattern(row: 0, column: 1)), Array(scan.patterns[3600 ..< 7200]))
        let background = try XCTUnwrap(scan.staticBackground)
        assertBlock(try XCTUnwrap(r["static_background"] as? [String: Any]), bytes: background.pixels, shape: [background.height, background.width])
    }

    func testTheDamagedSettingsFilesStillReadTheAcquisition() throws {
        for file in ["Setting_bad1.txt", "Setting_bad2.txt", "Setting_bad3.txt"] {
            let scan = try NORDIFScan.read(patternFile: path("Pattern.dat"), settingsFile: path(file))
            let r = acquisition(file)
            XCTAssertEqual([scan.rows, scan.columns], ints(r["navigation_shape_yx"]), file)
            XCTAssertEqual([scan.stepUM, scan.stepUM], (r["step_um"] as? [NSNumber])?.map(\.doubleValue), file)
            XCTAssertEqual(sha256(scan.patterns), (r["data"] as? [String: Any])?["sha256"] as? String, file)
            assertDetector(scan.detector, try XCTUnwrap(r["detector"] as? [String: Any]))
        }
        // bad3 has `Step size	1.000` (and a UTF-8 encoding kikuchipy reads as Latin-1): the step follows the file.
        XCTAssertEqual(try NORDIFScan.read(patternFile: path("Pattern.dat"), settingsFile: path("Setting_bad3.txt")).stepUM, 1.0)
    }

    func testAShortPatternFileReadsZeroPaddedAndSaysSo() throws {
        let settings = try NORDIFSettings.read(path: path("Setting.txt"))
        let whole = try Data(contentsOf: URL(fileURLWithPath: path("Pattern.dat")))
        let short = NORDIFScan.read(data: whole.prefix(whole.count - 100), settings: settings, staticBackground: nil, fileName: "Pattern.dat")
        XCTAssertEqual(short.patterns.count, 3 * 3 * 60 * 60)
        XCTAssertEqual(Array(short.patterns.prefix(whole.count - 100)), Array(whole.prefix(whole.count - 100)))
        XCTAssertEqual(Array(short.patterns.suffix(100)), [UInt8](repeating: 0, count: 100))
        XCTAssertEqual(short.note, "Pattern.dat ends 100 bytes before its last pattern (3 x 3 patterns of 60 x 60 px from the settings); the missing pixels read 0.")
        let long = NORDIFScan.read(data: whole + Data([1, 2, 3]), settings: settings, staticBackground: nil, fileName: "Pattern.dat")
        XCTAssertEqual(long.patterns, [UInt8](whole))
        XCTAssertEqual(long.note, "Pattern.dat is 3 bytes longer than its 3 x 3 patterns of 60 x 60 px from the settings; the rest is not read.")
        let empty = scratchFile(named: "Pattern.dat", contents: Data())
        XCTAssertThrowsError(try NORDIFScan.read(patternFile: empty, settingsFile: path("Setting.txt"))) { error in
            XCTAssertEqual(error as? NORDIFScan.Refusal, .empty("Pattern.dat"))
        }
    }

    // MARK: - Calibration patterns

    func testCalibrationPatternsReadWithTheirPositionsScaledAsKikuchipy() throws {
        let c = try NORDIFCalibrationPatterns.read(settingsFile: path("Setting.txt"))
        let r = calibration("Setting.txt")
        XCTAssertEqual(c.positions.map { [$0.y, $0.x] }, pairs(r["indices_yx"]))
        XCTAssertEqual(c.positionsScaled?.map { [$0.row, $0.column] }, pairs(r["indices_scaled_yx"]))
        XCTAssertEqual(c.areaShape.map { [$0.row, $0.column] }, ints(r["area_shape_yx"]))
        XCTAssertEqual(c.areaShapeScaled.map { [$0.row, $0.column] }, ints(r["area_shape_scaled_yx"]))
        XCTAssertEqual([c.roiOrigin.row, c.roiOrigin.column], ints(r["roi_origin_yx"]))
        XCTAssertEqual([c.roiShape.row, c.roiShape.column], ints(r["roi_shape_yx"]))
        XCTAssertEqual(c.roiOriginScaled.map { [$0.row, $0.column] }, ints(r["roi_origin_scaled_yx"]))
        XCTAssertEqual(c.roiShapeScaled.map { [$0.row, $0.column] }, ints(r["roi_shape_scaled_yx"]))
        assertDetector(c.detector, try XCTUnwrap(r["detector"] as? [String: Any]))
        XCTAssertEqual(c.patterns.count, 2)
        assertBlock(try XCTUnwrap(r["data"] as? [String: Any]), bytes: c.patterns.flatMap(\.pixels), shape: [2, 60, 60])
        let patterns = try XCTUnwrap(r["patterns"] as? [[String: String]])
        for (pattern, expected) in zip(c.patterns, patterns) {
            XCTAssertEqual(sha256(pattern.pixels), expected["sha256"], expected["file"] ?? "")
        }
        let background = try XCTUnwrap(c.staticBackground)
        assertBlock(try XCTUnwrap(r["static_background"] as? [String: Any]), bytes: background.pixels, shape: [background.height, background.width])
    }

    /// A `Step size` of 0 or an `[Area] Width` of 0 px makes the scaling factor 0, and a step of NaN or one so small that a position
    /// is more steps than an Int holds gives quotients no Int holds: no scaling then, as without a readable `Width`, and the values
    /// as written stay. Red before: `Int(_:)` of the infinite, NaN or too large quotient trapped.
    func testAZeroStepOrAZeroPixelWidthGivesNoScalingInsteadOfATrap() throws {
        let lines = try NORDIFSettings.read(path: path("Setting.txt")).lines
        XCTAssertEqual(lines[76], "Width\t4.500 (11)\tµm (px)")
        XCTAssertEqual(lines[78], "Step size\t1.500\tµm")
        var noPixels = lines
        noPixels[76] = "Width\t4.500 (0)\tµm (px)"
        var cases: [([String], NORDIFCalibrationPatterns.Point)] = [(noPixels, NORDIFCalibrationPatterns.Point(row: 11, column: 0))]
        for step in ["0", "nan", "1e-300"] {
            var edited = lines
            edited[78] = "Step size\t\(step)\tµm"
            cases.append((edited, NORDIFCalibrationPatterns.Point(row: 11, column: 11)))
        }
        for (edited, roiShape) in cases {
            let settings = try NORDIFSettings.parse(lines: edited, fileName: "Setting.txt")
            let c = NORDIFCalibrationPatterns.geometry(settings: settings, patterns: [], staticBackground: nil)
            XCTAssertNil(c.positionsScaled, edited[78])
            XCTAssertNil(c.areaShapeScaled, edited[78])
            XCTAssertNil(c.roiOriginScaled, edited[78])
            XCTAssertNil(c.roiShapeScaled, edited[78])
            XCTAssertEqual(c.positions, [NORDIFSettings.Position(x: 425, y: 447), NORDIFSettings.Position(x: 294, y: 532)])
            XCTAssertEqual(c.areaShape, NORDIFCalibrationPatterns.Point(row: 1000, column: 1000))
            XCTAssertEqual(c.roiOrigin, NORDIFCalibrationPatterns.Point(row: 223, column: 152))
            XCTAssertEqual(c.roiShape, roiShape)
        }
        // A usable factor scales as before (the reference values: testCalibrationPatternsReadWithTheirPositionsScaledAsKikuchipy).
        let kept = NORDIFCalibrationPatterns.geometry(settings: try NORDIFSettings.parse(lines: lines, fileName: "Setting.txt"), patterns: [],
                                                      staticBackground: nil)
        XCTAssertEqual(kept.positionsScaled?.map { [$0.row, $0.column] }, [[122, 116], [145, 80]])
        XCTAssertEqual(kept.roiShapeScaled, NORDIFCalibrationPatterns.Point(row: 3, column: 3))
    }

    func testTheSettingsFilesWithoutCalibrationLinesAreRefusedWithTheReferenceSentence() throws {
        for file in ["Setting_bad1.txt", "Setting_bad2.txt"] {
            let r = calibration(file)
            XCTAssertEqual(r["reference_error"] as? String, "No calibration patterns found in settings file", file)
            XCTAssertThrowsError(try NORDIFCalibrationPatterns.read(settingsFile: path(file)), file) { error in
                XCTAssertEqual(error as? NORDIFSettings.Refusal, .noCalibrationPatterns, file)
                XCTAssertEqual((error as? NORDIFSettings.Refusal)?.reason, r["refusal"] as? String, file)
            }
        }
    }

    func testTheThirdDamagedFileReadsWithTheCornerItLacksAsZeroAndHalfStepsRoundedToEven() throws {
        // bad3 lacks the `Resolution` and `Top` lines and has a 1 µm step: no area shape, origin row 0, and the ROI's
        // 11 px / (1 µm * 11 px / 4.5 µm) = 4.5 steps round to 4 as NumPy rounds, which kikuchipy's debug log reports.
        let c = try NORDIFCalibrationPatterns.read(settingsFile: path("Setting_bad3.txt"))
        let r = calibration("Setting_bad3.txt")
        XCTAssertNil(c.areaShape)
        XCTAssertNil(c.areaShapeScaled)
        XCTAssertTrue(r["area_shape_yx"] is NSNull)
        XCTAssertNil(c.settings.area.top)
        XCTAssertEqual([c.roiOrigin.row, c.roiOrigin.column], ints(r["roi_origin_yx"]))
        XCTAssertEqual(c.roiOrigin, NORDIFCalibrationPatterns.Point(row: 0, column: 152))
        XCTAssertEqual(c.roiShapeScaled.map { [$0.row, $0.column] }, ints(r["roi_shape_scaled_yx"]))
        XCTAssertEqual(c.roiShapeScaled, NORDIFCalibrationPatterns.Point(row: 4, column: 4))
        XCTAssertEqual(c.positionsScaled?.map { [$0.row, $0.column] }, pairs(r["indices_scaled_yx"]))
        XCTAssertEqual(sha256(c.patterns.flatMap(\.pixels)), (r["data"] as? [String: Any])?["sha256"] as? String)
    }

    func testAMissingCalibrationBitmapIsRefusedByName() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nordif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["Setting.txt", "Calibration (425,447).bmp"] {
            try FileManager.default.copyItem(at: Self.folder.appendingPathComponent(name), to: scratch.appendingPathComponent(name))
        }
        XCTAssertThrowsError(try NORDIFCalibrationPatterns.read(settingsFile: scratch.appendingPathComponent("Setting.txt").path)) { error in
            XCTAssertEqual(error as? NORDIFCalibrationPatterns.Refusal, .missingPattern("Calibration (294,532).bmp"))
            XCTAssertEqual((error as? NORDIFCalibrationPatterns.Refusal)?.reason, "its calibration pattern Calibration (294,532).bmp is not beside it.")
        }
    }

    // MARK: - Bitmaps

    func testTheBitmapDecoderReadsAnEightBitGreyscaleBitmapTopRowFirst() throws {
        // A 3 x 2 bitmap written here: bottom-up rows padded to 4 bytes, identity greyscale palette.
        func bitmap(height: Int32, palette: (Int) -> [UInt8]) -> Data {
            var d = Data([0x42, 0x4D]) + Data(count: 8)
            func le32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
            d += le32(54 + 1024)                                   // pixel offset
            d += le32(40) + le32(3) + le32(height) + [1, 0, 8, 0] + le32(0) + le32(8) + le32(0) + le32(0) + le32(256) + le32(0)
            for i in 0 ..< 256 { d += palette(i) }
            d += [10, 11, 12, 0, 20, 21, 22, 0]                    // rows as stored: first stored row then the second
            return d
        }
        let bottomUp = try NORDIFBitmap.decode(bitmap(height: 2) { [UInt8($0), UInt8($0), UInt8($0), 0] }, fileName: "p.bmp")
        XCTAssertEqual(bottomUp, NORDIFBitmap.Image(width: 3, height: 2, pixels: [20, 21, 22, 10, 11, 12]))
        XCTAssertEqual(bottomUp[0, 2], 22)
        let topDown = try NORDIFBitmap.decode(bitmap(height: -2) { [UInt8($0), UInt8($0), UInt8($0), 0] }, fileName: "p.bmp")
        XCTAssertEqual(topDown.pixels, [10, 11, 12, 20, 21, 22])
        XCTAssertThrowsError(try NORDIFBitmap.decode(bitmap(height: 2) { [UInt8(255 - $0), UInt8($0), UInt8($0), 0] }, fileName: "p.bmp")) { error in
            XCTAssertEqual(error as? NORDIFBitmap.Refusal, .palette("p.bmp"))
        }
        XCTAssertThrowsError(try NORDIFBitmap.decode(Data("not a bitmap".utf8), fileName: "p.bmp")) { error in
            XCTAssertEqual(error as? NORDIFBitmap.Refusal, .notBitmap("p.bmp"))
            XCTAssertEqual((error as? NORDIFBitmap.Refusal)?.reason, "p.bmp is not a Windows bitmap.")
        }
        let real = try NORDIFBitmap.read(path: path("Calibration (425,447).bmp"))
        XCTAssertEqual([real.width, real.height], [60, 60])
        XCTAssertEqual(Array(real.pixels.prefix(3)), [89, 90, 97], "kikuchipy's imread of the same file")
    }
}
