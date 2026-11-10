//
//  ExportPanelsTests.swift
//  Where Export Session Report's panel opens (`ExportPanels.defaultFolder(for:)`): in the folder of a file the session read, never inside
//  the app's own bundle, where the shipped demos live (an App Store install cannot be written to there, and a write would change the
//  signed bundle), nor on a generated demo's path, which does not exist; then the system chooses.
//  Red before the change: the panel took the first row file's folder as it was, so after Help > Open Demo Data > Ni EBSD Patterns it
//  opened in Contents/Resources/DemoData/nickel_ebsd_large.
//

import XCTest
import TEMSession
@testable import macTEM

nonisolated final class ExportPanelsTests: XCTestCase {

    /// A file on disk gives its folder; the shipped Ni EBSD demo (in the bundle), a generated demo and no file give nil; the report's
    /// panel takes the first folder its rows give. Mutation: the row file's folder taken as it is - red on the shipped demo.
    func testTheSessionReportPanelNeverOpensInsideTheAppBundle() throws {
        XCTAssertEqual(ExportPanels.defaultFolder(for: URL(fileURLWithPath: "/tmp/a/x.h5"))?.path, "/tmp/a")
        let shipped = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "the test host carries the shipped demo data")
        XCTAssertTrue(shipped.path.hasPrefix(Bundle.main.bundleURL.path), "the shipped demo lives in the app's bundle")
        XCTAssertNil(ExportPanels.defaultFolder(for: shipped))
        XCTAssertNil(ExportPanels.defaultFolder(for: DemoDocuments.ebsdURL))
        XCTAssertNil(ExportPanels.defaultFolder(for: nil))

        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("macTEM/App/ExportPanels.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("rows.filter { $0.kind != .export }.compactMap { defaultFolder(for: $0.file) }.first"),
                      "the session report's panel takes its folder from defaultFolder(for:)")
    }
}
