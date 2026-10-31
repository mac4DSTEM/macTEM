//
//  BusyOperationTests.swift
//  The toolbar's busy line names the work that is running (`BusyOperation`), never the last status sentence: during Quantify it read
//  "Opened … · 4096 channels", because the fit sets no sentence when it starts.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class BusyOperationTests: XCTestCase {
    private let opened = "Opened map.emd — 1024 × 1024 px, 4096 channels"

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// With the EDS room busy fitting (a Quantify: the fit runs inside a refresh), the operation is the fit, not the open line. Red under:
    /// the busy line taking the status sentence.
    func testAQuantifyIsNamedNotTheOpenLine() {
        let name = BusyOperation.edx(opening: false, openSentence: opened, fitting: true, checking: false, identifying: false, mapping: false, refreshing: true)
        XCTAssertEqual(name, "Quantifying…")
    }

    /// Each EDS busy flag has its own name; idle has none.
    func testEachEDSWorkHasItsName() {
        func edx(fit: Bool = false, check: Bool = false, id: Bool = false, maps: Bool = false, refresh: Bool = false) -> String? {
            BusyOperation.edx(opening: false, openSentence: opened, fitting: fit, checking: check, identifying: id, mapping: maps, refreshing: refresh)
        }
        XCTAssertEqual(edx(check: true), "Checking for unlisted lines…")
        XCTAssertEqual(edx(id: true), "Identifying elements…")
        XCTAssertEqual(edx(maps: true), "Computing the composition maps…")
        XCTAssertEqual(edx(refresh: true), "Updating the spectrum and maps…")
        XCTAssertNil(edx())
    }

    /// An open keeps the sentence it sets as it starts ("Opening <file>…"); a stale one is not taken for it.
    func testAnOpenKeepsItsOwnSentence() {
        XCTAssertEqual(BusyOperation.edx(opening: true, openSentence: "Opening map.emd…", fitting: false, checking: false, identifying: false,
                                         mapping: false, refreshing: false), "Opening map.emd…")
        XCTAssertEqual(BusyOperation.edx(opening: true, openSentence: opened, fitting: false, checking: false, identifying: false,
                                         mapping: false, refreshing: false), "Opening the spectrum image…")
        XCTAssertEqual(BusyOperation.eels(opening: true, openSentence: opened, computing: false, stage: nil), "Opening the spectrum image…")
    }

    /// The EELS room names the stage its pass computes.
    func testTheEELSStageIsNamed() {
        XCTAssertEqual(BusyOperation.eels(opening: false, openSentence: opened, computing: true, stage: .align), "Aligning the zero-loss peak…")
        XCTAssertEqual(BusyOperation.eels(opening: false, openSentence: opened, computing: true, stage: .thickness), "Mapping the thickness…")
        XCTAssertEqual(BusyOperation.eels(opening: false, openSentence: opened, computing: true, stage: .fit), "Fitting the edges…")
        XCTAssertNil(BusyOperation.eels(opening: false, openSentence: opened, computing: false, stage: .fit))
    }

    /// An idle room in a fresh window names nothing.
    @MainActor func testAnIdleRoomNamesNothing() {
        let state = AppState()
        XCTAssertNil(BusyOperation.name(room: .edx, appState: state))
        XCTAssertNil(BusyOperation.name(room: .eels, appState: state))
    }

    /// The toolbar and the Stop button read the running work, not the status sentence. Red under: `appState.statusText` as the operation.
    func testTheToolbarAndStopReadTheRunningWork() throws {
        let view = squeezed(try source("macTEM/UI/ContentView.swift"))
        XCTAssertTrue(view.contains(".busy(operation: BusyOperation.name(room: room, appState: appState) ?? room.title,"))
        let verb = try source("macTEM/UI/RoomPrimaryAction.swift")
        XCTAssertFalse(verb.contains("operationName: appState.statusText"))
    }
}
