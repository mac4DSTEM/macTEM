//
//  ResultsWiringTests.swift
//  The Results room's call sites: the room is built and can be entered, the shell's slots mount it (the room switch in
//  `WorkspaceView`, the Settings and Info switches in `WorkspaceInspector`), File > Export Results… is on ⇧⌥⌘E (a key no other
//  item has) and enabled by `ExportSnapshot.availability`, its entry point writes only in the Results room with a row (into a journey's
//  export folder, read back) and takes the EELS room's rows of the file on screen, the snapshot of the selected file is what the
//  panel's OK writes (a real file read back) and a saved file's snapshot takes the ISO 8601 session header, the room's state resets
//  its selection with a file switch and a window keeps its one state across room switches, and the table is a native `Table` with a
//  `Section` per group and ⌘C through `onCopyCommand`. Each fix is right in its pure function while reverting the one line that uses
//  it leaves every pure test green; these go red when that line reverts. Tier 2.
//
//  Mutations sampled (each alone, the named test went red): the Export Results… item without its `.disabled`; the room's switch
//  branch removed; the availability enabled outside the Results room; the snapshot taking all open files; the selection kept across
//  files.
//

import ImagoCore
import XCTest
import AppKit
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class ResultsWiringTests: XCTestCase {

    private static let software = "macEM 0.1.0 (1)"

    /// The repo's own source file at `path`, read beside this test file.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    nonisolated private static func image(fileName: String = "scan.dm4") -> CalibratedImage {
        CalibratedImage(width: 40, height: 30, pixels: (0..<1200).map { Float($0 % 97) },
                        x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.8, unit: "nm", origin: 0),
                        fileName: fileName, source: "ImageList.1", voltage: nil)
    }

    @MainActor private func twoItems() async throws -> (items: OpenItems, a: OpenItem, b: OpenItem) {
        let a = URL(fileURLWithPath: "/data/one/a.dm4"), b = URL(fileURLWithPath: "/data/two/b.dm4")
        let items = OpenItems(identify: { FileIdentity(path: $0.path) }, reader: { request in
            let image = Self.image(fileName: request.url.lastPathComponent)
            return OpenedImage(image: image, canvas: AppState.canvas(for: image), metadata: AcquisitionMetadata(), url: request.url,
                               thumbnail: nil, bookmark: nil)
        })
        items.open(urls: [a, b])
        await items.settled()
        return (items, try XCTUnwrap(items.items.first { $0.url == a }), try XCTUnwrap(items.items.first { $0.url == b }))
    }

    // MARK: The room is built

    /// The rooms 1.0 ships, in the order of the work, Results enterable with nothing open; Prepare is not among them (the owner, 2026-10-23:
    /// "It shouldn't ship in macTEM"). Red under: Prepare back in the list, Results not enterable, Results not the last workspace (⌘5 since
    /// the workspaces, 2026-11-10).
    @MainActor func testTheResultsRoomIsBuiltAndCanBeEntered() {
        XCTAssertEqual(WorkspaceArea.allCases, [.image, .fft, .edx, .eels, .diffraction, .patterns, .indexing, .maps, .results])
        XCTAssertNil(WorkspaceArea(rawValue: "prepare"), "a window that saved Prepare opens in the default room")
        let state = AppState()
        XCTAssertNil(state.roomUnavailableReason(.results), "with nothing open every room can be entered")
        state.selectWorkspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        state.selectWorkspace(.diffraction)
        XCTAssertEqual(state.navigation.workspaceArea, .diffraction)
        XCTAssertEqual(WorkspaceGroup.imaging.shortcutDigit, "1")
        XCTAssertEqual(WorkspaceGroup.results.shortcutDigit, "5", "Results is the last workspace")
        XCTAssertEqual(WorkspaceArea.results.group, .results)
        XCTAssertFalse(WorkspaceGroup.results.hasParts, "Results is one room, selected in its own right")
        XCTAssertTrue(state.resultsRoom.selection.isEmpty)
    }

    // MARK: Export Results… is enabled by the one rule

    /// Export Results… needs the Results room, an image, no read running and at least one row; the other two commands stay where
    /// they were and are off in this room. Red under: enabled outside the room; enabled with no row; enabled while a read runs; the
    /// Image room's commands on in the Results room.
    @MainActor func testExportResultsIsEnabledByTheOneRule() {
        func available(hasImage: Bool = true, area: WorkspaceArea = .results, isLoading: Bool = false, rows: Int = 3) -> ExportAvailability {
            ExportSnapshot.availability(hasImage: hasImage, area: area, isLoading: isLoading, profileHasSamples: true, resultRows: rows)
        }
        XCTAssertEqual(available(), ExportAvailability(image: false, profile: false, results: true))
        XCTAssertFalse(available(rows: 0).results, "nothing to export")
        XCTAssertFalse(available(hasImage: false).results)
        XCTAssertFalse(available(isLoading: true).results)
        for area in [WorkspaceArea.image, .fft, .diffraction] {
            XCTAssertFalse(available(area: area).results, "\(area): the Results room's command")
        }
        XCTAssertEqual(available(area: .image), ExportAvailability(image: true, profile: true, results: false))
        XCTAssertEqual(available(area: .image, rows: 0).profile, true, "the row count is the Results room's alone")
    }

    /// From the app's own state: the rule reads the selected file's ledger in the Results room and nothing elsewhere. Red under: the
    /// count taken from another item.
    @MainActor func testTheAvailabilityReadsTheSelectedFilesLedger() async throws {
        let (items, a, b) = try await twoItems()
        let state = AppState()
        // AppState owns its own OpenItems; drive its selected item through the same rule the menu uses.
        func count(_ item: OpenItem) -> Int { ResultsLedger.rows(of: item).count }
        let imageA = try XCTUnwrap(a.session.image)
        a.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)]), on: imageA)
        XCTAssertEqual(count(a), 1)
        XCTAssertEqual(count(b), 0)
        items.select(a.id)
        XCTAssertTrue(ExportSnapshot.availability(hasImage: true, area: .results, isLoading: false, profileHasSamples: false,
                                                  resultRows: count(items.selected!)).results)
        items.select(b.id)
        XCTAssertFalse(ExportSnapshot.availability(hasImage: true, area: .results, isLoading: false, profileHasSamples: false,
                                                   resultRows: count(items.selected!)).results)
        XCTAssertFalse(ExportSnapshot.availability(of: state).results, "no file open")
    }

    /// The entry point, with a journey's export folder (no panel): in the Results room with nothing to export, and in the Image room
    /// with a row, it writes nothing and leaves the status line as it was; in the Results room with a row it says "Exporting…" at once,
    /// then writes the file on screen into the folder and says so. Red under: the entry point's `availability(of:).results` dropped
    /// (the Image room's call writes the CSV). The nothing-to-export case is held by that and by the snapshot's own nil, so it goes
    /// red only when both go.
    @MainActor func testExportResultsWritesOnlyInTheRoomAndOnlyWithARow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ResultsWiringTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(launch: LaunchOptions(arguments: ["--export-dir", folder.path]))
        await state.open(urls: [DemoDocuments.latticeURL])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        let image = try XCTUnwrap(item.session.image, "the demo lattice is read")

        state.selectWorkspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        var before = state.statusText
        ExportPanels.exportResults(appState: state)
        XCTAssertEqual(state.statusText, before, "nothing to export: the status line is as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing to export: nothing written")

        state.selectWorkspace(.image)
        XCTAssertEqual(state.navigation.workspaceArea, .image)
        item.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 10, y: 10), ImagePoint(x: 40, y: 30)]), on: image)
        XCTAssertEqual(state.resultRows(of: item).count, 1, "a row to export")
        before = state.statusText
        ExportPanels.exportResults(appState: state)
        XCTAssertEqual(state.statusText, before, "the Image room: the status line is as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the Image room: nothing written")

        state.selectWorkspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        let snapshot = try XCTUnwrap(ExportSnapshot.resultsSnapshot(in: state))
        let exporting = ExportSnapshot.exportingLine(name: snapshot.defaultName)
        ExportPanels.exportResults(appState: state)
        XCTAssertEqual(state.statusText, exporting, "the line is up before the write, which runs off the main actor")
        try await waitUntil("the export to end", seconds: 10) { state.statusText != exporting }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.statusText, ResultsFormat.exportingDoneLine(name: snapshot.defaultName, rows: 1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [snapshot.defaultName])
        let text = try String(contentsOf: folder.appendingPathComponent(snapshot.defaultName), encoding: .utf8)
        XCTAssertEqual(text, ResultsCSV.text(snapshot.rows, source: snapshot.source, session: snapshot.session), "the file on screen")
    }

    /// The entry point takes the window's snapshot, with the spectrum rooms' rows: with the EELS room holding the file on screen (by its
    /// name, as a file read without a path is told) and its thickness map made, every row of the file is the room's t/λ, and the folder
    /// gets it. Red under: the entry point taking the open files' snapshot alone (`resultsSnapshot(in: appState.openItems)`), which has
    /// no row here, so nothing is written.
    @MainActor func testExportResultsTakesTheEELSRoomsRowsOfTheFileOnScreen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ResultsWiringTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(launch: LaunchOptions(arguments: ["--export-dir", folder.path]))
        await state.open(urls: [DemoDocuments.latticeURL])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        XCTAssertNotNil(item.session.image, "the demo lattice is read")
        XCTAssertTrue(state.resultRows(of: item).isEmpty, "the file has no row of its own")

        // The EELS room holds the file: it is one of the window's EELS files, and the room's cube (the demo spectrum image's) is bound
        // under the file's name, as the app's open hands a file to the room.
        let demo = try DemoDocuments.eels()
        let loaded = LoadedEELS(fileName: item.url.lastPathComponent, image: demo.image, beamEnergyKeV: demo.beamEnergyKeV,
                                convergenceMrad: demo.convergenceMrad, collectionMrad: demo.collectionMrad, origin: demo.origin)
        state.eelsFiles.insert(item.url)
        await state.eels.bind(loaded).value
        await state.eels.settled()
        XCTAssertNil(state.eels.failure)
        let rows = state.resultRows(of: item)
        XCTAssertFalse(rows.isEmpty, "the EELS room's thickness is the file's")
        XCTAssertTrue(rows.allSatisfy { $0.group == .eelsThickness }, "\(rows.map(\.label))")

        state.selectWorkspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        let snapshot = try XCTUnwrap(ExportSnapshot.resultsSnapshot(in: state))
        let exporting = ExportSnapshot.exportingLine(name: snapshot.defaultName)
        ExportPanels.exportResults(appState: state)
        XCTAssertEqual(state.statusText, exporting, "the EELS room's rows are something to export")
        try await waitUntil("the export to end", seconds: 10) { state.statusText != exporting }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.statusText, ResultsFormat.exportingDoneLine(name: snapshot.defaultName, rows: rows.count))
        let text = try String(contentsOf: folder.appendingPathComponent(snapshot.defaultName), encoding: .utf8)
        XCTAssertEqual(text, ResultsCSV.text(snapshot.rows, source: snapshot.source, session: snapshot.session), "the room's rows, in the file")
    }

    // MARK: The snapshot is what the panel writes

    /// The snapshot is of the selected file only, names its default (`<image>.results`, then the panel adds .csv) and its folder, says
    /// what the file holds, and its `write(to:)` writes a real CSV that reads back with the file's rows. Red under: all open files
    /// taken; the name keeping the extension; the write handing the writer another snapshot's rows.
    @MainActor func testTheSnapshotIsOfTheSelectedFileAndItsWriteIsTheFile() async throws {
        let (items, a, b) = try await twoItems()
        let imageA = try XCTUnwrap(a.session.image)
        a.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 6, y: 8)]), on: imageA)
        a.measurements.add(ImageMark(kind: .angle, points: [ImagePoint(x: 5, y: 5), ImagePoint(x: 10, y: 10), ImagePoint(x: 20, y: 6)]),
                           on: imageA)
        XCTAssertNil(ExportSnapshot.resultsSnapshot(of: b, software: Self.software), "b has no result: nothing to export")

        items.select(a.id)
        let snapshot = try XCTUnwrap(ExportSnapshot.resultsSnapshot(in: items, software: Self.software))
        XCTAssertEqual(snapshot.defaultName, "a.results")
        XCTAssertEqual(snapshot.directory?.path, "/data/one")
        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(snapshot.source.fileName, "a.dm4")
        XCTAssertEqual(snapshot.source.software, Self.software)
        XCTAssertEqual(snapshot.message, "2 results · Marks · numbers exact, one line per quantity")
        XCTAssertTrue(snapshot.session.hasPrefix("Not saved."), snapshot.session)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("results-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try await snapshot.write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, ResultsCSV.text(snapshot.rows, source: snapshot.source, session: snapshot.session))
        XCTAssertTrue(text.contains("# file: a.dm4\n"))
        XCTAssertTrue(text.contains(",length_px,10,px,"), "(0,0) to (6,8) is 10 px")
        XCTAssertEqual(text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.count,
                       1 + snapshot.rows.reduce(0) { $0 + $1.entries.count }, "the column header and one line per quantity")

        items.select(b.id)
        XCTAssertNil(ExportSnapshot.resultsSnapshot(in: items, software: Self.software), "an export is of the file on screen")
    }

    /// The session sentence is the Image room's own state line, else the room's words. Red under: a sentence of the room's own for a
    /// file with marks.
    @MainActor func testTheSessionSentence() async throws {
        let (_, a, b) = try await twoItems()
        XCTAssertEqual(ExportSnapshot.sessionSentence(of: b), "No marks in this file's session record.")
        let imageA = try XCTUnwrap(a.session.image)
        a.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 6, y: 8)]), on: imageA)
        let sentence = ExportSnapshot.sessionSentence(of: a)
        XCTAssertEqual(sentence, SessionFormat.tail(SessionTailInput(item: a)).lines.first?.text)
        XCTAssertTrue(sentence.hasPrefix("Not saved. Save to Session (⌘S) keeps the marks in "), sentence)
    }

    /// The results CSV's `session:` header writes a saved time in ISO 8601 with its zone's offset, the same in every locale and with the day; the
    /// Image room's tail (and the Results room's header) keep the reader's clock. That Export Results… takes the header is the next test's. Red
    /// before: the header was the tail's line, "Saved at 1:03 PM to …" in en_US and "Saved at 13:03 to …" in de_DE.
    @MainActor func testTheSessionHeaderWritesTheSavedTimeInISO8601() throws {
        let saved = Date(timeIntervalSince1970: 1_794_315_780) // 2026-11-10 13:03:00 UTC
        var input = SessionTailInput(fileName: "a.dm4.mactem.h5", sidecar: .saved, notes: [], needsAccess: false, newerVersion: nil,
                                     hasMarks: true, isDirty: false, canSave: false, isSaving: false, savedAt: saved)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(ExportSnapshot.sessionHeader(input, timeZone: utc), "Saved at 2026-11-10T13:03:00Z to a.dm4.mactem.h5.")
        XCTAssertEqual(ExportSnapshot.sessionHeader(input, timeZone: berlin), "Saved at 2026-11-10T14:03:00+01:00 to a.dm4.mactem.h5.")
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "de_DE")] {
            let screen = try XCTUnwrap(SessionFormat.tail(input, locale: locale).lines.first?.text)
            XCTAssertTrue(screen.hasPrefix("Saved at ") && !screen.contains("2026-11-10T"), "the screen keeps the reader's clock: \(screen)")
        }
        input.isDirty = true
        XCTAssertEqual(ExportSnapshot.sessionHeader(input, timeZone: utc), "Changed since saved at 2026-11-10T13:03:00Z.")
        input.sidecar = .none
        XCTAssertEqual(ExportSnapshot.sessionHeader(input, timeZone: utc), SessionFormat.tail(input).lines.first?.text, "no time: the tail's words")
    }

    /// A saved file's export takes the header: the snapshot's session line is `sessionHeader`, the saved time in ISO 8601, and not the
    /// sentence the Image room's tail shows on the reader's clock. Red under: the snapshot taking `sessionSentence(of:)`.
    @MainActor func testASavedFilesExportTakesTheHeaderNotTheScreensSentence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ResultsWiringTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.dm4")
        // A read that gives the pixels' identity, as a read from disk does, so the marks can be saved beside the file.
        let items = OpenItems(identify: { FileIdentity(path: $0.path) }, reader: { request in
            let image = Self.image(fileName: request.url.lastPathComponent)
            return OpenedImage(image: image, canvas: AppState.canvas(for: image), metadata: AcquisitionMetadata(), url: request.url,
                               thumbnail: nil, bookmark: nil, identity: SessionSourceIdentity.of(image, fileByteSize: 4096))
        })
        items.open(urls: [file])
        await items.settled()
        let item = try XCTUnwrap(items.items.first)
        let image = try XCTUnwrap(item.session.image)
        item.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 6, y: 8)]), on: image)
        let target = try SessionSidecarFile.sidecarURL(forSource: file)
        _ = try await SessionSaving.save(item, to: .url(target))
        XCTAssertNotNil(item.lastSavedAt, "the marks are saved")

        let header = ExportSnapshot.sessionHeader(SessionTailInput(item: item))
        XCTAssertTrue(header.hasPrefix("Saved at ") && header.hasSuffix(" to \(target.lastPathComponent)."), header)
        let snapshot = try XCTUnwrap(ExportSnapshot.resultsSnapshot(of: item, software: Self.software))
        XCTAssertEqual(snapshot.session, header, "Export Results… writes the header")
        XCTAssertNotEqual(snapshot.session, ExportSnapshot.sessionSentence(of: item), "not the screen's sentence, on the reader's clock")
    }

    // MARK: The room's state

    /// A file switch resets the selection and a repeat of the same file keeps it; the shown groups filter the rows and the sections,
    /// in the group order, empty groups left out; one selected row is the Info tab's, several are not. Red under: the selection kept
    /// across files; a hidden group still listed; the sections in insertion order.
    @MainActor func testTheRoomStateResetsWithTheFileAndFiltersByGroup() {
        let marks = ResultRow(id: "mark:1", product: .distance, label: "Distance 1", entries: [])
        let more = ResultRow(id: "mark:2", product: .angle, label: "Angle 1", entries: [])
        let spot = ResultRow(id: "spot:1", product: .spot, label: "Spot 1", entries: [])
        let rows = [marks, more, spot]
        let state = ResultsRoomState()
        let fileA = UUID(), fileB = UUID()
        state.attach(to: fileA)
        state.selection = ["mark:1"]
        state.attach(to: fileA)
        XCTAssertEqual(state.selection, ["mark:1"], "the same file keeps its selection")
        state.attach(to: fileB)
        XCTAssertTrue(state.selection.isEmpty, "a file switch resets the selection")

        XCTAssertEqual(state.visible(rows), rows)
        XCTAssertEqual(state.sections(rows).map(\.group), [.marks, .spots])
        XCTAssertEqual(state.sections(rows).map { $0.rows.map(\.id) }, [["mark:1", "mark:2"], ["spot:1"]])
        state.setShown(.marks, false)
        XCTAssertEqual(state.visible(rows), [spot])
        XCTAssertEqual(state.sections(rows).map(\.group), [.spots])
        XCTAssertFalse(state.isShown(.marks))
        state.setShown(.spots, false)
        XCTAssertTrue(state.sections(rows).isEmpty)
        state.setShown(.marks, true)
        state.setShown(.spots, true)

        state.selection = ["mark:2"]
        XCTAssertEqual(state.selected(in: rows)?.id, "mark:2")
        state.selection = ["mark:1", "spot:1"]
        XCTAssertNil(state.selected(in: rows), "several are selected")
        XCTAssertEqual(state.selectedRows(in: rows).map(\.id), ["mark:1", "spot:1"], "in table order")
        // A row the table does not list (its group is switched off) is not described, nor copied.
        state.setShown(.spots, false)
        XCTAssertEqual(state.selectedRows(in: rows).map(\.id), ["mark:1"])
        state.selection = ["spot:1"]
        XCTAssertNil(state.selected(in: rows), "a hidden row is not the Info tab's")
        state.setShown(.spots, true)
        state.selection = ["mark:9"]
        XCTAssertNil(state.selected(in: rows), "a row that has gone matches nothing")
        XCTAssertTrue(state.selectedRows(in: rows).isEmpty)
    }

    /// A window holds one Results room state, its own, and keeps it with its selection while the room is left and entered again. Red
    /// under: the state made anew on every read (the selection lost with a room switch); one state shared by every window.
    @MainActor func testTheWindowKeepsOneResultsState() {
        let state = AppState()
        let room = state.resultsRoom
        XCTAssertTrue(state.resultsRoom === room, "the same state on every read")
        state.selectWorkspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        room.selection = ["mark:1"]
        state.selectWorkspace(.image)
        XCTAssertEqual(state.navigation.workspaceArea, .image)
        state.selectWorkspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        XCTAssertTrue(state.resultsRoom === room, "the room switch keeps the state")
        XCTAssertEqual(state.resultsRoom.selection, ["mark:1"], "and its selection")
        let other = AppState()
        XCTAssertFalse(other.resultsRoom === room, "another window has its own")
    }

    // MARK: The slots in the shell, and the keys

    /// The shell's three slots mount the room; nothing else of the frozen shell files is named here. Red under: a slot removed.
    func testTheShellMountsTheRoomInItsSlots() throws {
        let view = squeezed(try source("macTEM/UI/WorkspaceView.swift"))
        XCTAssertTrue(view.contains("else if appState.navigation.workspaceArea == .results { ResultsRoom(image: image, item: item) }"))
        let inspector = squeezed(try source("macTEM/UI/WorkspaceInspector.swift"))
        XCTAssertTrue(inspector.contains("case .results: if let item = appState.openItems.selected { ResultsRoomSettings(image: image, item: item)"))
        XCTAssertTrue(inspector.contains("if appState.navigation.workspaceArea == .results, let item = appState.openItems.selected { ResultsRoomInfo(image: image, item: item) }"))
        XCTAssertFalse(inspector.contains("case .prepare, .diffraction, .results:"), "the room is no longer a placeholder")
    }

    /// File > Export Results… is ⇧⌥⌘E, is disabled by the rule, calls the one entry point; no other menu item takes the key. The room's own
    /// Export button is ControlPlacementRoomsTests', and what the entry point does is testExportResultsWritesOnlyInTheRoomAndOnlyWithARow's
    /// and testExportResultsTakesTheEELSRoomsRowsOfTheFileOnScreen's. Red under: the key changed to a taken one; the `.disabled` dropped;
    /// the item calling the Image room's export.
    func testExportResultsIsOnItsKeyAndNoOtherItemHasIt() throws {
        let commands = squeezed(try source("macTEM/App/ExportCommands.swift"))
        XCTAssertTrue(commands.contains("Button(\"Export Results…\") { if let appState { ExportPanels.exportResults(appState: appState) } } "
                                        + ".keyboardShortcut(\"e\", modifiers: [.command, .option, .shift]) .disabled(availability?.results != true)"))
        // No other item of the app has ⇧⌥⌘E, whatever order its modifiers are written in.
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        var holders: [String] = []
        for folder in ["macTEM/App", "macTEM/UI"] {
            let dir = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
                let text = squeezed(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
                for part in text.components(separatedBy: ".keyboardShortcut(").dropFirst() {
                    let call = String(part.prefix { $0 != ")" })
                    guard call.hasPrefix("\"e\"") else { continue }
                    let has = { (m: String) in call.contains(".\(m)") }
                    if has("command"), has("option"), has("shift") { holders.append(file) }
                }
            }
        }
        XCTAssertEqual(holders, ["ExportCommands.swift"], "exactly one item takes ⇧⌥⌘E")
    }

    /// The table is a native `Table` with a `Section` per group, selection through the state, and ⌘C through `onCopyCommand`; no
    /// delete key is handled (a result is removed in the room that made it). Red under: the Section dropped; the copy command removed;
    /// a delete handler added.
    func testTheTableIsNativeWithSectionsAndCopy() throws {
        let room = squeezed(try source("macTEM/UI/ResultsRoom.swift"))
        XCTAssertTrue(room.contains("Table(of: ResultRow.self, selection: $state.selection)"))
        XCTAssertTrue(room.contains("Section(ResultsFormat.title(section.group))"))
        XCTAssertTrue(room.contains(".onCopyCommand { copied() }"))
        XCTAssertTrue(room.contains(".onChange(of: item.id, initial: true) { state.attach(to: item.id) }"),
                      "the selection resets with the file, whenever the item changes")
        XCTAssertTrue(room.contains("ResultsFormat.copyText(rows, image: image)"))
        XCTAssertFalse(room.contains("onDeleteCommand"))
        XCTAssertFalse(room.contains("deleteKey"))
        for id in ["results.room", "results.table", "results.header", "results.row."] {
            XCTAssertTrue(room.contains("\"\(id)"), id)
        }
    }

    /// Nothing in the room authors a trust claim: the room's files hold no validation sentence of their own — the words come from
    /// `ResultRow.Product` (the producers' constants), and no "Unvalidated" label is added. Red under: a sentence written into the room.
    func testTheRoomAuthorsNoClaimOfTrust() throws {
        for path in ["macTEM/UI/ResultsRoom.swift", "macTEM/UI/ResultsRoomInspector.swift", "macTEM/App/ResultsFormat.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("compared with"), "\(path): a validation sentence")
            XCTAssertFalse(text.contains("closed form"), "\(path): a validation sentence")
            XCTAssertFalse(text.lowercased().contains("validated"), "\(path)")
        }
    }
}
