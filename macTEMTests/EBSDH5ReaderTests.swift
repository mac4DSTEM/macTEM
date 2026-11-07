//
//  EBSDH5ReaderTests.swift
//  The h5ebsd readers against kikuchipy 0.13.1: every fixture in Fixtures/ebsd-*.h5 (and .h5oina) reads with the values of
//  Fixtures/ebsd-h5ebsd.truth.json (tools/parity/sem-readers/make_h5ebsd_fixtures.py): shapes, steps, the detector with its
//  projection centres in the Bruker convention, the static background, the first and last pattern and the sha256 of the whole
//  pattern array in map order, the SEM header, the crystal map of the kikuchipy file; the fixtures' own sha256 so a regenerated
//  file is caught. Header fields and patterns are exact; angles derived in floating point (Oxford's radians to degrees) within 1e-12.
//

import CryptoKit
import FormatoCore
import TEMCore
import XCTest

nonisolated final class EBSDH5ReaderTests: XCTestCase {

    nonisolated struct Truth: Decodable {
        nonisolated struct Background: Decodable {
            let dtype: String
            let shape: [Int]
            let values: [Int]
        }
        let fileSHA256: String
        let manufacturer: String
        let version: String
        let navShape: [Int]
        let sigShape: [Int]
        let dtype: String
        let step: [String]
        let scanUnit: String
        let pxSize: String
        let binning: Int
        let tilt: String
        let azimuthal: String
        let twist: String
        let sampleTilt: String
        let pcShape: [Int]
        let pcBruker: [String]
        let staticBackground: Background?
        let patternsSHA256: String
        let firstPattern: [Int]
        let lastPattern: [Int]
        let sem: [String: String]
        let xmapPhaseNames: [String]
        let xmapHasRotations: Bool
        let xmapEulerFirst: [String]?
        let xmapEulerLast: [String]?
        enum CodingKeys: String, CodingKey {
            case manufacturer, version, dtype, step, binning, tilt, azimuthal, twist, sem
            case fileSHA256 = "file_sha256"
            case navShape = "nav_shape"
            case sigShape = "sig_shape"
            case scanUnit = "scan_unit"
            case pxSize = "px_size"
            case sampleTilt = "sample_tilt"
            case pcShape = "pc_shape"
            case pcBruker = "pc_bruker"
            case staticBackground = "static_background"
            case patternsSHA256 = "patterns_sha256"
            case firstPattern = "first_pattern"
            case lastPattern = "last_pattern"
            case xmapPhaseNames = "xmap_phase_names"
            case xmapHasRotations = "xmap_has_rotations"
            case xmapEulerFirst = "xmap_euler_first"
            case xmapEulerLast = "xmap_euler_last"
        }
    }

    nonisolated struct TruthFile: Decodable {
        let kikuchipy: String
        let files: [String: Truth]
    }

    static let fixtures: [(name: String, ext: String, format: EBSDFileFormat)] = [
        ("ebsd-kikuchipy-h5ebsd", "h5", .kikuchipyH5EBSD),
        ("ebsd-edax-h5ebsd", "h5", .edaxH5EBSD),
        ("ebsd-bruker-h5ebsd", "h5", .brukerH5EBSD),
        ("ebsd-bruker-roi-h5ebsd", "h5", .brukerH5EBSD),
        ("ebsd-oxford", "h5oina", .oxfordH5OINA),
        ("ebsd-oxford-6", "h5oina", .oxfordH5OINA),
    ]

    private func url(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: EBSDH5ReaderTests.self).url(forResource: name, withExtension: ext), "\(name).\(ext) is not in the test bundle")
    }

    private func truth() throws -> TruthFile {
        try JSONDecoder().decode(TruthFile.self, from: Data(contentsOf: url("ebsd-h5ebsd.truth", "json")))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func double(_ text: String, _ what: String) throws -> Double {
        try XCTUnwrap(Double(text), "\(what): '\(text)' is not a number")
    }

    private func assertClose(_ value: Double, _ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try double(text, what)
        let tolerance = max(1e-12 * abs(expected), 1e-12)
        XCTAssertEqual(value, expected, accuracy: tolerance, what, file: file, line: line)
    }

    func testTruthIsKikuchipy0131() throws {
        XCTAssertEqual(try truth().kikuchipy, "0.13.1")
        XCTAssertEqual(try truth().files.count, Self.fixtures.count)
    }

    func testEveryFixtureReadsAsKikuchipyReadsIt() throws {
        let truths = try truth().files
        for fixture in Self.fixtures {
            let fileName = "\(fixture.name).\(fixture.ext)"
            let expected = try XCTUnwrap(truths[fileName], "no truth for \(fileName)")
            let url = try url(fixture.name, fixture.ext)
            XCTAssertEqual(sha256(try Data(contentsOf: url)), expected.fileSHA256, "\(fileName): the fixture is not the one the truth was written from")
            XCTAssertEqual(EBSDH5Reader.sniff(url: url), fixture.format, fileName)
            let dataset = try EBSDH5Reader.read(url: url)
            XCTAssertEqual(dataset.format, fixture.format, fileName)
            XCTAssertEqual(dataset.manufacturer, expected.manufacturer, fileName)
            XCTAssertEqual(dataset.version, expected.version, fileName)
            XCTAssertEqual([dataset.scanRows, dataset.scanColumns], expected.navShape, "\(fileName) scan shape")
            XCTAssertEqual([dataset.patternRows, dataset.patternColumns], expected.sigShape, "\(fileName) pattern shape")
            XCTAssertEqual(dataset.dataType.rawValue, expected.dtype, "\(fileName) dtype")
            try assertClose(dataset.stepY, expected.step[0], "\(fileName) step y")
            try assertClose(dataset.stepX, expected.step[1], "\(fileName) step x")
            XCTAssertEqual(dataset.scanUnit, expected.scanUnit, fileName)
            let detector = dataset.detector
            XCTAssertEqual([detector.rows, detector.columns], expected.sigShape, "\(fileName) detector shape")
            try assertClose(detector.pixelSize, expected.pxSize, "\(fileName) px_size")
            XCTAssertEqual(detector.binning, expected.binning, "\(fileName) binning")
            try assertClose(detector.tilt, expected.tilt, "\(fileName) tilt")
            try assertClose(detector.azimuthal, expected.azimuthal, "\(fileName) azimuthal")
            try assertClose(detector.twist, expected.twist, "\(fileName) twist")
            try assertClose(detector.sampleTilt, expected.sampleTilt, "\(fileName) sample tilt")
            let pcCount = expected.pcShape.dropLast().reduce(1, *)
            XCTAssertEqual(detector.projectionCenters.count, pcCount, "\(fileName) PC count")
            XCTAssertEqual(expected.pcBruker.count, pcCount * 3, "\(fileName) truth PC length")
            for (i, pc) in detector.projectionCenters.enumerated() where 3 * i + 2 < expected.pcBruker.count {
                try assertClose(pc.x, expected.pcBruker[3 * i], "\(fileName) PC \(i) x")
                try assertClose(pc.y, expected.pcBruker[3 * i + 1], "\(fileName) PC \(i) y")
                try assertClose(pc.z, expected.pcBruker[3 * i + 2], "\(fileName) PC \(i) z")
            }
            if let background = expected.staticBackground {
                let read = try XCTUnwrap(dataset.staticBackground, "\(fileName): no static background read")
                XCTAssertEqual(read.dataType.rawValue, background.dtype, "\(fileName) background dtype")
                XCTAssertEqual(read.shape, background.shape, "\(fileName) background shape")
                XCTAssertEqual(read.doubles().map { Int($0) }, background.values, "\(fileName) background values")
            } else {
                XCTAssertNil(dataset.staticBackground, "\(fileName): a static background where kikuchipy reads none")
            }
            let reader = try EBSDPatternReader(dataset)
            let first = try reader.pattern(row: 0, column: 0)
            XCTAssertEqual(first.shape, expected.sigShape, "\(fileName) first pattern shape")
            XCTAssertEqual(first.doubles().map { Int($0) }, expected.firstPattern, "\(fileName) first pattern")
            let last = try reader.pattern(row: dataset.scanRows - 1, column: dataset.scanColumns - 1)
            XCTAssertEqual(last.doubles().map { Int($0) }, expected.lastPattern, "\(fileName) last pattern")
            let all = try dataset.allPatterns()
            XCTAssertEqual(all.shape, expected.navShape + expected.sigShape, "\(fileName) all patterns shape")
            XCTAssertEqual(sha256(all.bytes), expected.patternsSHA256, "\(fileName) all patterns")
            if let beam = expected.sem["beam_energy"] { try assertClose(try XCTUnwrap(dataset.sem.beamEnergyKeV), beam, "\(fileName) beam energy") }
            else { XCTAssertNil(dataset.sem.beamEnergyKeV, fileName) }
            if let mag = expected.sem["magnification"] { try assertClose(try XCTUnwrap(dataset.sem.magnification), mag, "\(fileName) magnification") }
            else { XCTAssertNil(dataset.sem.magnification, fileName) }
            if let wd = expected.sem["working_distance"] { try assertClose(try XCTUnwrap(dataset.sem.workingDistanceMM), wd, "\(fileName) working distance") }
            else { XCTAssertNil(dataset.sem.workingDistanceMM, fileName) }
            XCTAssertEqual(dataset.sem.microscope, expected.sem["microscope"], "\(fileName) microscope")
            if expected.xmapHasRotations {
                let map = try XCTUnwrap(dataset.crystalMap, "\(fileName): no crystal map read")
                XCTAssertEqual(map.phases.names, expected.xmapPhaseNames, "\(fileName) phases")
                XCTAssertEqual(map.euler.count, dataset.patternCount, "\(fileName) one orientation per point")
                let firstEuler = try XCTUnwrap(expected.xmapEulerFirst)
                let lastEuler = try XCTUnwrap(expected.xmapEulerLast)
                for k in 0..<3 {
                    try assertClose(map.euler[0][k], firstEuler[k], "\(fileName) first Euler \(k)")
                    try assertClose(map.euler[map.euler.count - 1][k], lastEuler[k], "\(fileName) last Euler \(k)")
                }
            } else {
                XCTAssertNil(dataset.crystalMap, "\(fileName): kikuchipy reads an empty crystal map here")
            }
        }
    }

    func testKikuchipyFileHoldsTwoScansAndTheSecondReadsByName() throws {
        let url = try url("ebsd-kikuchipy-h5ebsd", "h5")
        let first = try EBSDH5Reader.read(url: url)
        XCTAssertEqual(first.scanGroups, ["Scan 1", "Scan 2"])
        XCTAssertEqual(first.scanGroup, "Scan 1")
        let second = try EBSDH5Reader.read(url: url, scanGroup: "Scan 2")
        XCTAssertEqual(second.scanGroup, "Scan 2")
        XCTAssertEqual(second.patterns.datasetPath, "/Scan 2/EBSD/Data/patterns")
        XCTAssertEqual([second.scanRows, second.scanColumns], [3, 3])
        XCTAssertThrowsError(try EBSDH5Reader.read(url: url, scanGroup: "Scan 3")) { error in
            XCTAssertTrue((error as? EBSDReadError)?.text.contains("Scan 'Scan 3' is not among the scans") == true, "\(error)")
        }
    }

    func testBrukerRegionOfInterestMapsFilePatternsToTheirPositions() throws {
        // kikuchipy's dummy: IY = [1, 0, 0, 1, 2, 2], IX = [1, 1, 2, 2, 1, 2] -> a 3 x 2 region; position (0, 0) is file entry 1, (2, 1) is entry 5.
        let roi = try XCTUnwrap(EBSDH5Reader.rectangularROI(rows: [1, 0, 0, 1, 2, 2], columns: [1, 1, 2, 2, 1, 2]))
        XCTAssertEqual(roi.rows, 3)
        XCTAssertEqual(roi.columns, 2)
        let expectedOrder: [Int?] = [1, 2, 0, 3, 4, 5]
        XCTAssertEqual(roi.fileIndexByPosition, expectedOrder)
        XCTAssertNil(EBSDH5Reader.rectangularROI(rows: [0, 0, 1], columns: [0, 1, 0]), "an L shape is not rectangular")
        XCTAssertNil(EBSDH5Reader.rectangularROI(rows: [0, 2], columns: [0, 0]), "a gap is not rectangular")
        let dataset = try EBSDH5Reader.read(url: url("ebsd-bruker-roi-h5ebsd", "h5"))
        XCTAssertEqual(dataset.patterns.fileIndexByPosition, expectedOrder)
        XCTAssertEqual(dataset.patterns.fileCount, 6)
        XCTAssertEqual(dataset.detector.pixelSize, 23700.0 / 60.0, accuracy: 1e-12, "DetectorFullHeightMicrons / UnClippedPatternHeight")
    }

    func testProjectionCenterConventionsRoundTrip() {
        let detector = EBSDDetectorGeometry(rows: 60, columns: 80, pixelSize: 70, binning: 8, projectionCenters: [])
        let pc = SIMD3(0.42, 0.21, 0.5)
        for convention in [EBSDDetectorGeometry.Convention.bruker, .tsl, .oxford, .emsoft4, .emsoft5] {
            let there = detector.center(pc, in: convention)
            let back = detector.brukerCenter(there, from: convention)
            XCTAssertEqual(back.x, pc.x, accuracy: 1e-12, "\(convention)")
            XCTAssertEqual(back.y, pc.y, accuracy: 1e-12, "\(convention)")
            XCTAssertEqual(back.z, pc.z, accuracy: 1e-12, "\(convention)")
        }
        // kikuchipy's formulas, by hand: TSL flips y and scales z by min(rows, columns) / rows; Oxford by the aspect ratio.
        let tsl = detector.brukerCenter(SIMD3(0.4, 0.3, 0.6), from: .tsl)
        XCTAssertEqual(tsl.y, 0.7, accuracy: 1e-12)
        XCTAssertEqual(tsl.z, 0.6, accuracy: 1e-12)
        let oxford = detector.brukerCenter(SIMD3(0.4, 0.3, 0.6), from: .oxford)
        XCTAssertEqual(oxford.y, 1 - 0.3 * (80.0 / 60.0), accuracy: 1e-12)
        XCTAssertEqual(oxford.z, 0.6 * (80.0 / 60.0), accuracy: 1e-12)
    }

    func testOxfordBinningFollowsTheCameraMode() throws {
        let seven = try EBSDH5Reader.read(url: url("ebsd-oxford", "h5oina"))
        let six = try EBSDH5Reader.read(url: url("ebsd-oxford-6", "h5oina"))
        XCTAssertEqual(seven.version, "7.0")
        XCTAssertEqual(six.version, "6.0")
        XCTAssertEqual(seven.detector.binning, 17, "round(1024 / 60)")
        XCTAssertEqual(six.detector.binning, 17)
        XCTAssertEqual(seven.patterns.datasetPath, "/1/EBSD/Data/Processed Patterns")
        XCTAssertEqual(seven.detector.sampleTilt, 69.9, accuracy: 1e-4, "Tilt Angle, float32 radians to degrees")
        XCTAssertEqual(seven.detector.tilt, 1.5, accuracy: 1e-4, "Detector Orientation Euler[1] - 90")
    }

    func testAFileThatIsNotH5EBSDIsRefusedInWords() throws {
        let velox = try url("velox-haadf-last", "emd")
        XCTAssertNil(EBSDH5Reader.sniff(url: velox))
        XCTAssertThrowsError(try EBSDH5Reader.read(url: velox)) { error in
            let text = (error as? EBSDReadError)?.text ?? ""
            XCTAssertTrue(text.contains("not an h5ebsd file"), text)
        }
        XCTAssertNil(EBSDH5Reader.format(ofManufacturer: "Thermo"))
        XCTAssertEqual(EBSDH5Reader.format(ofManufacturer: "Oxford Instruments"), .oxfordH5OINA)
    }

    func testPatternOutsideTheScanIsRefused() throws {
        let dataset = try EBSDH5Reader.read(url: url("ebsd-edax-h5ebsd", "h5"))
        let reader = try EBSDPatternReader(dataset)
        XCTAssertThrowsError(try reader.pattern(row: 3, column: 0))
        XCTAssertThrowsError(try reader.pattern(row: 0, column: -1))
        XCTAssertEqual(try reader.pattern(row: 2, column: 2).count, 3600)
    }
}
