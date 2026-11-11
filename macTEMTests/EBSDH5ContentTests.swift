//
//  EBSDH5ContentTests.swift
//  #514: every EBSD HDF5 file goes to the room that opens what it holds, or is refused in a sentence that names it and says what it
//  holds, in words a user reads (no HDF5 path, no quoted dataset name).
//  - The patterns go to the Patterns room: an H5OINA whose scan holds only unprocessed patterns reads those (kikuchipy refuses it
//    unless asked for them), and an H5OINA's map comes with its patterns (kikuchipy 0.13.1 leaves it empty), while a map that does not
//    read never keeps the patterns from opening.
//  - A map without patterns goes to the Maps room: AZtec's H5OINA map export (#513) and orix's own HDF5 file, read as orix 0.15.0
//    reads it (ebsd-orix-map.truth.json, tools/parity/sem-readers/make_orix_map_fixtures.py): the points `is_in_data` keeps, and of a
//    map with several rotations a point the first, the one orix shows.
//  - An EDS-only H5OINA, and a Bruker or EDAX file saved without patterns (whose maps are not read yet), are refused in their sentences.
//  Fixtures: tools/parity/sem-readers/make_h5oina_map_fixtures.py, make_orix_map_fixtures.py, make_h5ebsd_without_patterns.py.
//  Red before: the EDS-only file and the files without patterns were refused as "neither a Velox file nor an EBSD scan … open it in
//  mac4DSTEM" or with "could not find patterns in the expected dataset 'EBSD/Data/RawPatterns'."; the unprocessed-only scan with the
//  missing 'Processed Patterns'; orix's map file as an HDF5 file macEM does not open; the reader's refusals named no file.
//

