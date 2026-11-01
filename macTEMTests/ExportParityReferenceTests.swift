//
//  ExportParityReferenceTests.swift
//  The export-parity harness (tools/parity/export-parity, a scientific lane run before a tag and nightly) checks the Results
//  CSV's validation sentences against the products its reference names. That list is the reference's own, written by hand, so a
//  product added to `ResultRow.Product` without it fails the harness's base run long after the commit that added it (calibration
//  and ring, added with the Diffraction room's results). This unit test holds the two together on every run.
//

import XCTest
import TEMCore

nonisolated final class ExportParityReferenceTests: XCTestCase {

    /// The harness's reference.py, read beside this test file.
    private func reference() throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("tools/parity/export-parity/reference.py"), encoding: .utf8)
    }

    /// The names in the reference's `RESULTS_PRODUCTS = (...)` line, in order.
    private func referenceProducts() throws -> [String]? {
        let prefix = "RESULTS_PRODUCTS = ("
        guard let line = try reference().components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }),
              let close = line.lastIndex(of: ")") else { return nil }
        return line[line.index(line.startIndex, offsetBy: prefix.count)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// The reference names every product the app has, in the app's order, and no other. Red under: the reference's former
    /// hard-coded set of four (distance, angle, profile, spot) while the app has six.
    func testTheReferenceNamesEveryResultsProduct() throws {
        let products = try XCTUnwrap(referenceProducts(), "reference.py has no RESULTS_PRODUCTS = (...) line")
        XCTAssertEqual(products, ResultRow.Product.allCases.map(\.rawValue))
    }
}
