//
//  SEMReaderBundleParityTests.swift
//  The SEM reader bundles under tools/parity/sem/references/m1 (kikuchipy 0.13.1's `kikuchipy.load`, orix 0.15.0's `orix.io.load`,
//  RosettaSciIO 0.15.0's MSA reader) and the background bundles under m2 (kikuchipy's `remove_static_background`, then
//  `remove_dynamic_background`) against the Swift ports, on the files the bundles were emitted from.
//  A pattern file opens through the Patterns room's door (`EBSDOpening.open`); EDAX's hexagonal `.up2`, which the door refuses in
//  words, is read by `EDAXBinaryReader`, which keeps kikuchipy's one-row reading. Navigation and signal shape, dtype, the whole
//  scan's sha256 and the first and last pattern are exact; each pattern's minimum, maximum and mean, the mean pattern, the
//  projection centres, the static background and the crystal map's first Euler angles are held at the bundle's tolerances. The
//  orientation maps go through `ANGReader` and `CTFReader`, the spectrum through FormatoKit's `MSAReader`, the background chain
//  through `PatternProcessing` at the bundle's kwargs. An EMsoft EBSD file has no Swift reader yet: its test holds the refusal.
//  Last, every bundle folder under m1/ and m2/ is named by a comparing test or allowlisted here with a reason.
//  The north-star scan's bundles were emitted from the downloaded nickel_ebsd_large and the duplex steel map from orix-data; the
//  shipped demo file and the committed .ang fixture are the same bytes (checked by sha256), so nothing here skips.
//  Red before: no test compared these 15 bundles, and the coverage test names them. Red after a reader drifts from kikuchipy or
//  orix on these files (a projection-centre convention, a pattern order, a scan shape): the case and the array are named.
//

import CryptoKit
import Foundation
import FormatoCore
import FormatoMSA
import TEMCore
import TEMSession
import XCTest

