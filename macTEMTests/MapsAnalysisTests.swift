//
//  MapsAnalysisTests.swift
//  The Maps room's grain analysis and texture (brief P5-04, `MapAnalysis`, `MapTexture`, `OrientationMapSession.segment`) on orix-data's
//  two-phase steel (Fixtures/ebsd-sdss-ferrite-austenite.ang). The room's Segment at DefDAP's settings of bundle `m5/grains-sdss`
//  (boundaries above 10°, grains of 10 points or more, KAM to 5°) is DefDAP 1.3.1's grain map, KAM and GOS at the bundle's tolerances
//  (exact grain map and sizes, atol 1e-6 on angles); the table, the boundary edges, the outline, the slip and the texture are the ported
//  functions laid out as the room draws them. Red before P5-04: none of these types or the Segment verb exists.
//

import FormatoCore
import Foundation
import TEMCore
import ShellLayout
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class MapsAnalysisTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static var sdss: URL { fixtures.appendingPathComponent("ebsd-sdss-ferrite-austenite.ang") }
    private static let defdap = MapAnalysisSettings(boundaryDegrees: 10, minimumSize: 10, kamMaxDegrees: 5)

    private func minusOneForNaN(_ a: [Double]) -> [Double] { a.map { $0.isNaN ? -1 : $0 } }

    // MARK: - Against DefDAP

    func testSegmentIsDefDAPsGrainsKAMAndGOSOfTheTwoPhaseSteel() throws {
        let ref = try SEMParityReference.load("m5/grains-sdss")
        XCTAssertEqual(ref.values["boundary_degrees"] as? Double, Self.defdap.boundaryDegrees)
        XCTAssertEqual(ref.values["min_grain_size"] as? Int, Self.defdap.minimumSize)
        XCTAssertEqual(ref.values["kam_threshold_degrees"] as? Double, Self.defdap.kamMaxDegrees)
        let map = try ANGReader.read(url: Self.sdss).map
        let analysis = try MapAnalysis.run(map, settings: Self.defdap)

        XCTAssertEqual(analysis.table.count, ref.values["grain_count"] as? Int)
        SEMAssertParity(analysis.grains.segmentation.grainMap.map(Double.init), try ref.array("grains"))
        SEMAssertParity(analysis.table.map { Double($0.points) }, try ref.array("grain_sizes"))
        SEMAssertParity(minusOneForNaN(analysis.grains.kam), try ref.array("kam_threshold"))
        SEMAssertParity(analysis.table.map { $0.gosDegrees * .pi / 180 }, try ref.array("gos"))

        // The KAM and GOS layers are those numbers in degrees, per grid cell.
        let kam = try XCTUnwrap(analysis.values(.kam))
        XCTAssertEqual(minusOneForNaN(kam.map { $0 * .pi / 180 }).count, analysis.rows * analysis.columns)
        let gosMap = try XCTUnwrap(analysis.values(.gos))
        for (k, row) in analysis.table.enumerated() {
            let p = analysis.grains.segmentation.grains[k].points[0]
            XCTAssertEqual(gosMap[p], row.gosDegrees, accuracy: 1e-12)
        }
    }

    // MARK: - The table

    func testTheGrainTableIsTheSegmentationsGrains() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let analysis = try MapAnalysis.run(map, settings: Self.defdap)
        let seg = analysis.grains.segmentation
        XCTAssertEqual(analysis.table.map(\.id), Array(1...seg.grains.count))
        XCTAssertEqual(analysis.scanUnit, map.scanUnit)
        for (k, row) in analysis.table.enumerated() {
            let grain = seg.grains[k]
            XCTAssertEqual(row.points, grain.size)
            XCTAssertEqual(row.area, Double(grain.size) * map.dx * map.dx, accuracy: 1e-9)
            XCTAssertEqual(row.diameter, 2 * (row.area / .pi).squareRoot(), accuracy: 1e-9)
            // Every point of the grain is on the grain map under the row's number.
            XCTAssertTrue(grain.points.allSatisfy { seg.grainMap[$0] == row.id })
            // The mean orientation reads back: Bunge degrees of DefDAP's average quaternion.
            let back = RotationConversions.eu2qu(row.euler * (.pi / 180))
            let dot = abs((back * row.orientation).sum())
            XCTAssertEqual(dot, 1, accuracy: 1e-9)
            XCTAssertEqual(row.phaseName, grain.phaseIndex.map { map.phases[id: analysis.phaseIDs[$0]]?.name ?? "" } ?? "mixed")
        }
        let neighbours = analysis.table.reduce(0) { $0 + $1.neighbours }
        XCTAssertEqual(neighbours, 2 * analysis.grains.neighbours.count, "each pair counted on both sides")
        XCTAssertNotNil(analysis.meanLinealIntercept)
        let astm = try XCTUnwrap(analysis.astmGrainSizeNumber)
        XCTAssertEqual(astm, GrainSegmentation.astmGrainSizeNumber(meanLinealInterceptMillimetres: try XCTUnwrap(analysis.meanLinealIntercept) / 1000),
                       accuracy: 1e-12)
    }

    // MARK: - Boundaries and outline

    func testTheBoundaryEdgesAreDefDAPsBoundaryPixelsAtTheirPixelEdges() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let analysis = try MapAnalysis.run(map, settings: Self.defdap)
        let b = analysis.grains.boundaries
        let edges = analysis.boundaryEdges()
        let c = analysis.columns
        func inside(_ i: Int, right: Bool) -> Bool { right ? i % c + 1 < c : i / c + 1 < analysis.rows }
        let expectedPhase = b.phaseX.indices.filter { b.phaseX[$0] && inside($0, right: true) }.count
            + b.phaseY.indices.filter { b.phaseY[$0] && inside($0, right: false) }.count
        let expectedGrain = b.grainX.indices.filter { b.grainX[$0] && !b.phaseX[$0] && inside($0, right: true) }.count
            + b.grainY.indices.filter { b.grainY[$0] && !b.phaseY[$0] && inside($0, right: false) }.count
        XCTAssertEqual(edges.phase.count, expectedPhase)
        XCTAssertEqual(edges.grain.count, expectedGrain)
        XCTAssertGreaterThan(edges.phase.count, 0, "a two-phase map has phase boundaries")
        // Every edge lies on a half-integer line between two pixel centres.
        for (a, e) in edges.grain + edges.phase {
            XCTAssertTrue(a.x == e.x || a.y == e.y)
            XCTAssertEqual(abs((a - e).sum()), 1, accuracy: 1e-12)
        }
    }

    func testAGrainsOutlineIsClosed() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let analysis = try MapAnalysis.run(map, settings: Self.defdap)
        let largest = try XCTUnwrap(analysis.table.max { $0.points < $1.points })
        let outline = analysis.outline(of: largest.id)
        XCTAssertFalse(outline.isEmpty)
        // A closed boundary meets every corner an even number of times.
        var degree: [SIMD2<Double>: Int] = [:]
        for (a, b) in outline { degree[a, default: 0] += 1; degree[b, default: 0] += 1 }
        XCTAssertTrue(degree.values.allSatisfy { $0 % 2 == 0 })
        XCTAssertEqual(analysis.grain(atRow: Int(largest.centroid.y.rounded()), column: Int(largest.centroid.x.rounded())) != nil, true)
    }

    // MARK: - Slip and GND

    func testTheSlipOfEachGrainIsDefDAPsForItsMeanOrientation() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let analysis = try MapAnalysis.run(map, settings: Self.defdap)
        let files = OrientationMapSession.defaultSlipFiles(map)
        let names = Dictionary(uniqueKeysWithValues: map.phases.entries.map { ($0.id, $0.phase.name.lowercased()) })
        XCTAssertEqual(files.count, 2, "austenite and ferrite get their slip systems by name: \(names)")
        for (id, file) in files {
            XCTAssertEqual(file, names[id]!.contains("austenite") ? .cubicFCC : .cubicBCC)
        }
        let slip = analysis.slip(load: SampleDirection.x.vector, files: files, phases: map.phases)
        XCTAssertEqual(slip.count, analysis.table.filter { $0.phaseID != nil }.count)
        let first = try XCTUnwrap(slip.first)
        let row = try XCTUnwrap(analysis.table.first { $0.id == first.grain })
        let set = try XCTUnwrap(MapAnalysis.slipSystems(try XCTUnwrap(files[try XCTUnwrap(row.phaseID)]), phase: try XCTUnwrap(map.phases[id: row.phaseID!])))
        XCTAssertEqual(first.maximumSchmid, SlipTraceAnalysis.maximumSchmidFactor(orientation: row.orientation, load: Vector3.x, systems: set), accuracy: 1e-12)
        let traces = SlipTraceAnalysis.traces(orientation: row.orientation, systems: set)
        XCTAssertEqual(first.planes.map(\.traceAngle), traces.map(\.angle))
        XCTAssertTrue(slip.allSatisfy { $0.maximumSchmid > 0 && $0.maximumSchmid <= 0.5 + 1e-12 })
        // DefDAP's `add_traces` gives a trace past the colour list the list's last colour (`colours[len(colours) - 1]`), never black: the
        // ferrite's cubic_bcc file has fewer colours than plane groups (#573: the extra traces were drawn black).
        let bcc = try XCTUnwrap(slip.first { g in files[analysis.table.first { $0.id == g.grain }?.phaseID ?? -1] == .cubicBCC })
        let bccRow = try XCTUnwrap(analysis.table.first { $0.id == bcc.grain })
        let bccSet = try XCTUnwrap(MapAnalysis.slipSystems(.cubicBCC, phase: try XCTUnwrap(map.phases[id: try XCTUnwrap(bccRow.phaseID)])))
        XCTAssertLessThan(bccSet.traceColours.count, bcc.planes.count, "setup: more plane groups than colours")
        for (k, plane) in bcc.planes.enumerated() {
            XCTAssertEqual(plane.colour, k < bccSet.traceColours.count ? bccSet.traceColours[k] : bccSet.traceColours.last, "plane \(k)")
        }

        // The Schmid layer: each grain's points carry its largest factor.
        let values = try XCTUnwrap(analysis.values(.schmid, slip: slip))
        let p = analysis.grains.segmentation.grains[first.grain - 1].points[0]
        XCTAssertEqual(values[p], first.maximumSchmid)
    }

    /// macEM#611: a step in no length unit ("px") refuses the GND in words; nm, µm and mm convert as before. Red before: "px" was
    /// taken as micrometres and the GND reported in m⁻² as if it were.
    func testGNDOnAMapWithoutALengthUnitIsRefusedAndTheGrainsStay() throws {
        var map = try ANGReader.read(url: Self.sdss).map
        let inMicrometres = try MapAnalysis.run(map, settings: Self.defdap)
        map.scanUnit = "px"
        let inPixels = try MapAnalysis.run(map, settings: Self.defdap)
        XCTAssertNil(inPixels.gnd)
        XCTAssertTrue(inPixels.gndRefusal?.contains("\"px\"") ?? false, inPixels.gndRefusal ?? "no refusal")
        XCTAssertNil(inPixels.astmGrainSizeNumber)
        XCTAssertEqual(inPixels.table.count, inMicrometres.table.count)
        XCTAssertNil(inMicrometres.gndRefusal)

        XCTAssertNil(MapAnalysis.micrometres(1, unit: "px"))
        XCTAssertNil(MapAnalysis.micrometres(1, unit: ""))
        XCTAssertEqual(MapAnalysis.micrometres(1, unit: "um"), 1)
        XCTAssertEqual(MapAnalysis.micrometres(1, unit: "µm"), 1)
        XCTAssertEqual(MapAnalysis.micrometres(500, unit: "nm"), 0.5)
        XCTAssertEqual(MapAnalysis.micrometres(0.002, unit: "mm"), 2)

        // The same step written in nm gives the same density.
        map.scanUnit = "nm"
        let inNanometres = try MapAnalysis.run(map, settings: Self.defdap)
        let expected = NyeTensor.compute(quaternions: inNanometres.grainMap.quaternions, rows: inNanometres.rows,
                                         columns: inNanometres.columns, stepMicrons: inNanometres.grainMap.step / 1000, structure: .cubic).gnd
        XCTAssertEqual(minusOneForNaN(try XCTUnwrap(inNanometres.gnd)), minusOneForNaN(expected))
    }

    func testGNDIsTheNyeTensorOfTheMapsQuaternions() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let analysis = try MapAnalysis.run(map, settings: Self.defdap)
        let gnd = try XCTUnwrap(analysis.gnd)
        let expected = NyeTensor.compute(quaternions: analysis.grainMap.quaternions, rows: analysis.rows, columns: analysis.columns,
                                         stepMicrons: analysis.grainMap.step, structure: .cubic).gnd
        XCTAssertEqual(minusOneForNaN(gnd), minusOneForNaN(expected))
        let layer = try XCTUnwrap(analysis.values(.gnd))
        for i in stride(from: 0, to: gnd.count, by: 97) where gnd[i] > 0 {
            XCTAssertEqual(layer[i], log10(gnd[i]), accuracy: 1e-12)
        }
    }

    // MARK: - Texture

    func testTheTextureIsOrixsPoleDensityOfThePhase() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let phase = try XCTUnwrap(map.phases.entries.first { $0.id != PhaseList.notIndexedID })
        let texture = try MapTexture.compute(map, phaseID: phase.id, size: 61)
        let orientations = try map.points(ofPhases: [phase.phase.name]).orientations()
        XCTAssertEqual(texture.points, orientations.count)
        XCTAssertEqual(texture.poleFigures.map(\.title), ["{100}", "{110}", "{111}"])
        let group = try XCTUnwrap(phase.phase.pointGroup)
        let l = try XCTUnwrap(phase.phase.lattice)
        let lattice = CrystalLattice(a: l[0], b: l[1], c: l[2], alpha: l[3], beta: l[4], gamma: l[5])
        let poles = try PoleFigures.poles(family: [1, 1, 1], lattice: lattice, group: group)
        let density = PoleFigures.poleFigure(orientations, poles: poles)
        // NaN outside the disk never equals itself: compare the bit patterns.
        let expected = TextureRaster.stereographic(density, size: 61)
        XCTAssertEqual(texture.poleFigures[2].raster.values.map(\.bitPattern), expected.values.map(\.bitPattern))
        XCTAssertEqual([texture.poleFigures[2].raster.width, texture.poleFigures[2].raster.height], [expected.width, expected.height])
        XCTAssertEqual(texture.poleFigures[2].maximum, density.maximum)
        XCTAssertEqual(texture.odfSections.map(\.title), ["φ₂ = 0°", "φ₂ = 45°", "φ₂ = 65°"])
        XCTAssertLessThanOrEqual(texture.odfPoints, MapTexture.odfPointLimit)
        XCTAssertNotNil(texture.inversePoleFigure)
        XCTAssertNotNil(MapsFigure.textureImage(texture.poleFigures[0].raster))
        let png = try MapsFigure.texturePNG(texture, fileName: "sdss.ang", side: 80)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        // The file's name is the figure's Title (#331).
        XCTAssertEqual(try FormatoPNG.textEntries(in: png).first { $0.keyword == "Title" }?.value, "sdss.ang")
    }

    // MARK: - The session and the room

    @MainActor func testSegmentLandsTheAnalysisAndItsLayers() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        XCTAssertNil(session.analysis)
        XCTAssertTrue(session.derivedLayers.isEmpty)
        XCTAssertTrue(session.canSegment)
        session.setAnalysisSettings(Self.defdap)
        await session.segment().value
        let analysis = try XCTUnwrap(session.analysis)
        XCTAssertFalse(session.isSegmenting)
        XCTAssertFalse(session.analysisIsStale)
        XCTAssertEqual(session.derivedLayers, [.grains, .kam, .gos, .gnd, .schmid])
        XCTAssertTrue(session.layers.contains(.derived(.kam)))
        XCTAssertFalse(session.grainBoundaryEdges.isEmpty)

        // The pinned point's grain is selected and outlined; the status line names it.
        session.pin(EBSDPosition(row: 50, column: 50))
        let grain = analysis.grain(atRow: 50, column: 50)
        XCTAssertEqual(session.selectedGrain, grain)
        if grain != nil { XCTAssertFalse(session.selectedOutline.isEmpty) }
        XCTAssertTrue(session.readout(at: EBSDPosition(row: 50, column: 50))?.contains("KAM") ?? false)

        // Picking a row pins its grain.
        let row = try XCTUnwrap(analysis.table.max { $0.points < $1.points })
        session.selectGrain(row.id)
        XCTAssertEqual(session.selectedGrain, row.id)
        XCTAssertEqual(analysis.grain(atRow: session.pinned.row, column: session.pinned.column), row.id)

        // A derived layer draws the analysis' own picture.
        await session.setLayer(.derived(.kam)).value
        let drawn = try XCTUnwrap(session.raster), made = analysis.raster(.kam)
        XCTAssertEqual(try XCTUnwrap(drawn.values).map(\.bitPattern), try XCTUnwrap(made.values).map(\.bitPattern))
        XCTAssertEqual(drawn.inData, made.inData)
        XCTAssertNotNil(session.propertyPresentation.canvas)

        // Changed settings read as stale until Segment runs again.
        var changed = Self.defdap
        changed.boundaryDegrees = 15
        session.setAnalysisSettings(changed)
        XCTAssertTrue(session.analysisIsStale)
        session.setAnalysisSettings(MapAnalysisSettings(boundaryDegrees: -3, minimumSize: 0, kamMaxDegrees: .nan))
        XCTAssertEqual(session.analysisSettings, MapAnalysisSettings(boundaryDegrees: 0.1, minimumSize: 1, kamMaxDegrees: 5))

        // Without slip systems there is no Schmid layer.
        for id in session.slipFiles.keys { session.setSlipFile(nil, phaseID: id) }
        XCTAssertTrue(session.slip.isEmpty)
        XCTAssertFalse(session.derivedLayers.contains(.schmid))

        session.close()
        XCTAssertNil(session.analysis)
        XCTAssertTrue(session.grainBoundaryEdges.isEmpty)
    }

    @MainActor func testSegmentIsTheMapsRoomsVerb() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .maps
        XCTAssertNil(RoomPrimaryAction.current(state), "no verb before a map")
        await state.maps.open(url: Self.sdss).value
        let action = try XCTUnwrap(RoomPrimaryAction.current(state))
        XCTAssertEqual(action.title, "Segment")
        XCTAssertTrue(action.isEnabled)
    }

    @MainActor func testTheGrainsAndTextureExportsAreWritten() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        session.setAnalysisSettings(Self.defdap)
        await session.segment().value
        await session.showTexture().value
        let state = MapsRoomState()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maps-analysis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var reports: [String] = []
        state.exportGrains(from: session, directory: dir) { reports.append($0) }
        state.exportTexture(from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first, "Exported ebsd-sdss-ferrite-austenite grains.csv")
        let csv = try String(contentsOf: dir.appendingPathComponent("ebsd-sdss-ferrite-austenite grains.csv"), encoding: .utf8)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 1 + (session.analysis?.table.count ?? 0))
        XCTAssertTrue(lines[0].hasPrefix("grain,phase,points,area_"))
        XCTAssertTrue(reports[1].hasPrefix("Exported ebsd-sdss-ferrite-austenite texture "))

        // The map figure of a derived layer carries the boundaries and its range.
        await session.setLayer(.derived(.grains)).value
        reports = []
        state.exportMap(from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports, ["Exported ebsd-sdss-ferrite-austenite map Grains.png"])
    }

    // MARK: - macTEM#239: histograms, several grains, poles of the selection

    func testTheHistogramsCountEveryKAMAndEveryGrain() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let analysis = try MapAnalysis.run(map, settings: Self.defdap)
        let kam = analysis.histogram(.kam)
        XCTAssertEqual(kam.edges.count, 41)
        XCTAssertEqual(kam.edges.first, 0)
        XCTAssertEqual(try XCTUnwrap(kam.edges.last), Self.defdap.kamMaxDegrees, accuracy: 1e-12)
        // KAM drops neighbours above the maximum, so every finite KAM is within it and counted.
        XCTAssertEqual(kam.counts.reduce(0, +), analysis.grains.kam.filter(\.isFinite).count)
        let gos = analysis.histogram(.gos)
        XCTAssertEqual(gos.counts.reduce(0, +), analysis.table.filter { $0.gosDegrees.isFinite }.count)
        let size = analysis.histogram(.grainSize, bins: 10)
        XCTAssertEqual(size.counts.count, 10)
        XCTAssertEqual(size.counts.reduce(0, +), analysis.table.count)
        XCTAssertEqual(try XCTUnwrap(size.edges.last), try XCTUnwrap(analysis.table.map(\.diameter).max()), accuracy: 1e-12)
        let row = try XCTUnwrap(analysis.table.first)
        XCTAssertEqual(analysis.histogramValue(.grainSize, of: row), row.diameter)
        XCTAssertNil(analysis.histogramValue(.kam, of: row))
        let csv = MapsRoomFormat.histogramCSV(.gos, histogram: gos, unit: "deg")
        XCTAssertEqual(csv.split(separator: "\n").count, 1 + gos.counts.count)
        XCTAssertTrue(csv.hasPrefix("gos_low_deg,gos_high_deg,count\n"))
    }

    func testTheOutlineOfSeveralGrainsIsOnePass() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let analysis = try MapAnalysis.run(map, settings: Self.defdap)
        let ids = Array(analysis.table.prefix(3).map(\.id))
        let together = analysis.outline(of: Set(ids))
        let apart = ids.reduce(0) { $0 + analysis.outline(of: $1).count }
        XCTAssertEqual(together.count, apart, "each grain's own edges, neighbours' shared edges kept on both sides")
        XCTAssertTrue(analysis.outline(of: Set<Int>()).isEmpty)
    }

    func testTheSelectedGrainsPolesLandWhereTheProjectionPutsThem() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let phase = try XCTUnwrap(map.phases.entries.first { $0.id != PhaseList.notIndexedID })
        let texture = try MapTexture.compute(map, phaseID: phase.id, size: 31)
        let cube = try XCTUnwrap(texture.poleFigures.first)
        XCTAssertEqual(cube.title, "{100}")
        XCTAssertFalse(cube.poles.isEmpty)
        // The identity orientation puts {100} on the centre (z) and the rim's right, left, top and bottom (x, y, folded up).
        let markers = MapTexture.poleMarkers(cube, orientations: [SIMD4(1, 0, 0, 0)])
        XCTAssertEqual(markers.count, cube.poles.count)
        let expected: [SIMD2<Double>] = [SIMD2(0.5, 0.5), SIMD2(1, 0.5), SIMD2(0, 0.5), SIMD2(0.5, 0), SIMD2(0.5, 1)]
        for m in markers {
            XCTAssertTrue(expected.contains { (($0 - m) * ($0 - m)).sum() < 1e-18 }, "\(m)")
        }
        XCTAssertTrue(markers.contains { (($0 - SIMD2(0.5, 0.5)) * ($0 - SIMD2(0.5, 0.5))).sum() < 1e-18 })
        // The IPF density and ODF sections carry no poles.
        XCTAssertTrue(MapTexture.poleMarkers(try XCTUnwrap(texture.inversePoleFigure), orientations: [SIMD4(1, 0, 0, 0)]).isEmpty)
    }

    @MainActor func testCommandClickAndTheTableSelectSeveralGrains() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        session.setAnalysisSettings(Self.defdap)
        await session.segment().value
        let analysis = try XCTUnwrap(session.analysis)
        let rows = Array(analysis.table.sorted { $0.points > $1.points }.prefix(3))
        func point(of row: GrainRow) -> EBSDPosition {
            let p = analysis.grains.segmentation.grains[row.id - 1].points[0]
            return EBSDPosition(row: p / analysis.columns, column: p % analysis.columns)
        }
        session.pin(point(of: rows[0]))
        XCTAssertEqual(session.selectedGrains, [rows[0].id])
        session.toggleGrain(at: point(of: rows[1]))
        XCTAssertEqual(session.selectedGrains, [rows[0].id, rows[1].id])
        XCTAssertEqual(session.selectedGrain, rows[1].id, "the grain added is the one the Slip section shows")
        XCTAssertEqual(session.selectedOutline.count, analysis.outline(of: Set([rows[0].id, rows[1].id])).count)
        session.toggleGrain(at: point(of: rows[1]))
        XCTAssertEqual(session.selectedGrains, [rows[0].id])
        XCTAssertEqual(session.selectedGrain, rows[0].id)

        session.selectGrains(Set(rows.map(\.id)))
        XCTAssertEqual(session.selectedGrains, Set(rows.map(\.id)))
        XCTAssertEqual(session.selectedRows.map(\.id), rows.map(\.id).sorted())
        session.selectGrains([rows[2].id])
        XCTAssertEqual(session.selectedGrains, [rows[2].id])
        XCTAssertEqual(analysis.grain(atRow: session.pinned.row, column: session.pinned.column), rows[2].id, "one row pins its grain")
        // A plain click goes back to one grain.
        session.pin(point(of: rows[0]))
        XCTAssertEqual(session.selectedGrains, [rows[0].id])
    }

    @MainActor func testTheHistogramExportsAsCSV() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        await session.segment().value
        let state = MapsRoomState()
        state.histogramKind = .gos
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maps-histogram-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var reports: [String] = []
        state.exportHistogram(from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports, ["Exported ebsd-sdss-ferrite-austenite histogram GOS.csv"])
    }

    /// A texture that cannot be made says why in the status line and in the Pole figures and ODF panes, and Compute Texture stays off:
    /// the same map and phase refuse the same way. Red before: the reason was dropped and the line read "No texture for this phase";
    /// then (macTEM#410 review) the pane promised that Compute Texture makes it, and the button was on.
    @MainActor func testATextureThatCannotBeMadeSaysWhy() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        var events: [String] = []
        session.onEvent = { events.append($0) }
        XCTAssertNil(session.document?.map.phases[id: 99], "no phase 99 in the map")
        await session.showTexture(phaseID: 99).value
        XCTAssertNil(session.texture)
        XCTAssertFalse(session.isTexturing)
        let why = "The phase has no point group: no texture."
        XCTAssertEqual(events.last, "No texture for this phase: " + why, "\(events)")
        XCTAssertFalse(session.textureStopped, "not made is not stopped")
        XCTAssertEqual(session.textureFailure, why)
        XCTAssertFalse(session.canComputeTexture, "asking again makes the same refusal")
        let words = MapsRoomFormat.textureUnavailable(stopped: session.textureStopped, failure: session.textureFailure, hasPhases: true)
        XCTAssertEqual(words.title, "No texture")
        XCTAssertEqual(words.detail, why, "the pane says why, and names no Compute Texture")
        XCTAssertEqual(MapsRoomFormat.computeTextureHelp(isTexturing: false, failure: session.textureFailure, canCompute: false), why)

        // Another phase asked for forgets the refusal.
        let phase = try XCTUnwrap(session.texturePhases.first?.id)
        let texturing = session.showTexture(phaseID: phase)
        XCTAssertNil(session.textureFailure)
        XCTAssertEqual(MapsRoomFormat.computeTextureHelp(isTexturing: session.isTexturing, failure: nil, canCompute: false),
                       "The texture is being computed")
        session.stop()
        await texturing.value
        XCTAssertNil(session.textureFailure, "a stop is not a refusal")
        XCTAssertTrue(session.canComputeTexture)
    }

    /// A texture stopped by ⌘. leaves the Pole figures and ODF panes saying so and naming the inspector's Compute Texture, never blank; a
    /// map bound again forgets the stop. Red before (macTEM#410): no flag, no words, and the pane's text was "".
    @MainActor func testAStoppedTexturePaneSaysSoAndHowToComputeItAgain() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        let texturing = session.showTexture()
        XCTAssertTrue(session.isTexturing)
        session.stop()
        await texturing.value
        XCTAssertNil(session.texture)
        XCTAssertTrue(session.textureStopped)

        let stopped = MapsRoomFormat.textureUnavailable(stopped: session.textureStopped, failure: session.textureFailure,
                                                        hasPhases: !session.texturePhases.isEmpty)
        XCTAssertEqual(stopped.title, "Texture stopped")
        XCTAssertEqual(stopped.detail, "Compute Texture in the inspector's Texture section makes it again.")

        let notMade = MapsRoomFormat.textureUnavailable(stopped: false, failure: nil, hasPhases: true)
        XCTAssertEqual(notMade.title, "No texture")
        XCTAssertTrue(notMade.detail.contains("Compute Texture"), notMade.detail)
        let noPhase = MapsRoomFormat.textureUnavailable(stopped: true, failure: nil, hasPhases: false)
        XCTAssertEqual(noPhase.title, "No texture")
        XCTAssertEqual(noPhase.detail, "No indexed phase with a point group.", "nothing to compute, so no Compute Texture")
        for words in [stopped, notMade, noPhase] { XCTAssertFalse(words.title.isEmpty || words.detail.isEmpty) }

        await session.open(url: Self.sdss).value
        XCTAssertFalse(session.textureStopped, "a map bound again forgets the stop")
        XCTAssertTrue(session.canComputeTexture)
    }

    /// #299: the histogram speaks what its bars show: the range, the tallest bin with its count, and the selected grains' ticks.
    /// Red before: the Canvas had a label and no value, so the shape and the ticks were never heard.
    func testTheHistogramSpeaksItsPeakAndTheSelectedGrainsTicks() throws {
        let en = Locale(identifier: "en_US")
        let histogram = AngleHistogram(values: [0.2, 0.6, 0.7, 0.8, 1.9, 3.1], edges: [0, 1, 2, 3, 4])
        XCTAssertEqual(MapsRoomFormat.histogramSpeech(histogram, unit: "°", ticks: [1.2], locale: en),
                       "0 to 4°, most values 0 to 1° (4), selected grain at 1.2°")
        XCTAssertEqual(MapsRoomFormat.histogramSpeech(histogram, unit: "µm", ticks: [1.2, .nan, 2.5], locale: en),
                       "0 to 4 µm, most values 0 to 1 µm (4), selected grains at 1.2 µm, 2.5 µm")
        XCTAssertEqual(MapsRoomFormat.histogramSpeech(AngleHistogram(values: [], edges: [0, 1]), unit: "°", ticks: []), "no values")
        XCTAssertTrue(try FFTRoomWiringTests.squeezedUI("MapsRoomAnalysis.swift")
            .contains(".accessibilityValue(MapsRoomFormat.histogramSpeech(histogram, unit: unit, ticks: ticks))"))
    }

    /// #356: a slip-plane row names the colour its trace is drawn in, so the row and its line on the map match in words, and the
    /// overlay speaks what its colours mean. Red before: "trace 132°" with no colour, and no `colourWord` or `tracesSpeech`.
    func testASlipPlaneRowNamesItsTracesColour() throws {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(MapsRoomFormat.traceText(132 * .pi / 180, colour: "blue", locale: en), "trace 132° in blue")
        XCTAssertEqual(MapsRoomFormat.traceText(30 * .pi / 180, colour: "m", locale: en), "trace 30° in magenta")
        XCTAssertEqual(MapsRoomFormat.traceText(.nan, colour: "green", locale: en), "no trace", "a plane parallel to the map draws no line")
        for name in ["blue", "green", "red", "purple", "orange", "yellow", "cyan", "m", "w", "gray", "brown"] {
            XCTAssertFalse(MapsRoomFormat.colourWord(name).count < 3, name)
        }
        XCTAssertEqual(MapsRoomFormat.colourWord("Purple"), "purple")
        let squeezed = try FFTRoomWiringTests.squeezedUI("MapsRoomAnalysis.swift")
        XCTAssertTrue(squeezed.contains("MapsRoomFormat.tracesSpeech(slip.planes)"), "the overlay speaks the traces")
        XCTAssertTrue(squeezed.contains("grain boundaries white, phase boundaries black"), "and what the boundary colours mean")
    }
}
