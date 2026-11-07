//
//  KikuchiOverlayExportTests.swift
//  The Kikuchi overlay's exports (#201): `Overlay CSV…` and `Pattern with Overlay…` from the Patterns room on the shipped nickel scan,
//  written to the journeys' folder without a panel; refused while the overlay is off; the band-width switch reaches the session's
//  overlay. Red before: neither export kind exists, and the session's overlay has no band edges.
//

import XCTest
import ImageIO
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class KikuchiOverlayExportTests: XCTestCase {

    @MainActor private func openNickel() async throws -> EBSDSession {
        let url = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "DemoData/ is not in the bundle")
        let session = EBSDSession()
        await session.open(url: url).value
        for _ in 0..<6000 where session.patternPresentation.canvas == nil || session.isMapping || session.isComputingMean {
            try await Task.sleep(for: .milliseconds(5))
        }
        return session
    }

    @MainActor func testTheOverlayExportsWriteTheirFiles() async throws {
        let session = try await openNickel()
        XCTAssertNotNil(session.patternPresentation.canvas, "the pattern never landed")
        XCTAssertTrue(session.canOverlay)
        XCTAssertTrue(session.canDrawBandWidth, "the demo file states 20 kV")
        let state = PatternsRoomState()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-export-\(UUID().uuidString)")
        var reports: [String] = []

        state.export(.overlayCSV, from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports.last, "Nothing to export yet: no Kikuchi overlay is on the pattern.")

        session.setOverlayOn(true)
        var settings = session.overlaySettings
        settings.bandWidth = true
        session.setOverlaySettings(settings)
        guard case .success(let overlay)? = session.overlay else { return XCTFail("no overlay on the demo nickel: \(String(describing: session.overlay))") }
        XCTAssertTrue(overlay.simulation.lines.allSatisfy { $0.edges.count == 2 }, "Band width draws both edges of every band")
        XCTAssertEqual(overlay.lineTheta?.count, overlay.simulation.lines.count)

        let position = try XCTUnwrap(session.patternPosition)
        let stem = "patterns_v2 overlay r\(position.row) c\(position.column)"
        state.export(.overlayCSV, from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports.last, "Exported \(stem).csv")
        let csv = try String(contentsOf: dir.appendingPathComponent("\(stem).csv"), encoding: .utf8)
        XCTAssertEqual(csv, KikuchiOverlay.csv(overlay))
        XCTAssertTrue(csv.hasPrefix("feature,h_or_u,k_or_v,l_or_w,label,x1_px,y1_px,x2_px,y2_px,theta_rad\nband,"))

        state.export(.overlayPNG, from: session, directory: dir) { reports.append($0) }
        let pngName = "patterns_v2 pattern r\(position.row) c\(position.column) overlay.png"
        XCTAssertEqual(reports.last, "Exported \(pngName)")
        let png = try Data(contentsOf: dir.appendingPathComponent(pngName))
        let image = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let s = KikuchiOverlayExport.scale(width: 60, height: 60)
        XCTAssertEqual(s, 8)
        XCTAssertEqual(image.width, 60 * s)
        XCTAssertEqual(image.height, 60 * s)

        // The overlay is in the picture: the enlarged plain pattern differs from it, and the accent blue is drawn where a band runs.
        let plain = try PatternsRoomState.patternPNG(canvas: try XCTUnwrap(session.patternPresentation.canvas), presentation: session.patternPresentation,
                                                     dataset: try XCTUnwrap(session.dataset), fileName: "patterns_v2.h5", position: position)
        var empty = overlay
        empty.simulation.lines = []
        empty.simulation.zoneAxes = []
        empty.lineLabels = []
        let bare = try XCTUnwrap(KikuchiOverlayExport.png(patternPNG: plain, overlay: empty, settings: settings))
        let drawn = try rgba(png), background = try rgba(bare)
        XCTAssertEqual(drawn.count, background.count)
        let changed = stride(from: 0, to: drawn.count, by: 4).filter { drawn[$0] != background[$0] || drawn[$0 + 2] != background[$0 + 2] }.count
        XCTAssertGreaterThan(changed, 2000, "the bands, edges and labels change the picture")
        let blue = stride(from: 0, to: drawn.count, by: 4).filter { drawn[$0 + 2] > 200 && drawn[$0] < 80 && drawn[$0 + 1] > 90 && drawn[$0 + 1] < 170 }.count
        XCTAssertGreaterThan(blue, 500, "the accent colour is on the bands")
    }

    /// The pixels of a PNG as sRGB RGBA bytes.
    private func rgba(_ png: Data) throws -> [UInt8] {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
