//
//  EELSFitNotesTests.swift
//  The EELS results footer as the EDS room's: "n notes · fit quality", and a click opens everything the fit says about its own numbers. Each note is a
//  sentence the room already writes elsewhere (the table's marks, the CSV, the Deconvolve readout, the Fitting section's refusals), grouped here.
//
//  THE TRUTH: planted rows with each flag the kit or the session can raise (an exponent on a bound, an edge at or under 3σ, an MLLS amount ≤ 0, an edge
//  the kit left with no answer, a composition refused), planted per-pixel reasons for the deconvolution, and the planted C K, N K, O K session of
//  `EELSControlsTests` fitted by MLLS.
//

import XCTest
import AppKit
import SwiftUI
import SpectroCore
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSFitNotesTests: XCTestCase {

    private static func row(_ title: String, intensity: Double? = 100, std: Double? = 1, atomic: Double? = 50, unavailable: String? = nil,
                            atomicUnavailable: String? = nil, atBound: Bool = false, fitOnly: Bool = false, notDetected: Bool = false) -> EELSEdgeRow {
        EELSEdgeRow(id: title, title: title, onsetEV: 300, intensity: intensity, arealDensityPerNM2: nil, atomicPercent: atomic, weightPercent: atomic,
                    exponent: 3, unavailable: unavailable, intensityStd: std, atomicUnavailable: atomicUnavailable, exponentAtBound: atBound,
                    fitOnly: fitOnly, notDetected: notDetected)
    }

    /// Every flag becomes its one sentence, in a fixed order: the refused picks, the edges with no answer, the composition's refusal, the exponent on a
    /// bound (once: the kit flags the fit), each edge under 3σ, the MLLS not-detected elements, the deconvolution's unanswered pixels. A fit-only
    /// edge's at% is a choice, not a note. Red under: no `fitNotes`; a flag dropped or said twice.
    func testTheNotesAreTheFitsOwnSentencesGrouped() {
        let unavailable: [EELSUnavailable?] = [nil, .nonFiniteResult, .noThreshold, .nonFiniteResult]
        let rows = [
            Self.row("C K", atBound: true),
            Self.row("N K", atomic: 0, atBound: true, notDetected: true),
            Self.row("O K", intensity: 2, std: 1, atBound: true),
            Self.row("Fe L3", intensity: nil, std: nil, atomic: nil, unavailable: "the edge model could not be fitted", atomicUnavailable: "no composition here"),
            Self.row("Cu L3", atomic: nil, atomicUnavailable: EELSEdgeRow.fitOnlyWords, fitOnly: true),
        ]
        let refused = "Ti L3: its signal window sits on a stretch with no counts."
        let notes = EELSRoomFormat.fitNotes(rows: rows, refusals: [refused], unanswered: unavailable)
        XCTAssertEqual(notes, [
            refused,
            "Fe L3: the edge model could not be fitted",
            "at% not computed: no composition here",
            ResultRow.eelsExponentAtBound,
            "O K " + ResultRow.eelsBelowDetection,
            "N " + EELSEdgeRow.notDetectedWords,
            "deconvolution: " + (EELSDeconvolveCompute.unansweredLine(unavailable) ?? "?"),
        ])
        XCTAssertEqual(notes[4], "O K below detection: I is at or under 3σ, the edge is not detected in this region")
        XCTAssertEqual(EELSRoomFormat.fitNotes(rows: [Self.row("C K"), Self.row("O K")], refusals: [], unanswered: nil), [], "a clean fit has no notes")
        XCTAssertEqual(EELSRoomFormat.fitNotes(rows: [Self.row("C K")], refusals: [], unanswered: [nil, nil]), [])
    }

    /// The footer line: "2 notes · χ²/dof … · Pearson", "1 note · …", and the quality alone with no note; with no quality, the method line. Red under: the
    /// old "model · background · …" footer.
    func testTheFooterSaysHowManyNotesAndTheFitQuality() {
        let en = Locale(identifier: "en_US")
        let q = EELSFitQuality(rss: 1234, channels: 100, parameters: 4, reducedChiSquared: 1.04)
        let quality = EELSRoomFormat.fitQuality(q, locale: en)
        XCTAssertEqual(EELSRoomFormat.fitNotesSummary(notes: 2, quality: quality), "2 notes · " + quality)
        XCTAssertEqual(EELSRoomFormat.fitNotesSummary(notes: 1, quality: quality), "1 note · " + quality)
        XCTAssertEqual(EELSRoomFormat.fitNotesSummary(notes: 0, quality: quality), quality)
    }

    @MainActor private func fitted(_ model: EELSFitModel) async throws -> EELSSession { try await Self.fittedSession(model) }

    /// The planted C K, N K, O K session of `EELSControlsTests`, fitted by `model` with no low-loss convolution.
    @MainActor static func fittedSession(_ model: EELSFitModel) async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "notes.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        session.setFitModel(model)
        await session.fit()?.value
        await session.settled()
        XCTAssertEqual(session.fitState, .current, session.failure ?? session.fitRefusal ?? "")
        return session
    }

    /// The session's notes are the format's on the rows on screen, its refusals and the fit's deconvolution; a composition left with one quantified
    /// element says why. The results and regions CSVs are the same with the notes as without (the notes are words on screen only). Red under: no
    /// `EELSSession.fitNotes`.
    @MainActor func testTheSessionNotesComeFromWhatItReports() async throws {
        let session = try await fitted(.mlls)
        let csv = session.resultsCSV
        XCTAssertEqual(session.fitNotes, EELSRoomFormat.fitNotes(rows: session.resultRows, refusals: session.refusals.map(\.reason),
                                                                 unanswered: session.modelDeconvolution?.unavailable))
        session.setFitOnly("N", true); session.setFitOnly("O", true)
        XCTAssertTrue(session.fitNotes.contains("at% not computed: " + EELSEdgeRow.atomicNeedsTwoQuantified), "\(session.fitNotes)")
        session.setFitOnly("N", false); session.setFitOnly("O", false)
        XCTAssertEqual(session.resultsCSV, csv, "the notes move no number and no CSV line")
    }

    /// The results panel and the notes popover's list drawn offscreen (a borderless window that is never shown) after an exact fit. The picture goes to
    /// `MACEM_SHOT_DIR` when the runner sets it. Red under: a panel or a list that does not draw.
    @MainActor func testThePanelAndTheNotesDraw() async throws {
        let session = try await fitted(.exactNNLS)
        func render(_ view: some View, size: NSSize) throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        let notes = session.fitNotes + [ResultRow.eelsExponentAtBound, "O K " + ResultRow.eelsBelowDetection]
        let panel = try render(EELSResultsPanel(session: session), size: NSSize(width: 560, height: 300))
        let list = try render(EELSFitNotesList(notes: notes, quality: session.resultQuality.map { EELSRoomFormat.fitQualityText($0) },
                                               method: session.fitFooter, methodNames: [session.model?.methodName].compactMap { $0 }),
                              size: NSSize(width: 360, height: 280))
        XCTAssertGreaterThan(panel.pixelsWide, 0); XCTAssertGreaterThan(list.pixelsWide, 0)
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        for (name, rep) in [("macTEM-98-notes-panel.png", panel), ("macTEM-98-notes-popover.png", list)] {
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
