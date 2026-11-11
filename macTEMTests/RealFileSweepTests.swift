//
//  RealFileSweepTests.swift
//  The real-file sweep: every file under the owner's data folder ($MACEM_DATA, else data/ beside the repository) whose extension
//  macEM claims (`FileRouting.openableExtensions`) is opened as a double-click opens it, in a window state of its own, one file at
//  a time. Each must either land in a room that then holds its data, or be refused in plain words: the sentence names the file
//  and carries no internals (an error domain, an HDF5 call or path in quotes, a Swift type). A file that opens with neither, or
//  is still opening after the wait, fails too.
//  Opt-in and never on a runner: `tools/run-tests.sh real-files` (MACTEM_REAL_FILES=1; the real-data flag does not start it).
//  MACTEM_SWEEP_FOLDERS (comma-separated, relative to the data folder) narrows the walk; MACTEM_SWEEP_SECONDS is the wait per file
//  (default 180). Writes $TMPDIR/macem-real-files.tsv, one row per file as it goes (so a crash leaves the rows before it), and
//  $TMPDIR/macem-real-files-summary.txt: the counts per room and every refusal and failure by kind with its sentence, the file's
//  name replaced by <file>, so the summary can be quoted without the owner's file names.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class RealFileSweepTests: XCTestCase {

    struct Row {
        var relative: String
        var kind: String
        /// landed, refused, nothing (opened without data or a sentence), or timeout.
        var result: String
        var room: String
        var seconds: Double
        var message: String
        /// Why the sentence is not plain words, or nil.
        var problem: String?
        var passes: Bool { (result == "landed" || result == "refused") && problem == nil }
        var tsv: String {
            [relative, kind, result, room, String(format: "%.1f", seconds), problem ?? "", message]
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " / ") }
                .joined(separator: "\t")
        }
    }

    /// Its own variable, not the real-data flag: the walk over the whole data folder is far longer than the other real-data tests.
    private func optIn() throws {
        guard ProcessInfo.processInfo.environment["MACTEM_REAL_FILES"] == "1" else {
            throw XCTSkip("opt-in: tools/run-tests.sh real-files (TEST_RUNNER_MACTEM_REAL_FILES=1)")
        }
    }

    /// Every file under `root` (or under its `folders`) with an extension macEM claims, in path order. Hidden files, AppleDouble
    /// files and package contents are left out.
    static func files(under root: URL, folders: [String]?) -> [URL] {
        let claimed = Set(FileRouting.openableExtensions.map { $0.lowercased() })
        let starts = folders.map { $0.map { root.appendingPathComponent($0) } } ?? [root]
        var found: [URL] = []
        for start in starts {
            guard let walk = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walk where claimed.contains(url.pathExtension.lowercased()) {
                guard !url.lastPathComponent.hasPrefix("._"),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The internals a sentence for a person never carries.
    static let internals = ["Error Domain=", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "HDF5 failed", "H5D", "H5F", "H5G", "Optional(",
                            "(null)", "Swift.", "DecodingError", "errno", "dataset '", "has no '", "Something went wrong"]

    /// Why `sentence`, the refusal of `file`, is not plain words, or nil.
    static func problem(_ sentence: String, file: String) -> String? {
        guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "empty" }
        if !sentence.contains(file) { return "does not name the file" }
        let rest = sentence.replacingOccurrences(of: file, with: "<file>")   // a file's own name is not an internal
        if let hit = internals.first(where: rest.contains) { return "carries \"\(hit)\"" }
        if rest.range(of: #"'/?[A-Za-z0-9 _]+/[A-Za-z0-9 _/]+'"#, options: .regularExpression) != nil { return "quotes an HDF5 path" }
        return nil
    }

    /// The room the window shows, and whether it holds the file's data.
    @MainActor static func room(_ state: AppState) -> (name: String, holds: Bool) {
        let area = state.navigation.workspaceArea
        let holds = switch area {
        case .maps: state.maps.document != nil
        case .patterns, .indexing: state.ebsd.dataset != nil
        case .edx: state.edx.source != nil
        case .eels: state.eels.source != nil
        case .image, .fft, .diffraction, .results: state.hasImage
        }
        return (area.rawValue, holds)
    }

    @MainActor static func busy(_ state: AppState) -> Bool {
        state.opensInFlight > 0 || state.edx.isOpening || state.eels.isOpening || state.ebsd.isOpening || state.maps.isOpening
            || state.imageSession.isLoading
    }

    /// Opens `url` as Finder's double-click does (`AppState.open(urls:)`) and waits until a sentence comes, or the room holds the
    /// data with nothing still opening, or nothing is opening for two seconds with no data and no sentence, or `wait` runs out.
    @MainActor static func open(_ url: URL, root: URL, wait: Double) async -> Row {
        let state = AppState(launch: LaunchOptions(arguments: []))
        let start = Date()
        await state.open(urls: [url])?.value
        var result = "timeout", idleSince: Date?
        while Date().timeIntervalSince(start) < wait {
            if state.errorMessage != nil { result = "refused"; break }
            let busy = Self.busy(state), holds = Self.room(state).holds
            if holds, !busy { result = "landed"; break }
            if busy { idleSince = nil } else if let idle = idleSince {
                if Date().timeIntervalSince(idle) > 2 { result = "nothing"; break }
            } else { idleSince = Date() }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let message = state.errorMessage ?? ""
        let room = Self.room(state)
        return Row(relative: relative, kind: url.pathExtension.lowercased(), result: result,
                   room: result == "refused" ? "-" : room.name, seconds: Date().timeIntervalSince(start), message: message,
                   problem: result == "refused" ? Self.problem(message, file: url.lastPathComponent) : nil)
    }

    /// `message` with the file's name, its stem and its folder's name replaced by placeholders, for the summary.
    static func anonymised(_ message: String, _ relative: String) -> String {
        let path = relative as NSString
        var text = message.replacingOccurrences(of: path.lastPathComponent, with: "<file>")
        let stem = (path.lastPathComponent as NSString).deletingPathExtension
        if stem.count > 2 { text = text.replacingOccurrences(of: stem, with: "<file>") }
        let folder = (path.deletingLastPathComponent as NSString).lastPathComponent
        if folder.count > 2 { text = text.replacingOccurrences(of: folder, with: "<folder>") }
        return text
    }

    static func summary(_ rows: [Row]) -> String {
        var lines = ["macEM real-file sweep: \(rows.count) files, \(rows.filter(\.passes).count) pass, \(rows.filter { !$0.passes }.count) fail",
                     "File names are replaced by <file> and their folders by <folder>.", "", "Landed, per room:"]
        let landed = Dictionary(grouping: rows.filter { $0.result == "landed" }, by: \.room)
        for (room, group) in landed.sorted(by: { $0.key < $1.key }) {
            let kinds = Dictionary(grouping: group, by: \.kind).map { "\($0.value.count) .\($0.key)" }.sorted().joined(separator: ", ")
            lines.append("  \(room): \(group.count) (\(kinds))")
        }
        lines += ["", "Refused in plain words (kind, count, sentence):"]
        let plain = Dictionary(grouping: rows.filter { $0.result == "refused" && $0.problem == nil }) { "\($0.kind)\t\(anonymised($0.message, $0.relative))" }
        for (key, group) in plain.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            lines.append("  .\(parts[0]) x\(group.count): \(parts.count > 1 ? parts[1] : "")")
        }
        lines += ["", "Failures (kind, result, room, why, sentence):"]
        for row in rows where !row.passes {
            lines.append("  .\(row.kind) \(row.result) in \(row.room), \(String(format: "%.1f", row.seconds)) s\(row.problem.map { ", \($0)" } ?? ""): "
                         + anonymised(row.message, row.relative))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor func testEveryRealFileLandsInARoomOrIsRefusedInPlainWords() async throws {
        try optIn()
        let root = URL(fileURLWithPath: RealDataFolder.path).standardizedFileURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "no data folder at \(root.path)")
        let environment = ProcessInfo.processInfo.environment
        let folders = environment["MACTEM_SWEEP_FOLDERS"].flatMap { list -> [String]? in
            let names = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return names.isEmpty ? nil : names
        }
        let wait = environment["MACTEM_SWEEP_SECONDS"].flatMap(Double.init) ?? 180
        let files = Self.files(under: root, folders: folders)
        XCTAssertFalse(files.isEmpty, "no file macEM claims under \(root.path)")
        let table = NSTemporaryDirectory() + "macem-real-files.tsv"
        FileManager.default.createFile(atPath: table, contents: Data("file\tkind\tresult\troom\tseconds\twhy\tsentence\n".utf8))
        let handle = FileHandle(forWritingAtPath: table)
        defer { try? handle?.close() }
        var rows: [Row] = []
        for (index, url) in files.enumerated() {
            let row = await Self.open(url, root: root, wait: wait)
            rows.append(row)
            handle?.seekToEndOfFile()
            handle?.write(Data((row.tsv + "\n").utf8))
            print("SWEEP \(index + 1)/\(files.count) \(row.result) \(row.room) \(String(format: "%.1f", row.seconds)) s .\(row.kind)")
            if !row.passes { XCTFail("\(row.relative): \(row.result) in \(row.room)\(row.problem.map { ", \($0)" } ?? ""): \(row.message)") }
        }
        let summary = Self.summary(rows)
        try summary.write(toFile: NSTemporaryDirectory() + "macem-real-files-summary.txt", atomically: true, encoding: .utf8)
        print(summary)
    }

    /// The plain-words rule itself, on sentences the app writes and on ones it must not.
    func testThePlainWordsRule() {
        XCTAssertNil(Self.problem("x.h5oina holds neither EBSD patterns nor orientations: its EBSD data has no Euler angles.", file: "x.h5oina"))
        XCTAssertEqual(Self.problem("The file is not a format macEM opens.", file: "x.dm4"), "does not name the file")
        XCTAssertEqual(Self.problem("x.h5 could not find patterns in the expected dataset 'EBSD/Data/RawPatterns'", file: "x.h5"),
                       "carries \"dataset '\"")
        XCTAssertEqual(Self.problem("x.h5: the header has no 'Pattern Height' dataset", file: "x.h5"), "carries \"has no '\"")
        XCTAssertEqual(Self.problem("x.emd: The operation couldn’t be completed. (Error Domain=NSCocoaErrorDomain Code=257)", file: "x.emd"),
                       "carries \"Error Domain=\"")
        XCTAssertEqual(Self.problem("x.h5 cannot be read at '/Scan 1/EBSD/Data'", file: "x.h5"), "quotes an HDF5 path")
        XCTAssertEqual(Self.problem("  ", file: "x.h5"), "empty")
        XCTAssertEqual(Self.anonymised("scan_17.h5 in Sample A: no patterns (scan_17)", "Sample A/scan_17.h5"),
                       "<file> in <folder>: no patterns (<file>)")
    }
}