import Foundation
import FormatoCore
import FormatoHDF5
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class EBSDH5ContentTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    /// A sentence a user reads: it names the file and quotes nothing (no 'EBSD/Data/…', no HDF5 call).
    private static func assertPlain(_ sentence: String, names file: String, file path: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sentence.contains(file), "does not name \(file): \(sentence)", file: path, line: line)
        let rest = sentence.replacingOccurrences(of: file, with: "<file>")
        for leak in ["'", "/EBSD", "HDF5 failed", "H5D", "H5F", "dataset", "Error Domain"] {
            XCTAssertFalse(rest.contains(leak), "carries \(leak): \(sentence)", file: path, line: line)
        }
    }

    // MARK: - Which room

    func testEachEBSDFileGoesToTheRoomOfWhatItHoldsOrIsRefusedInWords() throws {
        let patterns: [(String, EBSDFileFormat)] = [
            ("ebsd-oxford.h5oina", .oxfordH5OINA), ("ebsd-oxford-map-patterns.h5oina", .oxfordH5OINA),
            ("ebsd-oxford-map-unprocessed.h5oina", .oxfordH5OINA), ("ebsd-bruker-h5ebsd.h5", .brukerH5EBSD),
            ("ebsd-edax-h5ebsd.h5", .edaxH5EBSD), ("ebsd-kikuchipy-h5ebsd.h5", .kikuchipyH5EBSD),
        ]
        for (name, format) in patterns {
            XCTAssertEqual(EBSDH5Reader.content(url: Self.fixture(name)), .patterns(format), name)
            XCTAssertEqual(FileRouting.inventory(path: Self.fixture(name).path), FileInventory(ebsdPatterns: true), name)
        }
        let maps: [(String, EBSDH5Reader.MapLayout)] = [
            ("ebsd-oxford-map.h5oina", .oxford), ("ebsd-orix-map.h5", .orix), ("ebsd-orix-map-best2.h5", .orix), ("ebsd-orix-map-crop.h5", .orix),
        ]
        for (name, layout) in maps {
            XCTAssertEqual(EBSDH5Reader.content(url: Self.fixture(name)), .map(layout), name)
            XCTAssertEqual(FileRouting.inventory(path: Self.fixture(name).path), FileInventory(orientationMap: true), name)
        }
        let refused = [
            "ebsd-oxford-eds.h5oina": "ebsd-oxford-eds.h5oina holds EDS data from AZtec but no EBSD data. macEM does not read EDS from an "
                + ".h5oina file yet; a spectrum AZtec exports as .msa opens in the EDS room.",
            "ebsd-bruker-nopatterns-h5ebsd.h5": "ebsd-bruker-nopatterns-h5ebsd.h5 is a Bruker Esprit file saved without its EBSD patterns. "
                + "macEM does not read its orientation map yet; the map exported as .ang or .ctf opens in the Maps room.",
            "ebsd-edax-nopatterns-h5ebsd.h5": "ebsd-edax-nopatterns-h5ebsd.h5 is an EDAX OIM file saved without its EBSD patterns. "
                + "macEM does not read its orientation map yet; the map exported as .ang opens in the Maps room.",
        ]
        for (name, sentence) in refused {
            XCTAssertEqual(EBSDH5Reader.content(url: Self.fixture(name)), .refused(sentence), name)
            XCTAssertEqual(FileRouting.inventory(path: Self.fixture(name).path), FileInventory(refusal: sentence), name)
            Self.assertPlain(sentence, names: name)
        }
        XCTAssertNil(EBSDH5Reader.content(url: Self.fixture("velox-haadf-last.emd")), "not an EBSD file: the Velox route decides")
    }

    /// The app's Open: the EDS-only file is refused in its sentence and nothing opens; orix's map lands in the Maps room.
    @MainActor func testOpeningRefusesTheEDSOnlyFileAndLandsOrixsMapInTheMapsRoom() async throws {
        let eds = AppState(launch: LaunchOptions(arguments: []))
        await eds.open(urls: [Self.fixture("ebsd-oxford-eds.h5oina")])?.value
        let message = try XCTUnwrap(eds.errorMessage)
        XCTAssertTrue(message.hasPrefix("ebsd-oxford-eds.h5oina holds EDS data from AZtec but no EBSD data."), message)
        XCTAssertNil(eds.ebsd.dataset)
        XCTAssertNil(eds.maps.document)

        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [Self.fixture("ebsd-orix-map.h5")])?.value
        XCTAssertEqual(state.navigation.workspaceArea, .maps)
        for _ in 0..<4000 where state.maps.raster == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(state.maps.fileName, "ebsd-orix-map.h5")
        XCTAssertEqual(state.maps.document?.format, ".h5 (orix)")
        XCTAssertNil(state.errorMessage)
    }

    // MARK: - orix's map file

    private struct Truth: Decodable {
        struct Phase: Decodable { var id: Int; var name: String; var spaceGroup: Int?; var pointGroup: String?; var color: String; var lattice: [String] }
        struct File: Decodable {
            var size: Int; var pointCount: Int; var shape: [Int]; var rotationsPerPoint: Int
            var phaseIDs: [Int]; var x: [String]; var y: [String]; var euler: [String]
            var properties: [String: [String]]; var scanUnit: String; var dx: String; var dy: String; var phases: [Phase]
        }
        var orix: String
        var files: [String: File]
    }

    private static func numbers(_ values: [String]) -> [Double] { values.map { Double($0) ?? .nan } }

    /// Each orix file reads as `orix.io.load` reads it, exactly: the points in data, their phases, x and y, the Euler angles the file
    /// stores (the first rotation of each point), every property (its first column), the phases and the unit. Red under: `is_in_data`
    /// ignored (the cut map shows 12 points, not 6), the second rotation of each point read as a point of its own, "None" taken as a
    /// point group.
    func testOrixsMapFilesReadAsOrixReadsThem() throws {
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: Self.fixture("ebsd-orix-map.truth.json")))
        XCTAssertEqual(truth.orix, "0.15.0")
        XCTAssertEqual(truth.files.count, 3)
        for (name, expected) in truth.files.sorted(by: { $0.key < $1.key }) {
            let map = try EBSDH5Reader.readOrixMap(url: Self.fixture(name))
            XCTAssertEqual(map.size, expected.size, name)
            XCTAssertEqual(map.pointCount, expected.pointCount, name)
            XCTAssertEqual(map.shape, expected.shape, name)
            XCTAssertEqual(map.phaseIDs, expected.phaseIDs, name)
            XCTAssertEqual(map.x, Self.numbers(expected.x), name)
            XCTAssertEqual(map.y, Self.numbers(expected.y), name)
            XCTAssertEqual([map.dx, map.dy], Self.numbers([expected.dx, expected.dy]), name)
            let euler = Self.numbers(expected.euler)
            XCTAssertEqual(map.eulerInData, (0..<expected.size).map { SIMD3(euler[3 * $0], euler[3 * $0 + 1], euler[3 * $0 + 2]) }, name)
            XCTAssertEqual(map.propertyNames, expected.properties.keys.sorted(), name)
            for (property, values) in expected.properties { XCTAssertEqual(map.property(property), Self.numbers(values), "\(name) \(property)") }
            XCTAssertEqual(map.scanUnit, expected.scanUnit, name)
            XCTAssertEqual(map.phases.ids, expected.phases.map(\.id), name)
            for phase in expected.phases {
                let read = try XCTUnwrap(map.phases[id: phase.id], "\(name) phase \(phase.id)")
                XCTAssertEqual(read.name, phase.name, "\(name) phase \(phase.id)")
                XCTAssertEqual(read.color, phase.color, "\(name) phase \(phase.id)")
                guard phase.id != PhaseList.notIndexedID else { continue }
                XCTAssertEqual(read.spaceGroup, phase.spaceGroup, "\(name) phase \(phase.id)")
                XCTAssertEqual(read.pointGroupName, phase.pointGroup, "\(name) phase \(phase.id)")
                // The file stores the cell as given (3.21 Å); diffpy recomputes it from its base (3.2099999999999587), so the cell is
                // held to the file's numbers within the float64 rounding of that recomputation.
                let lattice = try XCTUnwrap(read.lattice, "\(name) phase \(phase.id)")
                for (got, want) in zip(lattice, Self.numbers(phase.lattice)) { XCTAssertEqual(got, want, accuracy: 1e-12 * max(1, abs(want))) }
            }
        }
    }

    /// The Maps room reads orix's file and names its format for Info.
    func testTheMapsRoomReadsOrixsMapFile() async throws {
        let document = try await OrientationMapSession.read(Self.fixture("ebsd-orix-map-crop.h5"))
        XCTAssertEqual(document.source, .mapFile)
        XCTAssertEqual(document.format, ".h5 (orix)")
        XCTAssertEqual(document.map, try EBSDH5Reader.readOrixMap(url: Self.fixture("ebsd-orix-map-crop.h5")))
        XCTAssertEqual(document.size, 6)
    }

    // MARK: - H5OINA patterns and their map

    /// An H5OINA scan with patterns carries its map; one that holds only unprocessed patterns reads those, pixel for pixel; one whose
    /// map does not read (kikuchipy's dummy file lists no phases) still opens its patterns.
    func testAnH5OINAsPatternsCarryTheirMapAndUnprocessedOnesRead() throws {
        let map = try EBSDH5Reader.readOxfordMap(url: Self.fixture("ebsd-oxford-map.h5oina"))
        for (name, dataset) in [("ebsd-oxford-map-patterns.h5oina", "Processed Patterns"), ("ebsd-oxford-map-unprocessed.h5oina", "Unprocessed Patterns")] {
            let read = try EBSDH5Reader.read(url: Self.fixture(name))
            XCTAssertEqual(read.patterns.datasetPath, "/1/EBSD/Data/" + dataset, name)
            XCTAssertEqual([read.scanRows, read.scanColumns, read.patternRows, read.patternColumns], [3, 4, 4, 5], name)
            XCTAssertEqual(read.crystalMap, map, "\(name): the map beside the patterns")
            let reader = try EBSDPatternReader(read)
            for (row, column) in [(0, 0), (1, 2), (2, 3)] {
                let i = row * 4 + column
                XCTAssertEqual(try reader.pattern(row: row, column: column).doubles(), (0..<20).map { Double(((i * 20 + $0) * 7) % 251) },
                               "\(name) pattern at \(row), \(column)")
            }
        }
        let dummy = try EBSDH5Reader.read(url: Self.fixture("ebsd-oxford.h5oina"))
        XCTAssertNil(dummy.crystalMap, "no phases listed: no map, and the patterns open")
        XCTAssertEqual(try EBSDPatternReader(dummy).pattern(row: 0, column: 0).count, 3600)
    }

    // MARK: - The sentences

    /// A refusal names the file and says what is wrong in words; an HDF5 failure never shows its call or the path inside the file.
    func testRefusalsNameTheFileAndKeepHDF5InternalsOut() throws {
        let file = URL(fileURLWithPath: "/data/scan 7.h5oina")
        let filter = HDF5FileError.hdf5(operation: "reading /1/EBSD/Data/Processed Patterns",
                                        detail: "H5Dread: required filter 'blosc' is not registered")
        XCTAssertEqual(EBSDReadError.wrap(filter, file: file).text, "scan 7.h5oina: its data is compressed with a filter macEM does not have.")
        XCTAssertEqual(EBSDReadError.wrap(HDF5FileError.cannotOpen("H5Fopen failed"), file: file).text,
                       "scan 7.h5oina: it cannot be opened as an HDF5 file (it may be damaged, or still being written).")
        XCTAssertEqual(EBSDReadError.wrap(EBSDReadError(text: "it holds no EBSD patterns."), file: file).text,
                       "scan 7.h5oina: it holds no EBSD patterns.")
        XCTAssertEqual(EBSDReadError.wrap(EBSDReadError(text: "scan 7.h5oina holds no EBSD map."), file: file).text,
                       "scan 7.h5oina holds no EBSD map.", "a sentence that names the file already is kept")
        for error: any Error in [filter, HDF5FileError.notFound("/1/EBSD/Header/Pattern Height"),
                                 HDF5FileError.unsupportedType(path: "/1/EBSD/Data/Euler", type: "compound")] {
            Self.assertPlain(EBSDReadError.wrap(error, file: file).text, names: "scan 7.h5oina")
        }

        let velox = Self.fixture("velox-haadf-last.emd")
        XCTAssertThrowsError(try EBSDH5Reader.read(url: velox)) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text,
                           "velox-haadf-last.emd: it is not an EBSD file (it does not name the software that wrote it).")
        }
        XCTAssertThrowsError(try EBSDH5Reader.readMap(url: Self.fixture("ebsd-oxford.h5oina"))) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text,
                           "ebsd-oxford.h5oina holds EBSD patterns: it opens in the Patterns room, which shows its map.")
        }
        XCTAssertThrowsError(try EBSDH5Reader.read(url: Self.fixture("ebsd-bruker-nopatterns-h5ebsd.h5"))) { error in
            let text = (error as? EBSDReadError)?.text ?? "\(error)"
            XCTAssertEqual(text, "ebsd-bruker-nopatterns-h5ebsd.h5: it holds no EBSD patterns.")
            Self.assertPlain(text, names: "ebsd-bruker-nopatterns-h5ebsd.h5")
        }
    }
}
