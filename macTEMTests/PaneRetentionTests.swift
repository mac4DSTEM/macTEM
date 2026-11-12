//
//  PaneRetentionTests.swift
//  A closed tab let go of its image only on paper: the 375 MB SEM TIFF's 1.5 GB of pixels stayed after Cmd-W (12 Nov memgraph: the
//  Float array <- a closure context <- HoverResponder <- the hosting view's EventBindingManager). SwiftUI keeps a view's hover and
//  gesture closures, and with them a copy of the view, for a while after the view is gone; a view that STORES the image keeps its
//  pixels alive in them. The Image room's pane and its marks overlay read the image from the item instead.
//
//  THE TRUTH: the views' own source. Red before: `let image: CalibratedImage` and `let canvas: CanvasPixels` on both views.
//

import XCTest

nonisolated final class PaneRetentionTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The stored properties of `type` in `text`: its lines at four spaces' indent that begin `let ` or `var ` and are not computed.
    private static func storedProperties(of type: String, in text: String) -> [String] {
        guard let start = text.range(of: "struct \(type):") else { return [] }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex
        return rest[..<end].split(separator: "\n").map(String.init).filter {
            ($0.hasPrefix("    let ") || $0.hasPrefix("    var ")) && !$0.hasSuffix("{")
        }
    }

    /// Every room's panes, the same rule (macTEM#574): the FFT, Results and Diffraction rooms stored the image too.
    func testNoRoomPaneStoresPixels() throws {
        let views = [("FFTRoom", "macTEM/UI/FFTRoom.swift"), ("FFTSourceImagePane", "macTEM/UI/FFTSourceImagePane.swift"),
                     ("ResultsRoom", "macTEM/UI/ResultsRoom.swift"), ("ResultsTable", "macTEM/UI/ResultsRoom.swift"),
                     ("DiffractionRoom", "macTEM/UI/DiffractionRoom.swift"), ("DiffractionHeader", "macTEM/UI/DiffractionRoom.swift"),
                     ("DiffractionPatternPane", "macTEM/UI/DiffractionRoom.swift"), ("DiffractionZoomCommands", "macTEM/UI/DiffractionRoom.swift")]
        for (type, path) in views {
            let stored = Self.storedProperties(of: type, in: try Self.source(path))
            XCTAssertFalse(stored.isEmpty, "\(type)'s properties were found")
            XCTAssertTrue(stored.allSatisfy { !$0.contains("CalibratedImage") && !$0.contains("CanvasPixels") }, "\(type): \(stored)")
        }
    }

    func testTheImagePaneStoresNoPixels() throws {
        let stored = Self.storedProperties(of: "ImagePane", in: try Self.source("macTEM/UI/ImagePane.swift"))
        XCTAssertFalse(stored.isEmpty, "the pane's properties were found")
        XCTAssertTrue(stored.allSatisfy { !$0.contains("CalibratedImage") && !$0.contains("CanvasPixels") }, "\(stored)")
    }

    func testTheMarksOverlayStoresNoPixels() throws {
        let stored = Self.storedProperties(of: "ImageMarksOverlay", in: try Self.source("macTEM/UI/ImageRoomMarks.swift"))
        XCTAssertFalse(stored.isEmpty, "the overlay's properties were found")
        XCTAssertTrue(stored.allSatisfy { !$0.contains("CalibratedImage") && !$0.contains("CanvasPixels") }, "\(stored)")
    }

    /// The Diffraction room's display canvas (4 B/px) goes with the room: on the 187 MP alite image it held 1.4 GB over the Image room for as
    /// long as the file was open (12 Nov drive). Red before: no release on leaving.
    func testTheDiffractionRoomLetsGoOfItsCanvasWhenLeft() throws {
        let text = try Self.source("macTEM/UI/DiffractionRoom.swift")
        XCTAssertTrue(text.contains(".onDisappear { view.presentation.releaseCanvas() }"))
    }

    /// No view body binds a file, a cube or an image to a name: a closure of that body (a text field's commit, a section's content, a hover) captures
    /// it, AppKit or SwiftUI keeps the closure, and the data outlives what replaced or closed it (12 Nov memgraph on 145_STEM: the two original cubes in
    /// one closure context reached from the EELS inspector's text field, 1.45 GB too many after Align). Views read numbers, or read the data where it is
    /// used, from the owner. `stack` is a reference the item releases on close, so binding it holds nothing. Red before: `let file = session.source`
    /// (EELS Fitting), `let image = session.source?.image` (EELS room), `if let source = session.source {` (EELS Info).
    func testNoViewBindsAFileOrACube() throws {
        let ui = Self.root.appendingPathComponent("macTEM/UI")
        let names = try FileManager.default.contentsOfDirectory(atPath: ui.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(names.count, 50, "the views were found")
        let pattern = try NSRegularExpression(
            pattern: #"^\s*(?:let|if let|guard let) \w+ = [\w.]*\b(?:session|item|appState\.\w+)\??\.(?:source|image|session\.image|workingLowLoss|workingCoreLoss|shownCoreLoss|fitCoreLoss|alignment|pixels)(?:\?\.(?:image|coreLoss))?\s*(?:\{|$|else)"#,
            options: [.anchorsMatchLines])
        var hits: [String] = []
        for name in names {
            let text = try String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)
            hits += pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { "\(name): " + (text as NSString).substring(with: $0.range) }
        }
        XCTAssertTrue(hits.isEmpty, "\(hits)")
        XCTAssertTrue(try Self.source("macTEM/UI/EELSRoomInspector.swift").contains("let file = EELSFileMicroscope(session.source)"))
    }
}