nonisolated final class SEMReaderBundleParityTests: XCTestCase {

    // MARK: - The cases

    /// Pattern files the app's door opens, each on the committed fixture its bundle names.
    private static let doorCases = ["m1/read-kikuchipy-h5ebsd", "m1/read-bruker-h5ebsd", "m1/read-edax-h5ebsd", "m1/read-oxford-h5oina",
                                    "m1/read-oxford-binary", "m1/read-edax-up1", "m1/read-nordif"]
    /// The north-star scan, read from the shipped demo file.
    private static let northStarCase = "m1/read-nickel-ebsd-large"
    /// EDAX's `.up2` on a hexagonal grid: kikuchipy reads its patterns as one row; the door refuses the grid.
    private static let hexagonalCase = "m1/read-edax-up2"
    private static let angCase = "m1/read-ang-sdss-ferrite-austenite"
    private static let ctfCase = "m1/read-ctf-planted-oxford"
    private static let spectrumCase = "m1/read-eds-msa-tm002"
    private static let backgroundCases = ["m2/background-kikuchipy-h5ebsd", "m2/background-nickel-ebsd-large"]
    /// Every case a test in this file compares with a Swift port.
    private static let comparedHere = doorCases + [northStarCase, hexagonalCase, angCase, ctfCase, spectrumCase] + backgroundCases
    /// The bundles under m1/ and m2/ that no test compares with a Swift port, each with the reason.
    private static let allowlist: [String: String] = [
        "m1/read-emsoft-ebsd": "TEMCore has no EMsoft EBSD pattern reader yet; testTheEMsoftEBSDFileIsRefusedInWords holds the refusal",
    ]

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    // MARK: - Helpers

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The committed copy of a downloaded dataset a bundle was emitted from (`sem-data/...` on the Python side).
    private static func committedCopy(of path: String) -> URL? {
        switch path {
        case "sem-data/nickel_ebsd_large/patterns_v2.h5": return DemoDocuments.Shipped.nickelEBSD.url
        case "sem-data/orix/sdss_ferrite_austenite.ang": return fixtures.appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")
        default: return nil
        }
    }

    /// The file a bundle was emitted from: its committed fixture, or the committed copy of its downloaded dataset, checked to be the
    /// bytes the manifest names.
    private func input(_ ref: SEMParityReference) throws -> URL {
        let name = ref.manifest.caseName
        let expected = try XCTUnwrap(ref.manifest.inputs.first, "\(name) names no input")
        guard !expected.path.hasPrefix("fixtures/") else { return try XCTUnwrap(ref.inputURL(0), "\(name): \(expected.path)") }
        let url = try XCTUnwrap(Self.committedCopy(of: expected.path), "\(name): no committed copy of \(expected.path) (DemoData/ in the bundle?)")
        XCTAssertEqual(Self.sha256(try Data(contentsOf: url)), expected.sha256, "\(name): \(url.lastPathComponent) is not the bundle's input")
        return url
    }

    /// The bundle's array, named with its case, so a failure in a loop over cases says which one.
    private func reference(_ ref: SEMParityReference, _ array: String) throws -> SEMParityReference.LoadedArray {
        let a = try ref.array(array)
        return SEMParityReference.LoadedArray(name: "\(ref.manifest.caseName)/\(array)", shape: a.shape, dtype: a.dtype, values: a.values,
                                              rtol: a.rtol, atol: a.atol)
    }

    /// kikuchipy's navigation shape as the Swift scan holds it: one navigation axis of n patterns is one scan row of n.
    private static func scanShape(_ navigation: [Int]) -> [Int] {
        navigation.count == 1 ? [1, navigation[0]] : navigation
    }

    // MARK: - Pattern readers

    /// A reader's scan against a pattern bundle: the shapes and dtype in `values`, the sha256 of the whole scan (`values.patterns`,
    /// the bytes in map order), the first and last pattern exact, then every pattern's minimum, maximum and mean and the mean
    /// pattern at the bundle's tolerances, read row by row as the pattern browser reads the scan. `row` hands one scan row of
    /// patterns in map order, `pattern` the pattern at (row, column).
    private func comparePatterns(_ ref: SEMParityReference, scanRows: Int, scanColumns: Int, patternRows: Int, patternColumns: Int,
                                 dataType: FormatoDataType, row: (Int) throws -> FormatoArray,
                                 pattern: (Int, Int) throws -> FormatoArray) throws {
        let name = ref.manifest.caseName
        let navigation = try XCTUnwrap(ref.values["navigation_shape_rc"] as? [Int], "\(name): navigation shape")
        let signal = [patternRows, patternColumns]
        XCTAssertEqual([scanRows, scanColumns], Self.scanShape(navigation), "\(name): navigation shape")
        XCTAssertEqual(signal, ref.values["signal_shape_rc"] as? [Int], "\(name): signal shape")
        XCTAssertEqual(dataType.rawValue, ref.values["dtype"] as? String, "\(name): dtype")

        SEMAssertParity(try pattern(0, 0).doubles(), try reference(ref, "first_pattern"), shape: signal)
        if ref.manifest.arrays["last_pattern"] != nil {
            SEMAssertParity(try pattern(scanRows - 1, scanColumns - 1).doubles(), try reference(ref, "last_pattern"), shape: signal)
        }

        let pixels = patternRows * patternColumns
        var minima: [Double] = [], maxima: [Double] = [], means: [Double] = []
        var sum = [Double](repeating: 0, count: pixels)
        var hasher = SHA256()
        for r in 0..<scanRows {
            let patterns = try row(r)
            hasher.update(data: patterns.bytes)
            let values = patterns.doubles()
            XCTAssertEqual(values.count, scanColumns * pixels, "\(name): scan row \(r)")
            for k in 0..<(values.count / pixels) {
                let start = k * pixels
                var low = Double.infinity, high = -Double.infinity, total = 0.0
                for i in 0..<pixels {
                    let v = values[start + i]
                    if v < low { low = v }
                    if v > high { high = v }
                    total += v
                    sum[i] += v
                }
                minima.append(low)
                maxima.append(high)
                means.append(total / Double(pixels))
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let patternsValue = ref.values["patterns"] as? [String: Any]
        XCTAssertEqual(digest, patternsValue?["sha256"] as? String, "\(name): the whole scan's sha256")
        SEMAssertParity(minima, try reference(ref, "pattern_min"), shape: navigation)
        SEMAssertParity(maxima, try reference(ref, "pattern_max"), shape: navigation)
        SEMAssertParity(means, try reference(ref, "pattern_mean"), shape: navigation)
        if ref.manifest.arrays["mean_pattern"] != nil {
            let count = Double(minima.count)
            SEMAssertParity(sum.map { $0 / count }, try reference(ref, "mean_pattern"), shape: signal)
        }
    }

    /// What a dataset carries beside its patterns, where the bundle holds it as an array: the projection centres in the Bruker
    /// convention and the static background (exact, its dtype too), and the crystal map's first Euler angles (rtol 1e-7). A file
    /// without one matches a bundle that states none: no background where kikuchipy reads none, and no crystal map where
    /// kikuchipy's is its placeholder of identity rotations (all Euler angles 0).
    private func compareDataset(_ ref: SEMParityReference, _ dataset: EBSDDataset) throws {
        let name = ref.manifest.caseName
        if ref.manifest.arrays["pc"] != nil {
            let centers = dataset.detector.projectionCenters
            SEMAssertParity(centers.flatMap { [$0.x, $0.y, $0.z] }, try reference(ref, "pc"), shape: [centers.count, 3])
        }
        if let entry = ref.manifest.arrays["static_background"] {
            let background = try XCTUnwrap(dataset.staticBackground, "\(name): no static background read")
            XCTAssertEqual(background.dataType.rawValue, entry.dtype, "\(name): static background dtype")
            SEMAssertParity(background.doubles(), try reference(ref, "static_background"), shape: background.shape)
        } else {
            XCTAssertTrue(ref.values["static_background"] is NSNull, "\(name): the bundle states no static background")
            XCTAssertNil(dataset.staticBackground, "\(name): a static background where kikuchipy reads none")
        }
        if let map = dataset.crystalMap {
            let head = try reference(ref, "xmap_euler_head")
            let n = head.shape.first ?? 0
            SEMAssertParity(map.eulerInData.prefix(n).flatMap { [$0.x, $0.y, $0.z] }, head, shape: [n, 3])
        } else if ref.manifest.arrays["xmap_euler_head"] != nil {
            XCTAssertTrue(try ref.array("xmap_euler_head").values.allSatisfy { $0 == 0 },
                          "\(name): kikuchipy's crystal map holds orientations the reader left out")
        }
    }

    private func compareScan(_ ref: SEMParityReference, dataset: EBSDDataset, reader: EBSDPatternReader) throws {
        try comparePatterns(ref, scanRows: dataset.scanRows, scanColumns: dataset.scanColumns, patternRows: dataset.patternRows,
                            patternColumns: dataset.patternColumns, dataType: dataset.dataType,
                            row: { try reader.row($0) }, pattern: { try reader.pattern(row: $0, column: $1) })
        try compareDataset(ref, dataset)
    }

    /// kikuchipy h5ebsd, Bruker and EDAX h5ebsd, Oxford H5OINA and `.ebsp`, EDAX `.up1` and NORDIF, each through the door.
    func testThePatternFilesReadAsKikuchipyReadsThem() throws {
        for name in Self.doorCases {
            let ref = try SEMParityReference.load(name)
            let (dataset, reader) = try EBSDOpening.open(url: try input(ref))
            try compareScan(ref, dataset: dataset, reader: reader)
        }
    }

    /// The 55 x 75 north-star scan, the shipped demo file.
    func testTheNorthStarScanReadsAsKikuchipyReadsIt() throws {
        let ref = try SEMParityReference.load(Self.northStarCase)
        let (dataset, reader) = try EBSDOpening.open(url: try input(ref))
        try compareScan(ref, dataset: dataset, reader: reader)
    }

    /// The hexagonal `.up2`: the reader hands kikuchipy's one row of ten uint16 patterns with kikuchipy's warning; the door and the
    /// routing refuse the grid in one sentence (D-SEM-20).
    func testTheHexagonalUp2ReadsAsKikuchipyAndTheDoorRefusesIt() throws {
        let ref = try SEMParityReference.load(Self.hexagonalCase)
        let url = try input(ref)
        let file = try EDAXBinaryReader.read(url: url)
        XCTAssertTrue(file.isHexagonal)
        XCTAssertEqual(file.note, EDAXBinaryReader.hexagonalNote, "kikuchipy's warning")
        try comparePatterns(ref, scanRows: file.scanRows, scanColumns: file.scanColumns, patternRows: file.patternRows,
                            patternColumns: file.patternColumns, dataType: file.dataType,
                            row: { _ in try EDAXBinaryReader.allPatterns(file) },
                            pattern: { try EDAXBinaryReader.pattern(file, row: $0, column: $1) })
        let sentence = "\(url.lastPathComponent) was acquired on a hexagonal grid; only square-grid EBSD maps are read."
        XCTAssertThrowsError(try EBSDOpening.open(url: url)) { error in
            XCTAssertEqual((error as? EDAXReadError)?.text, sentence)
        }
        XCTAssertEqual(FileRouting.inventory(path: url.path), FileInventory(refusal: sentence))
    }

    /// EMsoft's EBSD output (`EMData/EBSD/EBSDPatterns`) has no Swift reader: the routing refuses it as an HDF5 file it does not
    /// open, the door as a file that is not h5ebsd. The bundle stays the reference a port will be held to.
    func testTheEMsoftEBSDFileIsRefusedInWords() throws {
        let ref = try SEMParityReference.load("m1/read-emsoft-ebsd")
        let url = try input(ref)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let routing = "\(url.lastPathComponent) is a 4D dataset or an HDF5 file that is neither a Velox file nor an EBSD scan: "
            + "macEM opens images, spectra and EBSD patterns; open it in mac4DSTEM."
        XCTAssertEqual(FileRouting.inventory(path: url.path), FileInventory(refusal: routing))
        XCTAssertThrowsError(try EBSDOpening.open(url: url)) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text,
                           "\(url.lastPathComponent): it is not an EBSD file (it does not name the software that wrote it).")
        }
        XCTAssertEqual(ref.values["navigation_shape_rc"] as? [Int], [1])
        XCTAssertEqual(ref.values["signal_shape_rc"] as? [Int], [480, 640])
    }

    // MARK: - Orientation maps

    /// A map reader's `CrystalMap` against an orix bundle: size, shape, steps, scan unit and property names exact, every phase's
    /// name, point group, space group and colour, the phase ids and their counts exact, and the first 16 points' Euler angles,
    /// x, y and properties at rtol 1e-7.
    private func compareMap(_ ref: SEMParityReference, _ map: CrystalMap) throws {
        let name = ref.manifest.caseName
        XCTAssertEqual(map.size, ref.values["size"] as? Int, "\(name): size")
        XCTAssertEqual(map.shape, ref.values["shape"] as? [Int], "\(name): shape")
        XCTAssertEqual(map.dx, ref.values["dx"] as? Double, "\(name): dx")
        XCTAssertEqual(map.dy, ref.values["dy"] as? Double, "\(name): dy")
        XCTAssertEqual(map.scanUnit, ref.values["scan_unit"] as? String, "\(name): scan unit")
        let properties = try XCTUnwrap(ref.values["properties"] as? [String], "\(name): properties")
        XCTAssertEqual(map.propertyNames, properties, "\(name): property names")

        let phases = try XCTUnwrap(ref.values["phases"] as? [String: [String: Any]], "\(name): phases")
        XCTAssertEqual(Set(map.phases.ids.map { String($0) }), Set(phases.keys), "\(name): phase ids")
        for (id, phase) in map.phases.entries {
            let expected = phases[String(id)]
            XCTAssertEqual(phase.name, expected?["name"] as? String, "\(name): phase \(id) name")
            XCTAssertEqual(phase.pointGroupName, expected?["point_group"] as? String, "\(name): phase \(id) point group")
            XCTAssertEqual(phase.spaceGroup, expected?["space_group"] as? Int, "\(name): phase \(id) space group")
            XCTAssertEqual(phase.color, expected?["color"] as? String, "\(name): phase \(id) colour")
        }
        var counts: [String: Int] = [:]
        for id in map.phaseIDs { counts[String(id), default: 0] += 1 }
        XCTAssertEqual(counts, ref.values["phase_counts"] as? [String: Int], "\(name): points per phase")
        SEMAssertParity(map.phaseIDs.map { Double($0) }, try reference(ref, "phase_id"))

        let head = try reference(ref, "euler_head")
        let n = head.shape.first ?? 0
        SEMAssertParity(map.eulerInData.prefix(n).flatMap { [$0.x, $0.y, $0.z] }, head, shape: [n, 3])
        SEMAssertParity(Array((map.x ?? []).prefix(n)), try reference(ref, "x_head"))
        SEMAssertParity(Array((map.y ?? []).prefix(n)), try reference(ref, "y_head"))
        for property in properties {
            SEMAssertParity(Array((map.property(property) ?? []).prefix(n)), try reference(ref, "prop_\(property)_head"))
        }
    }

    /// orix-data's two-phase EDAX `.ang` (the committed fixture, the bundle's downloaded input byte for byte) and the planted
    /// Oxford `.ctf` with its not-indexed point.
    func testTheOrientationMapsReadAsOrixReadsThem() throws {
        let ang = try SEMParityReference.load(Self.angCase)
        try compareMap(ang, try ANGReader.read(url: try input(ang)).map)
        let ctf = try SEMParityReference.load(Self.ctfCase)
        try compareMap(ctf, try CTFReader.read(path: try input(ctf).path).map)
    }

    // MARK: - The EDS spectrum

    /// The bundle's axes decoded by `JSONDecoder`, which parses each float to the nearest Double (`SEMEDSMapReaderTests`).
    nonisolated struct SpectrumManifest: Decodable {
        nonisolated struct Axis: Decodable {
            let name: String
            let size: Int
            let scale: Double
            let offset: Double
            let units: String
        }

        nonisolated struct Values: Decodable {
            let axes: [Axis]
        }

        let values: Values
    }

    /// exspy's TM002 spectrum as `.msa`: the routing sends it to the EDS room, and FormatoKit's `MSAReader` (which `FileRouting`
    /// loads an `.msa` with) gives RosettaSciIO's counts, total, dtype, signal type and energy axis exactly.
    func testTheEDSSpectrumReadsAsRosettaSciIOReadsIt() throws {
        let ref = try SEMParityReference.load(Self.spectrumCase)
        let url = try input(ref)
        XCTAssertEqual(FileRouting.inventory(path: url.path), FileInventory(singleSpectrum: true))
        let signal = try MSAReader.read(path: url.path).signal
        XCTAssertEqual(signal.data.dataType.rawValue, ref.values["dtype"] as? String, "dtype")
        XCTAssertEqual(signal.signalType, ref.values["signal_type"] as? String, "signal type")
        let counts = signal.data.doubles()
        SEMAssertParity(counts, try reference(ref, "counts"), shape: signal.data.shape)
        SEMAssertParity(counts.reduce(0, +), ref, scalar: "total_counts")
        let manifest = try Data(contentsOf: ref.directory.appendingPathComponent("manifest.json"))
        let axes = try JSONDecoder().decode(SpectrumManifest.self, from: manifest).values.axes
        XCTAssertEqual(signal.axes.count, axes.count, "one energy axis")
        for (ours, theirs) in zip(signal.axes, axes) {
            XCTAssertEqual(ours.name, theirs.name, "axis name")
            XCTAssertEqual(ours.size, theirs.size, "axis size")
            XCTAssertEqual(ours.scale, theirs.scale, "axis scale")
            XCTAssertEqual(ours.offset, theirs.offset, "axis offset")
            XCTAssertEqual(ours.units, theirs.units, "axis units")
        }
    }

    // MARK: - Background removal (m2)

    /// kikuchipy's static background removal with the file's background, then the dynamic one, at the bundle's kwargs, on pattern
    /// (0, 0) and the scan's 3 x 3 corner (the whole nine-pattern fixture), each within the bundle's one grey level and, as
    /// docs/parity.md bounds a cast pattern, on at most 1 % of the pixels. The whole north-star scan's sha256 in the bundle is the
    /// Python side's drift check: kikuchipy truncates float32 values, so the port is held to the grey-level bound, not the bytes.
    func testTheBackgroundBundlesMatchAtTheirKwargs() throws {
        for name in Self.backgroundCases {
            let ref = try SEMParityReference.load(name)
            let (dataset, reader) = try EBSDOpening.open(url: try input(ref))
            let staticKwargs = try XCTUnwrap(ref.values["static_kwargs"] as? [String: Any], "\(name): static kwargs")
            let dynamicKwargs = try XCTUnwrap(ref.values["dynamic_kwargs"] as? [String: Any], "\(name): dynamic kwargs")
            XCTAssertEqual(staticKwargs["static_bg"] as? String, "from file", "\(name): the file's own static background")
            let staticOperation = try XCTUnwrap(PatternProcessing.Operation(rawValue: staticKwargs["operation"] as? String ?? ""), name)
            let scaleBackground = try XCTUnwrap(staticKwargs["scale_bg"] as? Bool, "\(name): scale_bg")
            let dynamicOperation = try XCTUnwrap(PatternProcessing.Operation(rawValue: dynamicKwargs["operation"] as? String ?? ""), name)
            let domain = try XCTUnwrap(PatternProcessing.FilterDomain(rawValue: dynamicKwargs["filter_domain"] as? String ?? ""), name)
            // `std` null is kikuchipy's default, the pattern width / 8, as `PatternProcessing` takes nil.
            let std = dynamicKwargs["std"] as? Double
            let truncate = try XCTUnwrap(dynamicKwargs["truncate"] as? Double, "\(name): truncate")

            XCTAssertEqual(dataset.dataType, .uint8, "\(name): 8-bit patterns")
            let background = [UInt8](try XCTUnwrap(dataset.staticBackground, "\(name): the file carries its static background").bytes)
            let rows = dataset.patternRows, columns = dataset.patternColumns
            func corrected(_ row: Int, _ column: Int) throws -> (afterStatic: [Double], afterDynamic: [Double]) {
                let raw = [UInt8](try reader.pattern(row: row, column: column).bytes)
                let afterStatic = try PatternProcessing.removeStaticBackground(raw, background: background, operation: staticOperation,
                                                                               scaleBackground: scaleBackground)
                let afterDynamic = try PatternProcessing.removeDynamicBackground(afterStatic, rows: rows, columns: columns,
                                                                                 operation: dynamicOperation, domain: domain, std: std,
                                                                                 truncate: truncate)
                return (afterStatic.map { Double($0) }, afterDynamic.map { Double($0) })
            }
            var staticCorner: [Double] = [], dynamicCorner: [Double] = []
            for r in 0..<3 {
                for c in 0..<3 {
                    let out = try corrected(r, c)
                    staticCorner += out.afterStatic
                    dynamicCorner += out.afterDynamic
                }
            }
            // Pattern (0, 0) is the corner's first.
            let size = rows * columns
            let first = (afterStatic: Array(staticCorner.prefix(size)), afterDynamic: Array(dynamicCorner.prefix(size)))
            // The nine-pattern fixture's bundle holds its whole scan; the north-star scan's its 3 x 3 corner.
            let whole = ref.manifest.arrays["after_static_corner"] == nil
            if whole { XCTAssertEqual([dataset.scanRows, dataset.scanColumns], [3, 3], "\(name): the whole scan is the corner") }
            let suffix = whole ? "" : "_corner"
            let checks: [([Double], String, [Int])] = [
                (first.afterStatic, "after_static_first", [rows, columns]),
                (first.afterDynamic, "after_static_and_dynamic_first", [rows, columns]),
                (staticCorner, "after_static" + suffix, [3, 3, rows, columns]),
                (dynamicCorner, "after_static_and_dynamic" + suffix, [3, 3, rows, columns]),
            ]
            for (ours, array, shape) in checks {
                let expected = try reference(ref, array)
                SEMAssertParity(ours, expected, shape: shape)
                // docs/parity.md bounds each pattern: at most 1 % of its pixels one grey level off.
                let count = min(ours.count, expected.values.count)
                for start in stride(from: 0, to: count, by: size) {
                    let end = min(start + size, count)
                    let off = zip(ours[start..<end], expected.values[start..<end]).filter { $0 != $1 }.count
                    XCTAssertLessThanOrEqual(Double(off), 0.01 * Double(end - start),
                                             "\(name)/\(array), pattern \(start / size): \(off) of \(end - start) pixels one grey level off")
                }
            }
        }
    }

    // MARK: - Coverage

    /// Every bundle folder under m1/ and m2/ is compared with a Swift port by a test, or allowlisted here with the reason. A folder
    /// counts as compared when this file's tables name it, or when another test source spells it in a string literal; an
    /// interpolated literal such as "m2/fft-filter-\(bundle)" counts for every folder its fixed text matches. SEMParityHarnessTests
    /// is not a comparing test (it reads one bundle's values to check the harness). Red under: a bundle folder nothing compares, an
    /// allowlisted one a test now compares, an allowlist entry without a folder or a reason.
    func testEveryM1AndM2BundleIsComparedOrAllowlisted() throws {
        let folders = try Self.bundleFolders(in: "m1") + Self.bundleFolders(in: "m2")
        XCTAssertGreaterThanOrEqual(folders.count, 40, "the m1 and m2 bundles are on disk")
        let spelled = try Self.casePiecesInOtherTests()
        var uncompared: [String] = []
        for name in folders {
            let compared = Self.comparedHere.contains(name) || spelled.contains { Self.pieces($0, spell: name) }
            if let reason = Self.allowlist[name] {
                XCTAssertFalse(compared, "\(name) is compared now: take it off the allowlist")
                XCTAssertFalse(reason.isEmpty, "\(name): the allowlist says why")
            } else if !compared {
                uncompared.append(name)
            }
        }
        XCTAssertEqual(uncompared, [], "bundles that no test compares with a Swift port and the allowlist does not name")
        for name in Self.allowlist.keys.sorted() { XCTAssertTrue(folders.contains(name), "allowlisted \(name) has no folder") }
        for name in Self.comparedHere { XCTAssertTrue(folders.contains(name), "\(name) is compared here but has no folder") }
    }

    /// The literal scan on sources written for it: plain and interpolated names, a name in a list, a literal that is not a case.
    func testTheCoverageScanReadsLiteralsAsTheirPieces() {
        let source = #"load("m1/read-nordif"); let x = "m2/clahe-\(bundle)"; let y = ["m1/a", "m2/b-\(f(x))-c"]; let z = "m3/x""#
        let found = Self.casePieces(in: source)
        XCTAssertEqual(found, [["m1/read-nordif"], ["m2/clahe-", ""], ["m1/a"], ["m2/b-", "-c"]])
        XCTAssertTrue(Self.pieces(["m2/clahe-", ""], spell: "m2/clahe-nickel-ebsd-large"))
        XCTAssertFalse(Self.pieces(["m2/clahe-", ""], spell: "m2/clahe-"), "an interpolation stands for at least one character")
        XCTAssertTrue(Self.pieces(["m2/b-", "-c"], spell: "m2/b-x-c"))
        XCTAssertFalse(Self.pieces(["m2/b-", "-c"], spell: "m2/b-x-d"))
        XCTAssertTrue(Self.pieces(["m1/a"], spell: "m1/a"))
        XCTAssertFalse(Self.pieces(["m1/a"], spell: "m1/ab"))
    }

    /// The case folders under references/<milestone>, as `m1/read-nordif`, listed from disk.
    private static func bundleFolders(in milestone: String) throws -> [String] {
        let root = SEMParityReference.referencesRoot.appendingPathComponent(milestone, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { milestone + "/" + $0.lastPathComponent }
            .sorted()
    }

    /// The m1/ and m2/ case names spelled in the other test sources next to this file.
    private static func casePiecesInOtherTests() throws -> [[String]] {
        let here = URL(fileURLWithPath: #filePath)
        let skipped: Set<String> = [here.lastPathComponent, "SEMParityHarnessTests.swift"]
        let files = try FileManager.default.contentsOfDirectory(at: here.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        var found: [[String]] = []
        for url in files where url.pathExtension == "swift" && !skipped.contains(url.lastPathComponent) {
            found += casePieces(in: try String(contentsOf: url, encoding: .utf8))
        }
        return found
    }

    /// Every one-line string literal in `source` that starts with "m1/" or "m2/", as its fixed pieces: the text before, between and
    /// after its interpolations ("m2/fft-filter-\(bundle)" is ["m2/fft-filter-", ""]).
    static func casePieces(in source: String) -> [[String]] {
        let bytes = Array(source.utf8)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), newline = UInt8(ascii: "\n")
        let leftParen = UInt8(ascii: "("), rightParen = UInt8(ascii: ")")
        let letterM = UInt8(ascii: "m"), one = UInt8(ascii: "1"), two = UInt8(ascii: "2"), slash = UInt8(ascii: "/")
        var found: [[String]] = []
        var i = 0
        while i + 3 < bytes.count {
            let digit = bytes[i + 2]
            let opensCase = bytes[i] == quote && bytes[i + 1] == letterM && bytes[i + 3] == slash
            guard opensCase, digit == one || digit == two else {
                i += 1
                continue
            }
            var pieces: [String] = [], piece: [UInt8] = []
            var j = i + 1, closed = false
            while j < bytes.count {
                let c = bytes[j]
                if c == quote {
                    closed = true
                    break
                }
                if c == newline { break }
                if c == backslash, j + 1 < bytes.count, bytes[j + 1] == leftParen {
                    pieces.append(String(decoding: piece, as: UTF8.self))
                    piece = []
                    var depth = 1
                    j += 2
                    while j < bytes.count, depth > 0 {
                        if bytes[j] == leftParen { depth += 1 } else if bytes[j] == rightParen { depth -= 1 }
                        j += 1
                    }
                    continue
                }
                piece.append(c)
                j += 1
            }
            if closed {
                pieces.append(String(decoding: piece, as: UTF8.self))
                found.append(pieces)
            }
            i = j + 1
        }
        return found
    }

    /// Whether a literal's `pieces` spell `name`: equal to a literal without interpolation; otherwise the pieces in order, each
    /// interpolation standing for at least one character.
    static func pieces(_ pieces: [String], spell name: String) -> Bool {
        guard pieces.count > 1 else { return pieces.first == name }
        let pattern = "^" + pieces.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: ".+") + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}
