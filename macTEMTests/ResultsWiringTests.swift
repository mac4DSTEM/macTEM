//
//  ResultsWiringTests.swift
//  The Results room's call sites: the room is built and can be entered, the shell's slots mount it (the room switch in
//  `WorkspaceView`, the Settings and Info switches in `WorkspaceInspector`), `AppState` composes its state in one line, File > Export
//  Results… is on ⇧⌥⌘E (a key no other item has) and enabled by `ExportSnapshot.availability`, the snapshot of the selected file is what
//  the panel's OK writes (a real file read back), the room's state resets its selection with a file switch, and the table is a
//  native `Table` with a `Section` per group and ⌘C through `onCopyCommand`. Each fix is right in its pure function while reverting
//  the one line that uses it leaves every pure test green; these go red when that line reverts. Tier 2.
//
//  Mutations sampled (each alone, the named test went red): `isBuilt` without `.results`; the Export Results… item without its
//  `.disabled`; the room's switch branch removed; the availability enabled outside the Results room; the snapshot taking all open files;
//  the selection kept across files.
//

import ImagoCore
import XCTest
import AppKit
#if canImport(TEMCore)
import FormatoCore
import TEMCore
import TEMSession
#endif
@testable import macTEM

nonisolated final class ResultsWiringTests: XCTestCase {

    private static let software = "macTEM 0.1.0 (1)"

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

    /// The rooms 1.0 ships, every one built, in the order of the work; Prepare is not among them (the owner, 2026-10-23: "It shouldn't ship
    /// in macTEM"). Red under: Prepare back in the list, a room listed but not built, Results not ⌘6.
    @MainActor func testTheResultsRoomIsBuiltAndCanBeEntered() {
        XCTAssertEqual(WorkspaceArea.allCases, [.image, .fft, .edx, .eels, .diffraction, .results])
        XCTAssertNil(WorkspaceArea(rawValue: "prepare"), "a window that saved Prepare opens in the default room")
        XCTAssertTrue(WorkspaceArea.allCases.allSatisfy(\.isBuilt))
        let state = AppState()
        state.selectWorkspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        state.selectWorkspace(.diffraction)
        XCTAssertEqual(state.navigation.workspaceArea, .diffraction)
        XCTAssertEqual(WorkspaceArea.image.shortcutDigit, "1")
        XCTAssertEqual(WorkspaceArea.results.shortcutDigit, "6", "Results is the last of the rooms, after EDS, EELS and Diffraction")
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

    // MARK: The slots in the shell, and the keys

    /// The shell's three slots mount the room and `AppState` composes its state in one line; nothing else of the frozen shell files is
    /// named here. Red under: a slot removed; the state composed twice.
    func testTheShellMountsTheRoomInItsSlots() throws {
        let view = squeezed(try source("macTEM/UI/WorkspaceView.swift"))
        XCTAssertTrue(view.contains("else if appState.navigation.workspaceArea == .results { ResultsRoom(image: image, item: item) }"))
        let inspector = squeezed(try source("macTEM/UI/WorkspaceInspector.swift"))
        XCTAssertTrue(inspector.contains("case .results: if let item = appState.openItems.selected { ResultsRoomSettings(image: image, item: item)"))
        XCTAssertTrue(inspector.contains("if appState.navigation.workspaceArea == .results, let item = appState.openItems.selected { ResultsRoomInfo(image: image, item: item) }"))
        XCTAssertFalse(inspector.contains("case .prepare, .diffraction, .results:"), "the room is no longer a placeholder")
        let app = try source("macTEM/App/AppState.swift")
        XCTAssertEqual(app.components(separatedBy: "ResultsRoomState()").count - 1, 1, "AppState composes the state in one line")
        XCTAssertTrue(app.contains("let resultsRoom = ResultsRoomState()"))
    }

    /// File > Export Results… is ⇧⌥⌘E, is disabled by the rule, calls the one entry point; no other menu item takes the key. Red under:
    /// the key changed to a taken one; the `.disabled` dropped; the item calling the Image room's export.
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
        let panels = squeezed(try source("macTEM/App/ExportPanels.swift"))
        XCTAssertTrue(panels.contains("static func exportResults(appState: AppState) { guard ExportSnapshot.availability(of: appState).results,"
                                        + " let snapshot = ExportSnapshot.resultsSnapshot(in: appState.openItems)"))
        let inspector = squeezed(try source("macTEM/UI/ResultsRoomInspector.swift"))
        XCTAssertTrue(inspector.contains("ExportPanels.exportResults(appState: appState) } .disabled(!availability.results)"))
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
        XCTAssertTrue(squeezed(try source("macTEM/UI/ResultsRoomInspector.swift")).contains(".accessibilityIdentifier(\"results.export\")"))
    }

    /// Nothing in the room authors a trust claim: the room's files hold no validation sentence of their own — the words come from
    /// `ResultRow.Product` (the producers' constants). Red under: a sentence written into the room.
    func testTheRoomAuthorsNoClaimOfTrust() throws {
        for path in ["macTEM/UI/ResultsRoom.swift", "macTEM/UI/ResultsRoomInspector.swift", "macTEM/App/ResultsFormat.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("compared with"), "\(path): a validation sentence")
            XCTAssertFalse(text.contains("closed form"), "\(path): a validation sentence")
            XCTAssertFalse(text.lowercased().replacingOccurrences(of: "unvalidated", with: "").contains("validated"), "\(path)")
        }
    }
}
