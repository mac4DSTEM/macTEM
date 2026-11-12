//
//  AccessibilityAuditJourney.swift
//  Xcode's accessibility audit (`performAccessibilityAudit`) on every room as Help > Open Demo Data fills it (#328): the welcome
//  canvas, the Image and FFT rooms on the lattice, Diffraction on the Au pattern, the EDS room on the EDX spectrum image, the EELS
//  room on its spectrum image, the Image room on the generated SEM image, the EDS room on the shipped SEM-EDS spectrum, Patterns and
//  Indexing on the nickel scan, Maps on the steel map, and the Results room last. Each room is audited for what VoiceOver needs:
//  every element says what it is (sufficient description), every element the audit sees on screen is in the accessibility tree
//  (element detection), and every control is big enough to hit (hit region). Contrast and clipped text are not audited here: they
//  follow the reader's appearance and the Metal panes draw pixels, not text.
//  The journey does not stop at a room's issues. It records each one with the room and the element's identifier and label, walks on,
//  and fails once at the end with the whole list, kept as an attachment beside the room's screenshot, so one run on the Mac lists
//  every issue to fix. The first run is expected to fail; the fixes it lists are what turn it green. Before every click the journey
//  checks that macTEM is frontmost (`openDemoData`, `requireFrontmost`). An audit reads the accessibility tree only: it moves no
//  pointer and types nothing.
//

import XCTest

nonisolated final class AccessibilityAuditJourney: Journey {
    /// What each room is audited for (the header says why contrast and clipped text are left out).
    private static var audited: XCUIAccessibilityAuditType { [.sufficientElementDescription, .elementDetection, .hitRegion] }

    /// One line per issue the audits found, by room, in the order they were found.
    @MainActor private var issues: [String] = []

    /// Audits what is on screen as `room` and records every issue it finds; none stops the journey here.
    @MainActor private func audit(_ room: String) throws {
        var found: [String] = []
        try app.performAccessibilityAudit(for: Self.audited) { issue in
            found.append("\(room): \(Self.line(issue))")
            return true   // recorded, not failed here: the journey fails once, at the end, with every room's issues
        }
        issues += found
        let report = XCTAttachment(string: found.isEmpty ? "no issues" : found.joined(separator: "\n"))
        report.name = "accessibility audit, \(room): \(found.count) issues"
        report.lifetime = .keepAlways
        add(report)
    }

    /// An issue as one line: the audit's short words, the element it names (its identifier and label, when it is still there), and
    /// the audit's long words.
    @MainActor private static func line(_ issue: XCUIAccessibilityAuditIssue) -> String {
        var element = "no element named"
        if let named = issue.element, named.exists {
            element = "identifier \"\(named.identifier)\", label \"\(named.label)\""
        }
        return "\(issue.compactDescription) (\(element)): \(issue.detailedDescription)"
    }

    @MainActor func testEveryRoomOnTheDemoDataPassesTheAccessibilityAudit() throws {
        try step("the welcome canvas") {
            launch()
            waitFor("welcome.tryDemo", timeout: 30)
            try audit("Welcome")
        }
        try step("the Image room on the lattice") {
            try openDemoData("Lattice Image")
            waitFor("image.view", timeout: 30)
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30), "the sidebar never listed Demo lattice")
            try audit("Image (lattice)")
        }
        try step("the FFT room on the lattice") {
            try requireFrontmost()
            bringToFront(room: "fft", in: "imaging", timeout: 10)
            waitFor("fft.room", timeout: 30)
            try audit("FFT (lattice)")
        }
        try step("the Diffraction room on the Au pattern") {
            try openDemoData("Au Diffraction Pattern")
            waitForDocument(named: "Demo Au pattern")
            bringToFront(room: "diffraction", in: "diffraction", timeout: 10)
            waitFor("diffraction.pane", timeout: 60)
            waitValue("diffraction.view", timeout: 60) { (Journey.number($0) ?? 0) > 0 }
            try audit("Diffraction (Au)")
        }
        try step("the EDS room on the EDX spectrum image") {
            try openDemoData("EDX Spectrum Image")
            waitFor("edx.room", timeout: 30)
            waitFor("maps.scaleBar.HAADF", timeout: 60)
            try audit("EDS (EDX spectrum image)")
        }
        try step("the EELS room on its spectrum image") {
            try openDemoData("EELS Spectrum Image")
            waitFor("eels.room", timeout: 30)
            let tile = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "t/\u{03BB} map")).firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 90), "the t/λ map never appeared")
            try audit("EELS (spectrum image)")
        }
        try step("the Image room on the generated SEM image") {
            try openDemoData("SEM Image (generated)")
            XCTAssertTrue(app.staticTexts["Demo SEM image.tif"].firstMatch.waitForExistence(timeout: 30), "the sidebar never listed the SEM image")
            waitFor("image.view", timeout: 30)
            try audit("Image (SEM)")
        }
        try step("the EDS room on the shipped SEM-EDS spectrum") {
            try openDemoData("SEM-EDS Spectrum (BAM TM002)")
            waitFor("edx.room", timeout: 30)
            waitStatus(containing: ["EDS_SEM_TM002.hspy"], timeout: 60)
            try audit("EDS (SEM-EDS spectrum)")
        }
        try step("the Patterns room on the nickel scan") {
            try openDemoData("Ni EBSD Patterns (kikuchipy)")
            waitFor("patterns.room", timeout: 60)
            waitFor("patterns.map", timeout: 60)
            waitFor("patterns.pattern", timeout: 60)
            try audit("Patterns (nickel)")
        }
        try step("the Indexing room on the nickel scan, before a run") {
            try requireFrontmost()
            waitFor("workspace.indexing", timeout: 30).click()
            waitFor("indexing.room", timeout: 30)
            waitFor("indexing.map", timeout: 30)
            try audit("Indexing (nickel, no run)")
        }
        try step("the Maps room on the steel map") {
            try openDemoData("Duplex Steel Orientation Map (orix)")
            waitForDocument(named: "sdss_ferrite_austenite")
            bringToFront(room: "maps", in: "ebsd", timeout: 10)
            waitFor("maps.room", timeout: 60)
            waitFor("maps.map", timeout: 60)
            try audit("Maps (steel)")
        }
        try step("the Results room") {
            try requireFrontmost()
            waitFor("workspace.results", timeout: 30).click()
            waitFor("results.room", timeout: 30)
            try audit("Results")
        }
        let report = XCTAttachment(string: issues.isEmpty ? "no issues" : issues.joined(separator: "\n"))
        report.name = "accessibility audit: \(issues.count) issues"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertTrue(issues.isEmpty, "\(issues.count) accessibility issues, all in the attachment; the first five: "
                                      + issues.prefix(5).joined(separator: " | "))
    }
}
