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

    /// The unit tests run optimised. Xcode's own ⌘U builds the Test action at -Onone and that setting reaches the SpectroKit
    /// package, whose fits are then about 20 times slower (the EDX tests take minutes). `tools/run-tests.sh unit` passes
    /// SWIFT_OPTIMIZATION_LEVEL=-O on the command line, which reaches every target, this one too: an -Onone build of this
    /// test is a run that did not come through the script. Red under: `xcodebuild test` without that override (or ⌘U).
    func testTheUnitTestsAreRunThroughTheScriptNotCommandU() {
        XCTAssertFalse(_isDebugAssertConfiguration(),
                       "These tests were built at -Onone (⌘U): run tools/run-tests.sh unit, which builds them and SpectroKit optimised.")
    }
}
