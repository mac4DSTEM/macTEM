//
//  EELSRunStopTests.swift
//  Stop ends the EELS room's whole Run, not only the stage in flight: Run chains the stages that are not current (Align, Thickness, Deconvolve,
//  Fit), and a stage that was stopped must not hand over to the next one.
//
//  THE ROOM: the planted spectrum image of `EELSRoomTests` with the planted core loss of `EELSControlsTests` and a fixed 2.5 eV threshold, so the
//  thickness map is current after the open. With C K, N K and O K picked and Fourier-log chosen, Align, Deconvolve and Fit are pending and nothing
//  blocks the fit.
//

import XCTest
import SpectroEELS
import TEMCore
import TEMSession
import ShellEDXModel
@testable import macTEM

nonisolated final class EELSRunStopTests: XCTestCase {

    /// Stop while Align runs ends the Run there: Deconvolve and Fit never start (their results stay nil), the stopped alignment does not land, and
    /// the room is idle with no failure. The Stop comes before Align can land: the chain's first stage and the Stop both run on the main actor,
    /// where a landing waits its turn. Red under: the chain guarded only by `failure == nil`, which ran Fourier-log and then the fit after the Stop.
    @MainActor func testStopEndsTheWholeRunNotOnlyTheStageInFlight() async throws {
        let loaded = LoadedEELS(fileName: "run-stop.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        XCTAssertNotNil(session.map, session.failure ?? "no map")
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        session.setDeconvolution(.fourierLog)
        XCTAssertNil(session.fitBlocker, "the fit can run")
        XCTAssertEqual(session.stages.map(\.stage), [.align, .thickness, .deconvolve, .edges, .fit])
        XCTAssertEqual(session.stages.map(\.state), [.notRun, .current, .notRun, .current, .notRun], "Align, Deconvolve and Fit are pending")
        XCTAssertTrue(session.canRun)

        let run = session.run()
        // Yields, not the shared wait's 5 ms sleeps, in which Align could land before the Stop; the assertion below fails if it never starts.
        var turns = 0
        while !session.isComputing, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        XCTAssertEqual(session.computingStage, .align, "Align is in flight")
        session.stop()
        await run.value
        await session.settled()

        XCTAssertNil(session.deconvolution, "Deconvolve started after the Stop")
        XCTAssertNil(session.model, "Fit started after the Stop")
        XCTAssertNil(session.alignment, "the stopped alignment does not land")
        XCTAssertFalse(session.isComputing)
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.stages.map(\.state), [.notRun, .current, .notRun, .current, .notRun], "the pending stages are still pending")
    }
}
