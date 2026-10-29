//
//  BuildSettingsTests.swift
//  Build settings the project file must keep. Metal fast math stays off: a Metal path is checked against its float64 CPU
//  reference at the upstream float32 tolerance, and fast math reorders and approximates float operations that check relies on.
//

import XCTest

nonisolated final class BuildSettingsTests: XCTestCase {

    /// The project file, read beside this test file.
    private func projectFile() throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("macTEM.xcodeproj/project.pbxproj"), encoding: .utf8)
    }

    /// Every configuration sets `MTL_FAST_MATH = NO`, and none sets it to YES. Red under: Xcode's template default (YES).
    func testMetalFastMathIsOffInEveryConfiguration() throws {
        let project = try projectFile()
        XCTAssertFalse(project.contains("MTL_FAST_MATH = YES;"), "Metal fast math is on in a configuration")
        XCTAssertEqual(project.components(separatedBy: "MTL_FAST_MATH = NO;").count - 1, 3,
                       "the project's Debug, Release and Develop configurations each set MTL_FAST_MATH = NO")
    }
}
