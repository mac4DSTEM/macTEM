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
    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
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
}
