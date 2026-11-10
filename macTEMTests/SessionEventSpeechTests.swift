//
//  SessionEventSpeechTests.swift
//  What VoiceOver hears of the rooms' runs (`SessionEventSpeech`, `AppState.report(event:in:)`): the line that ends a run (it landed,
//  stopped, was refused or failed) and a file opened are spoken; a run's start line is not, the line that ends it says the outcome.
//  Every session's event goes through `report`, which keeps the infobar line and the SEM rooms' session record as they were.
//  Red before: no `SessionEventSpeech` and no `report(event:in:)`; the sessions' `onEvent` set the infobar only, never spoken.
//  A line is spoken once and at default priority: not when an alert says the same failure, and not over what the person does next.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class SessionEventSpeechTests: XCTestCase {

    /// The repo's own source file at `path`, read beside this test file.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The sessions' own lines, ends and starts. Red under: every line spoken (a start line too), or none.
    func testTheLineThatEndsARunIsSpokenAndItsStartIsNot() {
        XCTAssertTrue(SessionEventSpeech.announces("Indexed 4120 of 4125 patterns with Hough in 3.1 s"))
        XCTAssertFalse(SessionEventSpeech.announces("Indexing 4125 patterns with Hough (Ni)…"))
        XCTAssertTrue(SessionEventSpeech.announces("Error: x"))
        let ends = ["Opened Demo EBSD — 30 × 40 patterns of 60 × 60 px, step 1.5 µm",
                    "Stopped indexing after 12 of 30 rows; the indexed rows stay",
                    "Stopped processing; the last complete run stays",
                    "Processed 1200 patterns in 2.0 s · 4.3 MB in memory",
                    "Segmented 14 grains (boundaries above 5°, at least 5 points)",
                    "Fitted 2 edges over 1024 px",
                    "Deconvolved: 1024 px",
                    "Aligned.",
                    "Stopped.",
                    "Refused: the file states no beam energy."]
        for line in ends {
            XCTAssertTrue(SessionEventSpeech.announces(line), line)
        }
        let starts = ["Opening scan.h5…", "Processing 1200 patterns…", "Segmenting grains…",
                      "Indexing 1200 patterns against 2 dictionaries (Ni, Fe) at 2.0° (NCC); each point takes the phase of its best score…"]
        for line in starts {
            XCTAssertFalse(SessionEventSpeech.announces(line), line)
        }
        XCTAssertFalse(SessionEventSpeech.announces(""), "an empty line says nothing")
    }

    /// A master pattern that cannot be opened is said once. The session sends its line and then the failure, which the window shows as
    /// an alert; VoiceOver reads the alert, so the line is kept (the Output pane, the Indexing room's session record) and not spoken as
    /// well. Red before: `announces` was true for the line, so the failure was announced and then read again from the alert.
    @MainActor func testAMasterPatternThatCannotBeOpenedIsSaidOnceByItsAlert() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        let scan = try XCTUnwrap(Bundle(for: SessionEventSpeechTests.self).url(forResource: "ebsd-kikuchipy-h5ebsd", withExtension: "h5"),
                                 "ebsd-kikuchipy-h5ebsd.h5 is not in the test bundle")
        await state.indexing.openMasterPattern(url: scan).value
        let sentence = "ebsd-kikuchipy-h5ebsd.h5 is not an EMsoft master pattern file."
        XCTAssertEqual(state.errorMessage, sentence, "the alert says why, and VoiceOver reads it")
        let lines = state.semRecord.lines(of: .indexing).map(\.text)
        XCTAssertEqual(lines, ["Master pattern: " + sentence], "the session record keeps the line")
        for line in lines {
            XCTAssertFalse(SessionEventSpeech.announces(line), "spoken as well as the alert: \(line)")
        }
        XCTAssertTrue(SessionEventSpeech.announces("Opened the master pattern ni.h5: 20 kV; Ni has no master pattern of its own"),
                      "a master pattern that opened is still said")
    }

    /// A run's line is posted at default priority, as mac4DSTEM's announcements are: a run ends while the person works, and a line at
    /// high priority cannot be interrupted once it starts. An export's and a save's line keep `ExportPanels.announcement` (posted as
    /// their sheet goes away; ExportSnapshotTests pins its priority). Red before: `report` posted `ExportPanels.announcement(line)`.
    func testARunsLineIsPostedAtDefaultPriority() throws {
        let speech = try source("macTEM/App/SessionEventSpeech.swift")
        XCTAssertTrue(speech.contains("AccessibilityNotification.Announcement(line).post()"))
        XCTAssertFalse(speech.contains("Announcement(ExportPanels.announcement("), "no high priority for a line that ends a run")
        XCTAssertFalse(speech.contains("accessibilitySpeechAnnouncementPriority"))
    }

    /// Each of the five sessions' `onEvent` goes through `report(event:in:)`. Red under: a closure that sets `statusText` itself again.
    func testEverySessionsEventGoesThroughReport() throws {
        let app = try source("macTEM/App/AppState.swift")
        let closures = app.components(separatedBy: ".onEvent = ").dropFirst().map { text in String(text.prefix { $0 != "\n" }) }
        XCTAssertEqual(closures.count, 5, "edx, eels, ebsd, maps and indexing")
        for closure in closures {
            XCTAssertTrue(closure.contains("self?.report(event: $0, in: "), closure)
        }
    }

    /// `report` keeps what the closures did: the infobar line, and the SEM room's line in the session record (a start line not kept);
    /// a spectrum room's line in no SEM room's record. Red under: the record skipped, or a spectrum room's line noted.
    @MainActor func testReportKeepsTheInfobarAndTheSessionRecord() {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.report(event: "Indexing 1200 patterns with Hough (Ni)…", in: .indexing)
        XCTAssertEqual(state.statusText, "Indexing 1200 patterns with Hough (Ni)…")
        state.report(event: "Indexed 1190 of 1200 patterns with Hough in 1.0 s", in: .indexing)
        XCTAssertEqual(state.statusText, "Indexed 1190 of 1200 patterns with Hough in 1.0 s")
        XCTAssertEqual(state.semRecord.lines(of: .indexing).map(\.text), ["Indexed 1190 of 1200 patterns with Hough in 1.0 s"])

        state.report(event: "Fitted 2 edges over 1024 px", in: nil)
        XCTAssertEqual(state.statusText, "Fitted 2 edges over 1024 px")
        for room in SEMSessionRecord.Room.allCases {
            XCTAssertFalse(state.semRecord.lines(of: room).map(\.text).contains("Fitted 2 edges over 1024 px"), room.rawValue)
        }
    }
}
