//
//  ExportFileTests.swift
//  What `ExportFile.write` must never do (archive: roadmap-registrations-2026-10-15.md V1-10 slice 1; Gate B round 2, finding F6): replace a FOLDER at the
//  destination. `replaceItemAt` swaps a folder for the file and deletes everything in it, so the writer refuses a folder
//  by name and leaves it as it was. (Writing over an existing file, to a new one, and leaving nothing beside the
//  destination are ImageExportRenderTests'.)
//  Mutation the test was broken by: the folder guard removed from `ExportFile.write` — the folder became a plain file
//  and its contents were gone.
//

import XCTest
import TEMCore

nonisolated final class ExportFileTests: XCTestCase {

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A destination that is a FOLDER is refused and the folder is left as it was, with what it held (`replaceItemAt` would
    /// otherwise swap it for the file and delete the folder with everything in it). Red on an unguarded `write`.
    func testAnExportNeverReplacesAFolder() throws {
        let directory = try scratch()
        let folder = directory.appendingPathComponent("results.csv", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        XCTAssertThrowsError(try ExportFile.write(Data("a,b\n".utf8), to: folder)) { error in
            guard case ExportFile.Failure.writeFailed(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("folder"), reason)
            XCTAssertTrue(reason.contains("results.csv"), "the sentence names the folder: \(reason)")
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("inside.txt"), encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["results.csv"],
                       "nothing was left beside the folder")
    }
}
