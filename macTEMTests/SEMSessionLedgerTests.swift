//
//  SEMSessionLedgerTests.swift
//  The Results room's SEM rows and the session report through the window (P8-02, design export-and-reports §3, §4, §7; D-SEM-103,
//  D-SEM-104): the shipped nickel scan opened, processed and Hough-indexed as a person does it, two exports written; the rows carry the
//  rooms' own words (the Indexing room's Info line, the Output line of the run), the export's picture is the bytes on disk, and File ›
//  Export Session Report… writes a Markdown report with the journey's headings that links the figure by its name. The session record
//  keeps a panel's export only once the panel has written it; the Results room opens on SEM results alone.
//  Red before the record: no row for an export, no time on the dataset. Red under: an export recorded before its panel wrote it; the
//  Results room refused to a window with only an EBSD dataset; the report's figure re-rendered instead of the exported bytes.
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class SEMSessionLedgerTests: XCTestCase {
    @MainActor private func waitIdle(_ state: AppState) async throws {
        for _ in 0..<12_000 where state.ebsd.isOpening || state.ebsd.isMapping || state.ebsd.isComputingMean || state.ebsd.isProcessing
            || state.maps.isBusy {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(state.ebsd.isBusy)
    }

    /// The nickel session as the window makes it: the rows, the figure's bytes, the report the File menu writes.
    @MainActor func testTheNickelSessionIsReportedInTheRoomsWords() async throws {
        let url = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "DemoData/ is not in the bundle")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SEMSessionLedgerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(launch: LaunchOptions(arguments: ["--export-dir", directory.path]))
        await state.open(urls: [url])?.value
        for _ in 0..<4000 where !state.ebsd.hasDataset { try await Task.sleep(for: .milliseconds(5)) }
        try await waitIdle(state)
        XCTAssertTrue(state.ebsd.hasDataset)
        await state.ebsd.process().value
        await state.indexing.index().value
        let result = try XCTUnwrap(state.indexing.result)
        var reports: [String] = []
        state.indexingRoom.export(.mapPNG, from: state.indexing, directory: directory) { reports.append($0) }
        state.indexingRoom.export(.ang, from: state.indexing, directory: directory) { reports.append($0) }
        XCTAssertEqual(reports, ["Exported patterns_v2 indexed IPF-Z.png", "Exported patterns_v2 indexed.ang"])

        let rows = SEMSessionLedger.rows(of: state)
        let kinds = Set(rows.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.dataset, .processing, .indexing, .export]), "\(rows.map(\.id))")
        let dataset = try XCTUnwrap(rows.first { $0.kind == .dataset })
        XCTAssertEqual(dataset.label, "patterns_v2.h5")
        XCTAssertNotNil(dataset.time, "the Opened line was kept with its time")
        XCTAssertEqual(dataset.fields.first?.name, "Step", "the Patterns room's Calibration rows")
        let processing = try XCTUnwrap(rows.first { $0.kind == .processing })
        XCTAssertTrue(processing.log.contains { $0.text.hasPrefix("Processed ") }, "\(processing.log)")
        XCTAssertEqual(processing.methods, [.staticBackground, .dynamicBackground], "the room's default stages")
        let indexing = try XCTUnwrap(rows.first { $0.kind == .indexing })
        // The Indexing room's Info line, as it was written there before the words were shared.
        XCTAssertEqual(indexing.fields.first { $0.name == "Indexed" }?.value, "\(result.indexedCount.formatted()) of \(result.pointCount.formatted())")
        XCTAssertEqual(indexing.fields.first { $0.name == "Method" }?.value, "Hough (pyEBSDindex 0.3.10.1)")
        XCTAssertTrue(indexing.log.contains { $0.text.hasPrefix("Indexed ") }, "\(indexing.log)")
        let exports = rows.filter { $0.kind == .export }
        XCTAssertEqual(exports.map(\.label), ["patterns_v2 indexed IPF-Z.png", "patterns_v2 indexed.ang"])
        let figure = try XCTUnwrap(exports[0].figure)
        XCTAssertEqual(figure.png, try Data(contentsOf: directory.appendingPathComponent("patterns_v2 indexed IPF-Z.png")), "the bytes written")
        XCTAssertEqual(figure.pixelWidth, result.scanColumns)
        XCTAssertEqual(figure.pixelHeight, result.scanRows)
        XCTAssertNil(exports[1].figure, "an .ang is a file, not a figure")
        XCTAssertEqual(exports[1].methods, [.houghIndexing, .angWriter])

        // File › Export Session Report…, as Markdown, into the journey folder.
        state.resultsRoom.reportFormat = .markdown
        ExportPanels.exportSessionReport(appState: state)
        let name = "patterns_v2 session report.md"
        XCTAssertTrue(state.statusText.hasPrefix("Exported \(name) — "), state.statusText)
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        for heading in ["## Processing", "## Indexing", "## Methods and references", "## Versions", "### Hough indexing"] {
            XCTAssertTrue(text.contains("\n\(heading)\n"), heading)
        }
        XCTAssertTrue(text.contains("![Figure 1](patterns_v2%20indexed%20IPF-Z.png)"), "the figure is linked by its name next to the report")
        XCTAssertTrue(text.contains("| Indexed | \(result.indexedCount.formatted()) of \(result.pointCount.formatted()) |"))
        XCTAssertTrue(text.contains("| patterns_v2 indexed.ang | EDAX ANG | Indexing · patterns_v2.h5 |"))

        // The PDF of the same session draws the exported bytes.
        state.resultsRoom.reportFormat = .pdf
        ExportPanels.exportSessionReport(appState: state)
        let pdf = try Data(contentsOf: directory.appendingPathComponent("patterns_v2 session report.pdf"))
        XCTAssertEqual(Array(pdf.prefix(5)), Array("%PDF-".utf8))
    }

    /// Both of the Indexing room's runs are listed, the one on screen first, each with its own settings, state and Output lines; the
    /// report sets both under Indexing and cites both methods. Red under: only the run on screen listed (a Dictionary run hid the Hough
    /// run the room still holds); the Hough run's lines given to the Dictionary run.
    @MainActor func testBothIndexingRunsAreListed() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitIdle(state)
        let indexing = state.indexing
        await indexing.index().value
        indexing.setMethod(.dictionary)
        indexing.editDictionarySettings { $0.resolution = 10 }
        for _ in 0..<6000 where indexing.currentMaster == nil || indexing.dictionarySize == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(indexing.refusal, indexing.refusal ?? "")
        await indexing.index().value
        XCTAssertEqual(indexing.result?.method, .dictionary)
        XCTAssertEqual(indexing.otherRun?.method, .hough)

        let rows = SEMSessionLedger.rows(of: state).filter { $0.kind == .indexing }
        XCTAssertEqual(rows.map(\.id), ["indexing", "indexing.hough"], "the run on screen, then the other method's")
        XCTAssertEqual(rows.map(\.label), ["Dictionary indexing", "Hough indexing"])
        let dictionary = rows[0], hough = rows[1]
        XCTAssertEqual(dictionary.fields.first { $0.name == "Method" }?.value, "Dictionary (kikuchipy 0.13.1)")
        XCTAssertNotNil(dictionary.fields.first { $0.name == "Dictionary" }, "the dictionary's size, step and metric")
        XCTAssertNil(dictionary.fields.first { $0.name == "Bands" })
        XCTAssertEqual(hough.fields.first { $0.name == "Bands" }?.value, "\(indexing.runs[.hough]?.inputs.settings.bands ?? -1)")
        XCTAssertNil(hough.fields.first { $0.name == "Dictionary" })
        XCTAssertEqual(dictionary.fields.first { $0.name == "State" }?.value, "Current")
        XCTAssertEqual(hough.fields.first { $0.name == "State" }?.value, "Current")
        XCTAssertTrue(dictionary.log.contains { $0.text.hasPrefix("Indexed ") && $0.text.contains(" with Dictionary ") }, "\(dictionary.log)")
        XCTAssertFalse(dictionary.log.contains { $0.text.contains(" with Hough ") }, "\(dictionary.log)")
        XCTAssertTrue(hough.log.contains { $0.text.hasPrefix("Indexed ") && $0.text.contains(" with Hough ") }, "\(hough.log)")
        XCTAssertFalse(hough.log.contains { $0.text.contains(" with Dictionary ") }, "\(hough.log)")
        XCTAssertEqual(hough.methods.first, .houghIndexing)
        XCTAssertEqual(dictionary.methods.first, .dictionaryIndexing)

        // A Hough setting changed: the Hough run is stale, the Dictionary run on screen is not.
        indexing.editSettings { $0.bands += 1 }
        let after = SEMSessionLedger.rows(of: state).filter { $0.kind == .indexing }
        XCTAssertEqual(after.last?.fields.first { $0.name == "State" }?.value, "Stale: the patterns, phases or settings changed")
        XCTAssertEqual(after.first?.fields.first { $0.name == "State" }?.value, "Current")

        let all = SEMSessionLedger.rows(of: state)
        let text = SEMReportMarkdown.text(of: SEMSessionReport.document(all, options: SEMSessionReport.Options(title: "Two runs", format: .markdown),
                                                                       context: SEMSessionReport.Context(date: Date(), software: "macTEM")),
                                          directory: nil)
        for heading in ["### Dictionary indexing", "### Hough indexing", "### " + SEMMethod.houghIndexing.title,
                        "### " + SEMMethod.dictionaryIndexing.title] {
            XCTAssertTrue(text.contains("\n\(heading)\n"), heading)
        }
    }

    /// A panel's export is kept once the panel has written it, with the place and the time; a cancelled panel keeps nothing.
    @MainActor func testAPanelExportIsKeptOnceWritten() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitIdle(state)
        state.patternsRoom.export(.metadataJSON, from: state.ebsd) { XCTFail($0) }
        XCTAssertEqual(state.patternsRoom.exporting, .metadataJSON)
        XCTAssertTrue(state.semRecord.exports.isEmpty, "nothing is kept before the panel writes")
        let url = URL(fileURLWithPath: "/tmp/Demo EBSD metadata.json")
        state.patternsRoom.didWrite(to: url)
        XCTAssertEqual(state.semRecord.exports.count, 1)
        let kept = try XCTUnwrap(state.semRecord.exports.first)
        XCTAssertEqual(kept.file, url)
        XCTAssertNotNil(kept.time)
        XCTAssertEqual(kept.room, "Patterns")
        XCTAssertEqual(kept.what, "Metadata JSON")
        XCTAssertNil(kept.png)
        state.patternsRoom.didWrite(to: url)
        XCTAssertEqual(state.semRecord.exports.count, 1, "one write, one record")
        XCTAssertTrue(state.semRecord.lines(of: .patterns).contains { $0.text.hasPrefix("Opened Demo EBSD") }, "\(state.semRecord.lines(of: .patterns))")
    }

    /// A window with only SEM results enters the Results room; the reason names both kinds of data otherwise.
    @MainActor func testTheResultsRoomOpensOnSEMResultsAlone() async throws {
        XCTAssertNil(RoomAvailability.reason(.results, holdings: RoomHoldings(ebsd: true, semResults: true)))
        XCTAssertEqual(RoomAvailability.reason(.results, holdings: RoomHoldings(eds: true)), "No file open holds an image or an SEM result")
        XCTAssertEqual(RoomAvailability.fallback(holdings: RoomHoldings(ebsd: true, semResults: true)), .patterns)
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitIdle(state)
        XCTAssertTrue(SEMSessionLedger.hasRows(state))
        state.selectWorkspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        let rows = SEMSessionLedger.rows(of: state)
        XCTAssertEqual(rows.first?.kind, .dataset)
        XCTAssertEqual(SEMSessionReport.defaultTitle(rows), "SEM session report", "the generated dataset has no file")
    }

    /// The record keeps a room's lines with their times, not the "…ing" lines of a run in flight.
    @MainActor func testTheRecordKeepsTheEndingLines() {
        let record = SEMSessionRecord()
        record.note("Opening a.h5…", in: .patterns)
        record.note("Opened a.h5 — 2 × 2 of 4 × 4, step 1 µm", in: .patterns)
        record.note("", in: .patterns)
        record.note("Processed 4 patterns in 0.1 s · 0.1 MB in memory", in: .patterns)
        record.note("Opened b.h5 — 2 × 2 of 4 × 4, step 1 µm", in: .patterns)
        XCTAssertEqual(record.lines(of: .patterns).map(\.text).count, 3)
        XCTAssertEqual(record.lines(of: .patterns, sinceLastStartingWith: "Opened b.h5").map(\.text), ["Opened b.h5 — 2 × 2 of 4 × 4, step 1 µm"])
        XCTAssertEqual(record.lastLine(of: .patterns, startingWith: "Processed ")?.text, "Processed 4 patterns in 0.1 s · 0.1 MB in memory")
        XCTAssertTrue(record.lines(of: .indexing).isEmpty)
    }
}
