//
//  EELSMapsStatusTests.swift
//  The EELS room's Maps status line: while a stage makes maps, "Computing … maps" with a spinner under the Maps control, as the EDS room's.
//
//  THE TRUTH: the planted spectrum image of `EELSRoomTests` with the planted core loss of `EELSControlsTests`. The line names the maps the running stage
//  makes (`EELSMapsSegment.status`); the stage is the session's `computingStage`, set while its pass runs and cleared when it lands.
//

import XCTest
import AppKit
import SwiftUI
import SpectroEELS
import TEMCore
import TEMSession
import ShellEDXModel
@testable import macTEM

nonisolated final class EELSMapsStatusTests: XCTestCase {

    @MainActor private func room() async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "status.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        return session
    }

    /// The words: each map-making stage names its maps as the Maps control does, the picked segment where the stage makes it; Deconvolve makes no map;
    /// nothing running, no line. Red under: no line while a stage runs.
    func testTheStatusLineNamesTheMapsTheStageMakes() {
        for segment in EELSMapsSegment.allCases { XCTAssertNil(EELSMapsSegment.status(computing: nil, selection: segment), segment.title) }
        XCTAssertEqual(EELSMapsSegment.status(computing: .thickness, selection: .tOverLambda), "Computing t/λ maps…")
        XCTAssertEqual(EELSMapsSegment.status(computing: .thickness, selection: .thickness), "Computing t maps…")
        XCTAssertEqual(EELSMapsSegment.status(computing: .thickness, selection: .atomicPercent), "Computing t/λ maps…")
        XCTAssertEqual(EELSMapsSegment.status(computing: .align, selection: .tOverLambda), "Computing ZLP maps…")
        XCTAssertEqual(EELSMapsSegment.status(computing: .fit, selection: .weightPercent), "Computing wt% maps…")
        XCTAssertEqual(EELSMapsSegment.status(computing: .fit, selection: .atomicPercent), "Computing at% maps…")
        XCTAssertEqual(EELSMapsSegment.status(computing: .fit, selection: .tOverLambda), "Computing edge maps…")
        XCTAssertNil(EELSMapsSegment.status(computing: .deconvolve, selection: .tOverLambda), "Deconvolve makes no map")
    }

    /// The session names the running stage while its pass runs and clears it when the pass lands: a new threshold remakes the thickness map, a fit the edge
    /// maps. Red under: no stage named while the pass runs.
    @MainActor func testTheSessionNamesTheStageWhileItsPassRuns() async throws {
        let session = try await room()
        XCTAssertNil(session.computingStage)
        session.setThreshold(.fixed(3))
        XCTAssertTrue(session.isComputing)
        XCTAssertEqual(session.computingStage, .thickness)
        await session.settled()
        XCTAssertFalse(session.isComputing)
        XCTAssertNil(session.computingStage, "cleared when the map lands")

        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        let fit = session.fit()
        XCTAssertEqual(session.computingStage, .fit)
        await fit?.value
        await session.settled()
        XCTAssertNil(session.computingStage)

        session.setThreshold(.fixed(2.5))
        session.stop()
        XCTAssertNil(session.computingStage, "Stop clears it")
    }

    /// The Maps section while the thickness map is remade (the status line and its spinner under the control), rendered offscreen. Writes `macTEM-98b.png`
    /// when MACEM_SHOT_DIR is set (TEST_RUNNER_MACEM_SHOT_DIR); otherwise only checks that it renders.
    @MainActor func testTheMapsStatusLineRendersOffscreen() async throws {
        let session = try await room()
        let state = EELSRoomState()
        session.setThreshold(.fixed(3))
        XCTAssertNotNil(EELSMapsSegment.status(computing: session.computingStage, selection: session.mapsAvailability.effective(state.maps)))
        let view = ScrollView { EELSMapsSection(session: session, state: state).padding(.horizontal, 12) }.frame(width: 320, height: 200).padding(12)
        let canvas = NSSize(width: 344, height: 224)
        let host = NSHostingView(rootView: view.frame(width: canvas.width, height: canvas.height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        await session.settled()
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-98b.png"))
    }
}
