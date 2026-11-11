//
//  SEMSessionLedgerTests.swift
//  The Results room's SEM rows and the session report through the window (P8-02, design export-and-reports §3, §4, §7; D-SEM-103,
//  D-SEM-104): the shipped nickel scan opened, processed and Hough-indexed as a person does it, two exports written; the rows carry the
//  rooms' own words (the Indexing room's Info line, the Output line of the run), the export's picture is the bytes on disk, and File ›
//  Export Session Report… writes a Markdown report with the journey's headings that links the figure by its name. The session record
//  keeps a panel's export only once the panel has written it; the Results room opens on SEM results alone.
//  Red before the record: no row for an export, no time on the dataset. Red under: an export recorded before its panel wrote it; the
//  Results room refused to a window with only an EBSD dataset; the report's figure re-rendered instead of the exported bytes.
//  The report's numbers are in `ExportSnapshot.labelLocale` on every Mac, the Results room's in the reader's (macTEM#267).
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class SEMSessionLedgerTests: XCTestCase {
    @MainActor private func waitIdle(_ state: AppState) async throws {
        try await waitUntil("the Patterns and Maps rooms' passes to end", seconds: 60) {
            !state.ebsd.isOpening && !state.ebsd.isMapping && !state.ebsd.isComputingMean && !state.ebsd.isProcessing && !state.maps.isBusy
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
        try await waitUntil("the nickel scan to open in the Patterns room", seconds: 20) { state.ebsd.hasDataset }
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
        // The Indexing room's Info line, its counts never grouped on screen as in the report (#272).
        XCTAssertEqual(indexing.fields.first { $0.name == "Indexed" }?.value, "\(result.indexedCount) of \(result.pointCount)")
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
        // The report writes its numbers one way on every Mac (`ExportSnapshot.labelLocale`): "4125 of 4125", never "4,125" or "4.125".
        XCTAssertTrue(text.contains("| Indexed | \(result.indexedCount) of \(result.pointCount) |"), "the report's counts are not grouped")
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
        try await waitUntil("the master pattern and the dictionary's size", seconds: 30) {
            !indexing.masterPatterns.isEmpty && indexing.dictionarySize != nil
        }
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

    /// A Maps figure cites what made its layer, and a layer the analysis makes carries the settings it ran with; every method the report
    /// can cite names its literature and a pinned reference with its version. Red under: a KAM map cited as an IPF colour key; a
    /// method without a reference.
    func testMapsFiguresCiteTheirAnalysisAndEveryMethodIsReferenced() {
        XCTAssertEqual(MapsRoomFormat.methods(of: .ipf(.z)), [.orientationMap, .ipfColours])
        XCTAssertEqual(MapsRoomFormat.methods(of: .phase), [.orientationMap])
        XCTAssertEqual(MapsRoomFormat.methods(of: .derived(.kam)), [.orientationMap, .kam])
        XCTAssertEqual(MapsRoomFormat.methods(of: .derived(.gos)), [.orientationMap, .grains, .gos])
        XCTAssertEqual(MapsRoomFormat.methods(of: .derived(.gnd)), [.orientationMap, .gnd])
        XCTAssertEqual(MapsRoomFormat.methods(of: .derived(.schmid)), [.orientationMap, .grains, .schmid])
        XCTAssertEqual(MapsRoomFormat.analysisFields(MapAnalysisSettings()).map(\.name), ["Boundary", "Smallest", "KAM maximum"])
        XCTAssertEqual(MapsRoomFormat.analysisFields(MapAnalysisSettings()).map(\.value), ["5°", "10 points", "5°"])
        let pinned = Set(SEMReferenceVersions.pinned.map { "\($0.name) \($0.version)" })
        for method in SEMMethod.allCases {
            XCTAssertFalse(method.title.isEmpty, method.rawValue)
            XCTAssertTrue(method.sentence.hasSuffix("."), method.rawValue)
            XCTAssertFalse(method.references.isEmpty, method.rawValue)
            XCTAssertTrue(pinned.contains { method.parityReference.contains($0) }, "\(method.rawValue): \(method.parityReference)")
        }
    }

    /// The Maps room's Segment and texture are Results rows and report parts (macTEM#242): the grain statistics in the Grains section's
    /// words with the mean GOS and KAM of what Segment stored and the settings it ran with, stale once the settings change; the texture
    /// with each figure's largest density; the grains under "Maps and grains", the texture its own section with its own checkbox.
    /// Red before: no row for either, and no Texture section; red under: the stale row showing the new settings instead of the ones it
    /// ran with; the texture method cited with the Texture part switched off.
    @MainActor func testGrainsAndTextureAreRowsAndReportParts() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ebsd-sdss-ferrite-austenite.ang")
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.maps.open(url: url).value
        XCTAssertTrue(state.maps.hasMap)
        XCTAssertNil(SEMSessionLedger.rows(of: state).first { $0.kind == .grains }, "no grain row before Segment")
        let settings = MapAnalysisSettings(boundaryDegrees: 10, minimumSize: 10, kamMaxDegrees: 5)
        state.maps.setAnalysisSettings(settings)
        await state.maps.segment().value
        await state.maps.showTexture().value
        let analysis = try XCTUnwrap(state.maps.analysis)
        let texture = try XCTUnwrap(state.maps.texture)

        let rows = SEMSessionLedger.rows(of: state)
        XCTAssertEqual(rows.map(\.kind), [.orientationMap, .grains, .texture], "\(rows.map(\.id))")
        let grains = try XCTUnwrap(rows.first { $0.kind == .grains })
        func field(_ row: SEMSessionRow, _ name: String) -> String? { row.fields.first { $0.name == name }?.value }
        XCTAssertEqual(grains.value, MapsRoomFormat.grainSummary(analysis))
        XCTAssertEqual(field(grains, "Grains"), "\(analysis.table.count)")
        XCTAssertEqual(field(grains, "Boundary"), "10°")
        XCTAssertEqual(field(grains, "State"), "Current")
        let gos = analysis.table.map(\.gosDegrees).filter(\.isFinite)
        XCTAssertEqual(field(grains, "Mean GOS"),
                       "\(MapsRoomFormat.angle(gos.reduce(0, +) / Double(gos.count), digits: 2))° over \(gos.count) grains")
        XCTAssertTrue(field(grains, "Mean KAM")?.hasSuffix(" points") ?? false, "\(grains.fields)")
        XCTAssertEqual(grains.methods, [.grains, .kam, .gos])
        XCTAssertTrue(grains.log.first?.text.hasPrefix("Segmented \(analysis.table.count) grains") ?? false, "\(grains.log)")
        XCTAssertNotNil(grains.time)

        let made = try XCTUnwrap(rows.first { $0.kind == .texture })
        XCTAssertEqual(made.label, "\(texture.phaseName) texture")
        XCTAssertEqual(field(made, "Points"), "\(texture.points)")
        for figure in texture.poleFigures + texture.odfSections {
            XCTAssertEqual(field(made, figure.title), "maximum \(MapsRoomFormat.number(figure.maximum)) MRD", figure.title)
        }
        XCTAssertEqual(made.methods, [.orientationMap, .texture])

        // The report: the grains under Maps and grains, the texture its own part, left out with its method when unticked.
        let outline = SEMSessionReport.outline(rows)
        XCTAssertEqual(outline[.maps], 2)
        XCTAssertEqual(outline[.texture], 1)
        let context = SEMSessionReport.Context(date: Date(), software: "macTEM")
        let text = SEMReportMarkdown.text(of: SEMSessionReport.document(rows, options: SEMSessionReport.Options(title: "Steel", format: .markdown),
                                                                       context: context), directory: nil)
        for heading in ["## Maps and grains", "### Grain statistics", "## Texture", "### \(texture.phaseName) texture",
                        "### " + SEMMethod.texture.title, "### " + SEMMethod.kam.title] {
            XCTAssertTrue(text.contains("\n\(heading)\n"), heading)
        }
        var sections = Set(SEMSessionReport.Section.allCases)
        sections.remove(.texture)
        let without = SEMReportMarkdown.text(of: SEMSessionReport.document(rows, options: SEMSessionReport.Options(title: "Steel", sections: sections,
                                                                                                                  format: .markdown),
                                                                          context: context), directory: nil)
        XCTAssertFalse(without.contains("\n## Texture\n"))
        XCTAssertFalse(without.contains("\n### " + SEMMethod.texture.title + "\n"), "a part left out cites nothing")
        XCTAssertTrue(without.contains("\n### Grain statistics\n"))

        // Changed settings: the row is stale and still says what Segment ran with.
        state.maps.setAnalysisSettings(MapAnalysisSettings(boundaryDegrees: 15, minimumSize: 10, kamMaxDegrees: 5))
        let stale = try XCTUnwrap(SEMSessionLedger.rows(of: state).first { $0.kind == .grains })
        XCTAssertEqual(stale.value, MapsRoomFormat.grainSummary(analysis) + " · stale")
        XCTAssertEqual(field(stale, "State"), "Stale: the Grains or Misorientation settings changed after Segment")
        XCTAssertEqual(field(stale, "Boundary"), "10°", "the settings it ran with")
    }

    /// The rows' numbers are in the locale the caller passes: the reader's in the Results room, `ExportSnapshot.labelLocale` in the
    /// session report, so a report reads the same whatever the Mac's region. NLPAR's λ follows its neighbours, so one German row never
    /// reads "std 1,5 px … λ 0.123". Red before: no locale to pass, λ always written with a point.
    func testTheRowsWriteEveryNumberInOneLocale() throws {
        let german = Locale(identifier: "de_DE"), report = ExportSnapshot.labelLocale
        let dataset = try DemoDocuments.ebsd().dataset
        var pipeline = PatternPipeline()
        pipeline.dynamicStage.std = 1.5
        pipeline.nlpar.isOn = true
        func fields(_ locale: Locale) -> [String: String] {
            let made = SEMSessionLedger.processingFields(pipeline, dataset: dataset, lambda: 0.1234, locale: locale)
            return Dictionary(made.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        let radius = "radius \(pipeline.nlpar.searchRadius) px"
        XCTAssertEqual(fields(german)["Dynamic background"], "Subtract · Gaussian · std 1,5 px · truncate 4 std")
        XCTAssertEqual(fields(german)["NLPAR"], "\(radius) · λ 0,123")
        XCTAssertEqual(fields(report)["Dynamic background"], "Subtract · Gaussian · std 1.5 px · truncate 4 std")
        XCTAssertEqual(fields(report)["NLPAR"], "\(radius) · λ 0.123")

        // The Indexing room's Info words: never grouped, on screen as in the report (#272; a German screen read "4.125 of 4.125").
        let ni = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Ni" })
        var result = IndexingResult(scanRows: 55, scanColumns: 75, phases: [ni])
        var indexed = HoughIndexer.Solution()
        indexed.phase = 0
        for row in 0..<55 { result.land(Array(repeating: indexed, count: 75), at: row) }
        XCTAssertEqual(IndexingInfoFormat.indexed(result, locale: report), "4125 of 4125")
        XCTAssertEqual(IndexingInfoFormat.indexed(result, locale: german), "4125 of 4125")
        XCTAssertEqual(IndexingInfoFormat.points(3812, locale: report), "3812 points")
        XCTAssertEqual(IndexingInfoFormat.time(1.25, locale: german), "1,25 s")

        // The Patterns room's Calibration rows and the Maps room's words take the same locale.
        XCTAssertEqual(EBSDBrowsing.calibrationRows(dataset, locale: german).first?.value, "1,5 µm × 1,5 µm")
        XCTAssertEqual(EBSDBrowsing.calibrationRows(dataset, locale: report).first?.value, "1.5 µm × 1.5 µm")
        let settings = MapAnalysisSettings(boundaryDegrees: 2.5, minimumSize: 10, kamMaxDegrees: 5)
        XCTAssertEqual(MapsRoomFormat.analysisFields(settings, locale: german).map(\.value), ["2,5°", "10 points", "5°"])
        XCTAssertEqual(MapsRoomFormat.angle(1.234, digits: 2, locale: german), "1,23")

        // The SEM-EDS rows' words take it too, and never group their counts.
        XCTAssertEqual(SEMEDSFormat.keV(5.8987, locale: german), "5,899")
        XCTAssertEqual(SEMEDSFormat.keV(5.8987, locale: report), "5.899")
        XCTAssertEqual(SEMEDSFormat.counts(12345, locale: german), "12345")
        XCTAssertEqual(SEMEDSFormat.counts(12345, locale: report), "12345")
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
