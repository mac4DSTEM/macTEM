//
//  EELSResultsRowsTests.swift
//  The EELS results pane keeps every quantified edge in view when a region is drawn (the edges table and the regions table share the pane), and the
//  Fitting section's Fit to reads as a word without a unit while the exact fit uses its own signal windows.
//
//  THE TRUTH: the planted low and core loss of `EELSControlsTests` (C K, N K and O K on a power law) on the 4 x 3 image of `EELSRoomTests`. No numbers
//  are checked here: this is layout and words only.
//

import XCTest
import AppKit
import SwiftUI
import SpectroEDX
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM
import ShellEDXModel

nonisolated final class EELSResultsRowsTests: XCTestCase {

    @MainActor private func fittedRoomWithARegion() async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "rows.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        XCTAssertNotNil(session.map, session.failure ?? "no map")
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2)))
        await session.fit()?.value
        await session.settled()
        return session
    }

    @MainActor private func host(_ view: some View, size: NSSize) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    @MainActor private func save(_ host: NSView, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// The edges table's floor: a header, every edge's row and the room for a horizontal scroll bar, up to six rows (more scroll).
    func testTheEdgesTableFloorHoldsItsRowsUpToACap() {
        let m = EELSResultsLayout.self
        XCTAssertEqual(m.edgesTableMinimumHeight(rows: 3), m.tableHeaderHeight + 3 * m.tableRowHeight + m.scrollBarAllowance)
        XCTAssertEqual(m.edgesTableMinimumHeight(rows: 6), m.tableHeaderHeight + 6 * m.tableRowHeight + m.scrollBarAllowance)
        XCTAssertEqual(m.edgesTableMinimumHeight(rows: 9), m.edgesTableMinimumHeight(rows: 6), "capped at six rows")
        XCTAssertEqual(m.edgesTableMinimumHeight(rows: 0), m.edgesTableMinimumHeight(rows: 1))
    }

    /// Three fitted edges and one region in a results pane the size of the drive's (about 300 x 282 pt): the edges table shows all three rows whole,
    /// clear of a horizontal scroll bar, and the regions table still shows its row. Red under: the edges table squeezed to a row and a half by the
    /// regions table (the drive's EELS_2_14 and EELS_3_14).
    @MainActor func testThreeEdgesAndARegionAllShow() async throws {
        let session = try await fittedRoomWithARegion()
        XCTAssertEqual(session.resultRows.count, 3, session.failure ?? session.fitRefusal ?? "")
        XCTAssertEqual(session.pinRows.count, 1)
        let size = NSSize(width: 300, height: 282)
        let host = host(EELSResultsPanel(session: session), size: size)
        try save(host, "macTEM-rowsfitto-results.png")
        let found = tables(in: host)
        let edges = try XCTUnwrap(found.first { $0.numberOfColumns == 4 }, "the edges table")
        XCTAssertEqual(edges.numberOfRows, 3)
        let scroll = try XCTUnwrap(edges.enclosingScrollView)
        let visible = scroll.documentVisibleRect
        let last = edges.rect(ofRow: 2)
        XCTAssertGreaterThanOrEqual(visible.maxY - last.maxY, EELSResultsLayout.scrollBarAllowance - 1,
                                    "the last edge row clears the scroll bar: visible \(visible), last row \(last)")
        XCTAssertLessThanOrEqual(visible.minY, edges.rect(ofRow: 0).minY, "the first row is whole")
        let pane = host.convert(scroll.bounds, from: scroll)
        XCTAssertGreaterThanOrEqual(pane.minY, -0.5); XCTAssertLessThanOrEqual(pane.maxY, size.height + 0.5, "inside the pane")
        // The regions grid (a scroll view of its own, not the edges table's) keeps at least its header and one row.
        let regions = try XCTUnwrap(scrollViews(in: host).first { $0 !== scroll && $0.documentView as? NSTableView == nil }, "the regions grid")
        XCTAssertGreaterThanOrEqual(regions.frame.height, EELSResultsLayout.regionsTableMinimumHeight - 8, "the region row shows: \(regions.frame)")
    }

    /// Fit to: under MLLS a number in eV; under the exact fit the full word, no unit, and the reason in the help. Red under: "Signal win" with "eV".
    func testFitToReadsAsAWordWithoutAUnitUnderTheExactFit() {
        let exact = EELSFitToField.shown(.exactNNLS)
        XCTAssertEqual(exact.word, "signal windows")
        XCTAssertNil(exact.unit)
        XCTAssertTrue(exact.help.hasPrefix("Off: "), exact.help)
        XCTAssertTrue(exact.help.contains("signal window"), exact.help)
        let mlls = EELSFitToField.shown(.mlls)
        XCTAssertNil(mlls.word)
        XCTAssertEqual(mlls.unit, "eV")
        XCTAssertFalse(mlls.help.hasPrefix("Off"), mlls.help)
    }

    /// The Fitting section drawn offscreen in both models, for the pull request (`MACEM_SHOT_DIR`); the exact fit's row shows the word whole: the
    /// row's text field fits it without clipping. Red under: a field the numeric width that clips the word.
    @MainActor func testTheFitToRowDrawsInBothModels() async throws {
        let session = try await fittedRoomWithARegion()
        let size = NSSize(width: 320, height: 520)
        let exact = host(ScrollView { EELSFittingSection(session: session).padding(.horizontal, 12) }, size: size)
        try save(exact, "macTEM-rowsfitto-fitting-exact.png")
        let field = try XCTUnwrap(fields(in: exact).first { $0.stringValue == "signal windows" }, "the word is the field's text")
        XCTAssertFalse(field.isEnabled)
        XCTAssertGreaterThanOrEqual(field.frame.width + 0.5, field.intrinsicContentSize.width, "the word is not clipped")
        session.setFitModel(.mlls)
        let mlls = host(ScrollView { EELSFittingSection(session: session).padding(.horizontal, 12) }, size: size)
        try save(mlls, "macTEM-rowsfitto-fitting-mlls.png")
        XCTAssertNil(fields(in: mlls).first { $0.stringValue == "signal windows" })
    }

    @MainActor private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
}
