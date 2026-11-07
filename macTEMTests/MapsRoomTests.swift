//
//  MapsRoomTests.swift
//  The Maps room's first slice (brief P3-04, docs/sem/design/orientation-maps-room.md): the map pictures against orix 0.15.0's
//  `CrystalMap.plot` (bundle `m3/maps-room-sdss`: the IPF-X, IPF-Y, IPF-Z and phase map images of orix-data's two-phase steel, the
//  F6 map on screen), the routing of an `.ang` or `.ctf` alone into the room, the session's layers, hover words and keys, the room
//  following the Patterns room's dataset, the unit cell of the orientation pane and the PNG figure. Red before: none of
//  `OrientationMaps`, `OrientationMapSession` or the room exists, and a lone `.ang` was refused. Red after a transposed map, a phase
//  coloured by another's key, a layer that does not land, or a lone map refused again.
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class MapsRoomTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static var sdss: URL { fixtures.appendingPathComponent("ebsd-sdss-ferrite-austenite.ang") }

    private func flat(_ a: [SIMD3<Double>]) -> [Double] { a.flatMap { [$0.x, $0.y, $0.z] } }

    // MARK: - Parity: the map pictures are orix's plot

    /// The IPF-Z, IPF-X and IPF-Y map images and the phase map image of the two-phase steel, laid out in rows and columns, equal orix's
    /// within the bundle's tolerance (colours atol 1e-6, phases exact). Red under: rows and columns swapped, the sample direction ignored,
    /// a phase's colour from the other phase, the not-indexed fill moved.
    func testTheMapPicturesAreOrixsPlotOfTheTwoPhaseSteel() throws {
        let ref = try SEMParityReference.load("m3/maps-room-sdss")
        let map = try ANGReader.read(url: Self.sdss).map
        XCTAssertEqual(OrientationMaps.gridShape(map).rows, 100)
        XCTAssertEqual(OrientationMaps.gridShape(map).columns, 117)
        for (direction, name) in [(SampleDirection.z, "ipf_z_image"), (.x, "ipf_x_image"), (.y, "ipf_y_image")] {
            let raster = OrientationMaps.raster(.ipf(direction), of: map)
            XCTAssertEqual([raster.rows, raster.columns], [100, 117])
            SEMAssertParity(flat(try XCTUnwrap(raster.rgb)), try ref.array(name), shape: [100, 117, 3])
            XCTAssertTrue(raster.inData.allSatisfy { $0 })
        }
        let phase = OrientationMaps.raster(.phase, of: map)
        SEMAssertParity(flat(try XCTUnwrap(phase.rgb)), try ref.array("phase_image"), shape: [100, 117, 3])
        // The bundle's IPF-Z is F6's numbers (m3/ipf-sdss-ferrite-austenite), the same colours point by point.
        let f6 = try SEMParityReference.load("m3/ipf-sdss-ferrite-austenite")
        SEMAssertParity(flat(OrientationMaps.ipfColors(map, direction: Vector3.z)), try f6.array("ipf_z_rgb"))
    }

    /// The RGBA the Metal view and the figure take: each colour to the nearest byte, opaque where a point is.
    func testTheRasterBytesAreTheColoursRounded() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let raster = OrientationMaps.raster(.ipf(.z), of: map)
        let bytes = try XCTUnwrap(raster.rgba8)
        let rgb = try XCTUnwrap(raster.rgb)
        XCTAssertEqual(bytes.count, 100 * 117 * 4)
        for i in [0, 117, 5000, 11_699] {
            XCTAssertEqual(bytes[4 * i], UInt8((rgb[i].x * 255).rounded()))
            XCTAssertEqual(bytes[4 * i + 2], UInt8((rgb[i].z * 255).rounded()))
            XCTAssertEqual(bytes[4 * i + 3], 255)
        }
        let iq = OrientationMaps.raster(.property("iq"), of: map)
        XCTAssertNil(iq.rgba8)
        XCTAssertEqual(try XCTUnwrap(iq.values?.first), 24.4, accuracy: 1e-4)
        XCTAssertNotNil(iq.valueRange)
    }

    // MARK: - Words

    /// The layers in the Maps control's order, and the hover's words (design §3): phase, Bunge angles in degrees, the file's properties.
    func testTheLayersAndTheHoverWords() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        XCTAssertEqual(OrientationMaps.layers(of: map), [.ipf(.z), .ipf(.x), .ipf(.y), .phase, .property("dp"), .property("iq")])
        XCTAssertEqual(OrientationMaps.layers(of: map).map(\.title), ["IPF-Z", "IPF-X", "IPF-Y", "Phase", "dp", "iq"])
        let grid = OrientationMaps.pointIndexGrid(map)
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(OrientationMaps.readout(map, grid: grid, row: 0, column: 0, locale: en),
                       "row 0 · col 0 · ferrite/ferrite · φ₁ 203.3° Φ 38.8° φ₂ 171.2° · dp 0.799 · iq 24.4")
        XCTAssertNil(OrientationMaps.readout(map, grid: grid, row: 100, column: 0, locale: en))
        XCTAssertNil(OrientationMaps.readout(map, grid: grid, row: 0, column: -1, locale: en))
        XCTAssertEqual(MapsRoomFormat.capsuleDetail(map), "100 × 117 · 2 phases")
        XCTAssertEqual(MapsRoomFormat.mapTitle(.ipf(.x)), "Map · IPF-X")
    }

    /// The key of a cubic phase: the TSL key image of m-3m, its longer side the key's pixels, its three corners labelled.
    func testTheCubicKeyIsLabelledAtItsCorners() throws {
        let group = try XCTUnwrap(PointGroup.named("432"))
        let (image, labels) = OrientationMaps.keyImage(for: group)
        XCTAssertTrue((OrientationMaps.keySide...(OrientationMaps.keySide + 1)).contains(max(image.width, image.height)), "\(image.width) × \(image.height)")
        XCTAssertEqual(Set(labels.map(\.text)), ["[001]", "[101]", "[111]"])
        for label in labels {
            XCTAssertTrue((-1...Double(image.width)).contains(label.column), "\(label)")
            XCTAssertTrue((-1...Double(image.height)).contains(label.row), "\(label)")
        }
        XCTAssertEqual(OrientationMaps.directionLabel(SIMD3(0, 0, 1)), "[001]")
        XCTAssertNil(OrientationMaps.directionLabel(SIMD3(0.3, 0.7, 1)))
    }

    /// The unit cell the orientation pane draws: twelve edges, the farthest corner at 1; at the identity a cube's edges lie along the axes,
    /// turned 90° about z its x edges lie along y.
    func testTheUnitCellIsTheLatticeTurnedIntoTheSampleFrame() throws {
        let phase = CrystalPhase(name: "austenite", pointGroup: "432", lattice: [3.595, 3.595, 3.595, 90, 90, 90])
        let identity = OrientationMaps.unitCellEdges(phase: phase, rotation: SIMD4(1, 0, 0, 0))
        XCTAssertEqual(identity.count, 12)
        let side = 2 / 3.0.squareRoot()
        for (a, b) in identity {
            let d = b - a
            XCTAssertEqual([abs(d.x), abs(d.y), abs(d.z)].filter { $0 > 1e-12 }.count, 1)
            XCTAssertEqual((d * d).sum().squareRoot(), side, accuracy: 1e-12)
        }
        let turned = OrientationMaps.unitCellEdges(phase: phase, rotation: Rotation.fromAxisAngle(Vector3.z, Double.pi / 2).q)
        let first = turned[0].1 - turned[0].0   // the a edge
        XCTAssertEqual(abs(first.y), side, accuracy: 1e-12)
        XCTAssertEqual(first.x, 0, accuracy: 1e-12)
    }

    // MARK: - Routing

    /// An `.ang` with no pattern file of its name next to it opens in the Maps room; the room is enterable exactly when the window holds a map.
    func testALoneMapRoutesToTheMapsRoom() throws {
        XCTAssertTrue(EBSDOpening.isLoneMap(Self.sdss))
        XCTAssertEqual(FileRouting.inventory(path: Self.sdss.path), FileInventory(orientationMap: true))
        XCTAssertEqual(FileInventory(orientationMap: true).landing, .maps)
        XCTAssertEqual(FileInventory(ebsdPatterns: true, orientationMap: true).landing, .patterns)
        XCTAssertGreaterThan(FileInventory.Landing.patterns.richness, FileInventory.Landing.maps.richness)
        XCTAssertGreaterThan(FileInventory.Landing.maps.richness, FileInventory.Landing.eds.richness)
        XCTAssertNil(RoomAvailability.reason(.maps, holdings: RoomHoldings(maps: true)))
        XCTAssertNotNil(RoomAvailability.reason(.maps, holdings: RoomHoldings(ebsd: true)))
        XCTAssertNotNil(RoomAvailability.reason(.patterns, holdings: RoomHoldings(maps: true)))
        XCTAssertEqual(RoomAvailability.fallback(holdings: RoomHoldings(maps: true)), .maps)
    }

    /// The app's Open: the `.ang` lands in the Maps room and the map is shown at IPF-Z.
    @MainActor func testOpeningALoneMapLandsInTheMapsRoom() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [Self.sdss])?.value
        XCTAssertEqual(state.navigation.workspaceArea, .maps)
        for _ in 0..<4000 where state.maps.raster == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(state.maps.fileName, "ebsd-sdss-ferrite-austenite.ang")
        XCTAssertEqual(state.maps.document?.source, .mapFile)
        XCTAssertEqual(state.maps.layer, .ipf(.z))
        XCTAssertEqual(state.windowTitle, "ebsd-sdss-ferrite-austenite.ang")
        XCTAssertNil(state.roomUnavailableReason(.maps))
    }

    // MARK: - The session

    /// The session's layers land, the keys of both phases are made, and the orientation pane's point is the map's.
    @MainActor func testTheSessionDrawsEveryLayerAndTheKeys() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        XCTAssertFalse(session.isOpening)
        XCTAssertEqual(session.layer, .ipf(.z))
        let ref = try SEMParityReference.load("m3/maps-room-sdss")
        SEMAssertParity(flat(try XCTUnwrap(session.raster?.rgb)), try ref.array("ipf_z_image"))
        XCTAssertEqual(session.rasterRGBA?.count, 100 * 117 * 4)
        await session.setLayer(.phase).value
        SEMAssertParity(flat(try XCTUnwrap(session.raster?.rgb)), try ref.array("phase_image"))
        await session.setLayer(.property("iq")).value
        XCTAssertNil(session.rasterRGBA)
        XCTAssertEqual(session.propertyPresentation.canvas?.width, 117)
        for _ in 0..<4000 where session.keys.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.keys.map(\.name), ["austenite/austenite", "ferrite/ferrite"])
        XCTAssertEqual(session.keys.map(\.pointGroup), ["432", "432"])

        session.pin(EBSDPosition(row: 0, column: 0))
        let point = try XCTUnwrap(session.orientation(at: .origin))
        XCTAssertEqual(point.phase.name, "ferrite/ferrite")
        XCTAssertEqual(point.euler.x, 3.54788, accuracy: 1e-6)
        session.step(.right, by: 10)
        XCTAssertEqual(session.pinned, EBSDPosition(row: 0, column: 10))
        session.step(.left, by: 100)
        XCTAssertEqual(session.pinned, EBSDPosition(row: 0, column: 0))
        session.close()
        XCTAssertFalse(session.hasMap)
        XCTAssertNil(session.raster)
    }

    /// The Maps room follows the Patterns room: a dataset whose file carries a crystal map shows it here with its patterns (the source is
    /// the patterns, so the live pattern pane is the Patterns room's); closing the dataset takes the map with it.
    @MainActor func testTheMapsRoomShowsThePatternFilesCrystalMap() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        let url = try XCTUnwrap(Bundle(for: MapsRoomTests.self).url(forResource: "ebsd-kikuchipy-h5ebsd", withExtension: "h5"))
        await state.ebsd.open(url: url).value
        XCTAssertEqual(state.maps.document?.source, .patterns)
        XCTAssertEqual(state.maps.fileName, "ebsd-kikuchipy-h5ebsd.h5")
        XCTAssertEqual(state.maps.gridShape.rows, state.ebsd.dataset?.scanRows)
        XCTAssertNil(state.roomUnavailableReason(.maps))
        state.ebsd.close()
        XCTAssertFalse(state.maps.hasMap)
    }

    // MARK: - Export

    /// Map PNG… writes the figure (map, scale bar, key) as a PNG wider than the map, named after the file and the layer.
    @MainActor func testTheMapFigureIsWritten() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        for _ in 0..<4000 where session.keys.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let state = MapsRoomState()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maps-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var reports: [String] = []
        state.exportMap(from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports, ["Exported ebsd-sdss-ferrite-austenite map IPF-Z.png"])
        let data = try Data(contentsOf: dir.appendingPathComponent("ebsd-sdss-ferrite-austenite map IPF-Z.png"))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(MapsFigure.scale(columns: 117), 6)
        XCTAssertEqual(MapsFigure.niceLength(175.5), 20)
        XCTAssertEqual(MapsFigure.niceLength(1000), 200)
    }

    // MARK: - The room key

    /// Maps sits after Patterns with the plan's fixed key: ⌘8, leaving ⌘7 to Indexing, Results ⌘9 (D-SEM-80).
    @MainActor func testTheMapsRoomIsOnCommandEight() {
        XCTAssertEqual(WorkspaceArea.maps.shortcutDigit, "8")
        XCTAssertEqual(WorkspaceArea.results.shortcutDigit, "9")
        XCTAssertEqual(WorkspaceArea.maps.title, "Maps")
        XCTAssertEqual(WorkspaceArea.maps.systemImage, "map")
        XCTAssertTrue(LaunchOptions(arguments: ["--demo-ang"]).demoOrientationMap)
        XCTAssertEqual(DemoDocument.orientationMap.room, .maps)
    }
}
