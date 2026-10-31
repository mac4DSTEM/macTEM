//
//  EELSOpeningTests.swift
//  The EELS room's document: every EELS cube of a file is read and gets its role by its energy window (a window that holds 0 eV is the low
//  loss, one that starts above it the core loss), so a Dual-EELS file opens with both. The real Velox example (3 cubes) is read from References.
//

import ShellLayout
import XCTest
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSOpeningTests: XCTestCase {

    private func reference(_ relative: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [root.appendingPathComponent("References/\(relative)"), root.deletingLastPathComponent().appendingPathComponent("References/\(relative)")]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("\(relative) is not in the data folder ($MACEM_DATA)")
        }
        return url
    }

    /// The Velox example holds three EELS cubes (EDS + EELS, dual): the low loss is the one holding 0 eV and the core loss, when one starts above it,
    /// rides along on the same scan. Red under: the first cube taken whatever it is; a core loss that does not share the scan.
    func testTheVeloxExampleOpensWithItsLowLossAndItsCoreLoss() throws {
        let url = try reference("mac4DSTEM/velox-parity/velox_EELS_EDS/example_velox_EELS_EDS.emd")
        let loaded = try EELSOpening.open(url: url)
        let low = loaded.image
        XCTAssertEqual([low.nx, low.ny, low.channels], [20, 16, 2048])
        XCTAssertEqual(low.energyOffsetEV, -21.5026, accuracy: 1e-3)
        XCTAssertEqual(low.energyScaleEV, 0.1692, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(low.energyOffsetEV, 0)
        XCTAssertGreaterThanOrEqual(low.energy(ofChannel: low.channels - 1), 0, "the low loss holds the zero-loss peak")
        let core = try XCTUnwrap(loaded.coreLoss, "the example is Dual-EELS: a core loss starts at 800 eV")
        XCTAssertEqual(core.energyOffsetEV, 800, accuracy: 1e-6)
        XCTAssertEqual(core.energyScaleEV, low.energyScaleEV, accuracy: 1e-9)
        XCTAssertEqual(core.nx, low.nx); XCTAssertEqual(core.ny, low.ny)
        XCTAssertNotNil(loaded.coreLossOrigin)
    }

    // MARK: The pipeline (Align, then Thickness)

    /// A 4 x 3 low loss like `EELSRoomTests`' planted one but with the zero-loss peak at channel 10 + (k % 3) in pixel k: Align must bring the
    /// three positions to one, and the thickness read from the aligned cube is the planted one (the tail moves with the peak).
    static func shiftedImage() throws -> LowLossSpectrumImage {
        let nx = 4, ny = 3, channels = 256
        var counts = [Double](repeating: 0, count: nx * ny * channels)
        for k in 0..<(nx * ny) {
            let base = k * channels, s = k % 3
            counts[base + 9 + s] = 300; counts[base + 10 + s] = 1400; counts[base + 11 + s] = 300
            let tail = 2000 * (exp(EELSRoomTests.planted(k)) - 1) / 100
            for c in 30..<130 { counts[base + c + s] = tail }
        }
        return try LowLossSpectrumImage(nx: nx, ny: ny, channels: channels, counts: counts, energyOffsetEV: -5, energyScaleEV: 0.5)
    }

    func testTheAlignmentReadout() {
        XCTAssertEqual(EELSRoomFormat.alignmentReadout(offsetBefore: -21.5026, offsetAfter: -0.0001, kept: 2041, of: 2048, locale: Locale(identifier: "en_US")),
                       "offset -21.5 → 0 eV, 2041 of 2048 channels kept")
    }

    /// Red under: Align not run by Run; the thickness not recomputed on the aligned cube (it stays stale); the before tile missing.
    @MainActor func testRunAlignsThenMapsTheThicknessAndTheStagesSaySo() async throws {
        let session = EELSSession()
        let loaded = LoadedEELS(fileName: "shifted.dm4", image: try Self.shiftedImage(), beamEnergyKeV: nil, convergenceMrad: 0, collectionMrad: 10, origin: "planted")
        session.bind(loaded)
        await session.settled()
        XCTAssertEqual(session.alignState, .notRun)
        XCTAssertEqual(session.thicknessState, .current, "the map on open is of the raw cube")
        XCTAssertTrue(session.canRun, "Align has not run")
        let before = try XCTUnwrap(session.map)
        let zlpBefore = Set(before.pixels.map { Int(($0.zlpCentreEV * 10).rounded()) })
        XCTAssertGreaterThan(zlpBefore.count, 1, "the peaks sit at different energies before Align")

        await session.run().value
        await session.settled()
        XCTAssertEqual(session.alignState, .current)
        XCTAssertEqual(session.thicknessState, .current, "recomputed on the aligned cube")
        XCTAssertFalse(session.canRun, "every stage is current")
        let after = try XCTUnwrap(session.map)
        XCTAssertEqual(Set(after.pixels.map { Int(($0.zlpCentreEV * 10).rounded()) }).count, 1, "one energy after Align")
        XCTAssertEqual(after.pixels.map(\.zlpCentreEV).map { abs($0) }.max() ?? 1, 0, accuracy: 1e-9, "recalibrated: the peak is at 0 eV")
        XCTAssertNotNil(session.alignmentReadout)
        let ids = session.displayedTiles.map(\.id)
        XCTAssertEqual(ids, ["tOverLambda", "zlpCentreBefore", "zlpCentre", "i0", "iTotal"])
        let tile = try XCTUnwrap(session.displayedTiles.first { $0.id == "zlpCentreBefore" })
        XCTAssertEqual(Set(tile.values.map { ($0 * 10).rounded() }).count, 3, "the before tile shows the three planted positions")
        XCTAssertEqual(session.stages.map(\.state), [.current, .current, .notRun, .notRun], "Edges and Fit have not been asked for")
    }

    /// The toolbar's verb: Run for the EELS room once a cube is open, enabled while a stage is not current, Cancel while it runs.
    @MainActor func testTheEELSRoomHasRunAsItsVerb() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .eels
        XCTAssertNil(RoomPrimaryAction.current(state), "no cube: no verb")
        let loaded = LoadedEELS(fileName: "shifted.dm4", image: try Self.shiftedImage(), beamEnergyKeV: nil, convergenceMrad: 0, collectionMrad: 10, origin: "planted")
        state.eels.bind(loaded)
        await state.eels.settled()
        let action = try XCTUnwrap(RoomPrimaryAction.current(state))
        XCTAssertEqual(action.title, "Run")
        XCTAssertTrue(action.isEnabled)
        XCTAssertTrue(action.help.contains("Align"), action.help)
    }

    // MARK: The edge model on the real Dual-EELS example

    /// Align the Velox example, offer the edges its core loss (800 to 1146 eV) can hold, pick them, type the microscope and fit: every stage lands,
    /// the stages say so, the maps and the region table exist. Red under: Fit not run by Run; the stage left stale; no region table.
    @MainActor func testTheVeloxExampleFitsItsEdgesThroughRun() async throws {
        let url = try reference("mac4DSTEM/velox-parity/velox_EELS_EDS/example_velox_EELS_EDS.emd")
        let session = EELSSession()
        session.bind(try EELSOpening.open(url: url))
        await session.settled()
        let offered = session.offeredEdges
        XCTAssertFalse(offered.isEmpty, "a 800 to 1146 eV core loss holds a bundled edge")
        XCTAssertTrue(offered.allSatisfy { $0.onsetEV >= 810 && $0.onsetEV < 1146 }, "\(offered.map(EELSFitCompute.title))")
        XCTAssertNotNil(session.fitBlocker, "no edge picked yet")
        // The edges of the elements this test was written on (Fe, Cu): since SpectroKit 0.12.0 the window offers many more (Ba, Ce, Ni …).
        offered.filter { ["C", "N", "O", "Mg", "Al", "Si", "Fe", "Cu"].contains($0.element) }.forEach { session.toggleEdge($0) }
        XCTAssertEqual(session.fitBlocker, "Type the beam energy and the convergence and collection angles under Fitting.")
        session.setBeamEnergy(300); session.setConvergence(10); session.setCollection(20)
        XCTAssertNil(session.fitBlocker)
        XCTAssertTrue(session.canRun)
        await session.run().value
        await session.settled()
        XCTAssertEqual(session.stages.map(\.state), [.current, .current, .current, .current], session.failure ?? "")
        let model = try XCTUnwrap(session.model, session.failure ?? "no model")
        XCTAssertEqual(model.validation, "none")
        XCTAssertEqual(model.nx * model.ny, 20 * 16)
        XCTAssertEqual(session.modelTiles.filter { $0.id.hasPrefix("edge-") }.count, model.edges.count)
        let rows = session.regionRows
        XCTAssertEqual(rows.count, model.edges.count)
        XCTAssertTrue(rows.contains { ($0.intensity ?? 0) > 0 }, "the summed region has a positive edge: \(rows)")
        // Changing a pick makes the fit stale and Run enabled again; the result stays on screen.
        session.toggleEdge(offered[0])
        XCTAssertEqual(session.fitState, .stale)
        XCTAssertNotNil(session.model)
        XCTAssertTrue(session.canRun || session.fitBlocker != nil)
    }
}
