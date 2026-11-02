//
//  EELSRoomStatesTests.swift
//  The EELS room's states: a single spectrum (a 1 x 1 file) and the stage state on the Processing and Fitting titles.
//
//  THE TRUTH: the planted spectrum image of `EELSRoomTests` (a 4 x 3 low loss) and its first pixel alone as a 1 x 1 file, each with the planted core loss of
//  `EELSControlsTests` (C K, N K and O K) cut to the same scan. A single spectrum shows the spectrum and its results only, as the EDS room's `isSingleSpectrum`;
//  the stages' states are the session's (`EELSStageState`), the section's state the one rule `EELSStageState.section`.
//

import XCTest
import AppKit
import SwiftUI
import SpectroEELS
import TEMCore
import TEMSession
import ShellEDXModel
@testable import macTEM

nonisolated final class EELSRoomStatesTests: XCTestCase {

    /// The planted file, or its first pixel alone (1 x 1), with the planted core loss cut to the same scan.
    static func loaded(single: Bool) throws -> LoadedEELS {
        let image = try EELSRoomTests.image(), core = try EELSControlsTests.core()
        guard single else {
            return LoadedEELS(fileName: "grid.dm4", image: image, beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10, origin: "planted",
                              coreLoss: core, coreLossOrigin: "planted core")
        }
        let low = try LowLossSpectrumImage(nx: 1, ny: 1, channels: image.channels, counts: Array(image.counts.prefix(image.channels)),
                                           energyOffsetEV: image.energyOffsetEV, energyScaleEV: image.energyScaleEV)
        let oneCore = try CoreLossSpectrumImage(nx: 1, ny: 1, channels: core.channels, counts: Array(core.counts.prefix(core.channels)),
                                                energyOffsetEV: core.energyOffsetEV, energyScaleEV: core.energyScaleEV)
        return LoadedEELS(fileName: "point.dm4", image: low, beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10, origin: "planted",
                          coreLoss: oneCore, coreLossOrigin: "planted core")
    }

    @MainActor private func room(single: Bool) async throws -> EELSSession {
        let session = EELSSession()
        await session.bind(try Self.loaded(single: single)).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        return session
    }

    /// The height a view takes in an inspector column: 0 when it draws nothing.
    @MainActor private func height(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 300))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: Single spectrum

    /// A 1 x 1 file is a single spectrum: its spectrum is named "Spectrum", its thickness and results are made as for any file, and the inspector has no Maps
    /// and no Tools section. A 4 x 3 file keeps both. Red under: a 1 x 1 file drawn as a one-pixel map with the Maps and Tools controls.
    @MainActor func testAOneByOneFileShowsOnlyTheSpectrumAndItsResults() async throws {
        let single = try await room(single: true)
        XCTAssertTrue(single.isSingleSpectrum)
        XCTAssertNotNil(single.map, single.failure ?? "no thickness for the single spectrum")
        XCTAssertEqual(single.plot?.regionName, "Spectrum")
        let singleState = EELSRoomState()
        XCTAssertEqual(height(EELSMapsSection(session: single, state: singleState)), 0, "no Maps section")
        XCTAssertEqual(height(EELSToolsSection(session: single, state: singleState)), 0, "no Tools section")

        let grid = try await room(single: false)
        XCTAssertFalse(grid.isSingleSpectrum)
        XCTAssertEqual(grid.plot?.regionName, "Whole map")
        let gridState = EELSRoomState()
        XCTAssertGreaterThan(height(EELSMapsSection(session: grid, state: gridState)), 20, "the Maps section")
        XCTAssertGreaterThan(height(EELSToolsSection(session: grid, state: gridState)), 20, "the Tools section")

        XCTAssertFalse(EELSSession().isSingleSpectrum, "no file is no single spectrum")
    }

    // MARK: Stage state on the titles

    /// The section rule: stale wins (a result on screen that Run would change), then not run, else current; no stage, no state. Red under: no state.
    func testASectionsStateIsItsStagesWorst() {
        XCTAssertNil(EELSStageState.section([]))
        XCTAssertEqual(EELSStageState.section([.current]), .current)
        XCTAssertEqual(EELSStageState.section([.current, .current]), .current)
        XCTAssertEqual(EELSStageState.section([.current, .notRun]), .notRun)
        XCTAssertEqual(EELSStageState.section([.notRun, .stale]), .stale)
        XCTAssertEqual(EELSStageState.section([.stale, .current]), .stale)
        XCTAssertEqual(EELSSectionStatus.glyph(.stale).map { _ in true }, true)
        XCTAssertNil(EELSSectionStatus.glyph(nil))
    }

    /// Processing reads Thickness (and Deconvolve while a method is chosen), Fitting reads Fit: after opening, Processing is current and Fitting not run;
    /// after a fit both are current; a change of model stales Fitting and leaves Processing current; a new threshold before the map is remade stales
    /// Processing. Red under: no state on either title.
    @MainActor func testTheProcessingAndFittingTitlesCarryTheirStagesState() async throws {
        let session = try await room(single: false)
        XCTAssertEqual(session.processingState, .current)
        XCTAssertEqual(session.fittingState, .notRun)

        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        await session.fit()?.value
        await session.settled()
        XCTAssertNotNil(session.model, session.failure ?? session.fitRefusal ?? "no fit")
        XCTAssertEqual(session.fittingState, .current)
        XCTAssertEqual(session.processingState, .current)

        session.setFitModel(session.fitModel == .mlls ? .exactNNLS : .mlls)
        XCTAssertEqual(session.fittingState, .stale)
        XCTAssertEqual(session.processingState, .current)

        session.setDeconvolution(.make(.richardsonLucy, iterations: 15))
        XCTAssertNotEqual(session.deconvolveState, .current, "a method chosen and not yet run")
        XCTAssertEqual(session.processingState, session.deconvolveState, "Deconvolve joins the section while a method is chosen")
    }

    // MARK: The picture

    /// The single-spectrum room (the spectrum and its results) beside its inspector (Processing and Fitting with their state on the title, no Maps or Tools),
    /// rendered offscreen. Writes `macTEM-98a.png` when MACEM_SHOT_DIR is set (TEST_RUNNER_MACEM_SHOT_DIR); otherwise only checks that it renders.
    @MainActor func testTheSingleSpectrumRoomRendersOffscreen() async throws {
        let session = try await room(single: true)
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        await session.fit()?.value
        await session.settled()
        session.setFitModel(session.fitModel == .mlls ? .exactNNLS : .mlls)   // Fitting stale, Processing current: two symbols on the titles
        let state = EELSRoomState()
        let view = HStack(alignment: .top, spacing: 0) {
            EELSLowerPane(session: session, state: state).frame(width: 760, height: 560)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    EELSMapsSection(session: session, state: state)
                    EELSToolsSection(session: session, state: state)
                    EELSProcessingSection(session: session)
                    EELSFittingSection(session: session)
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 320, height: 560)
        }
        let canvas = NSSize(width: 1081, height: 560)
        let host = NSHostingView(rootView: view.frame(width: canvas.width, height: canvas.height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-98a.png"))
    }
}
