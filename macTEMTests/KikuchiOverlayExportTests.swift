//
//  KikuchiOverlayExportTests.swift
//  The Kikuchi overlay's exports (#201): `Overlay CSV…` and `Pattern with Overlay…` from the Patterns room on the shipped nickel scan,
//  written to the journeys' folder without a panel; refused while the overlay is off; the band-width switch reaches the session's
//  overlay; Kinematical carries the point's simulated pattern and the master pattern picture; the picture carries its Title, Software
//  and Description as text chunks (#331). Red before: neither export kind exists, and the session's overlay has neither band edges
//  nor a simulation; before #331 the Description was ImageIO's XMP packet and there was no Title.
//

import XCTest
import FormatoCore
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
        // Title, Software and what is drawn are text chunks, as the Image room's PNGs carry theirs (#331).
        let text = try FormatoPNG.textEntries(in: png)
        XCTAssertEqual(text.first { $0.keyword == "Title" }?.value, "patterns_v2.h5")
        XCTAssertEqual(text.first { $0.keyword == "Software" }?.value, "macTEM")
        let bands = overlay.simulation.lines.count, axes = overlay.simulation.zoneAxes.count
        XCTAssertEqual(text.first { $0.keyword == "Description" }?.value,
                       "Kikuchi overlay of \(overlay.phase): \(bands) bands, \(axes) zone axes; pattern enlarged 8x; macTEM")

        // The overlay is in the picture: the enlarged plain pattern differs from it, and the accent blue is drawn where a band runs.
        let plain = try PatternsRoomState.patternPNG(canvas: try XCTUnwrap(session.patternPresentation.canvas), presentation: session.patternPresentation,
                                                     dataset: try XCTUnwrap(session.dataset), fileName: "patterns_v2.h5", position: position)
        var empty = overlay
        empty.simulation.lines = []
        empty.simulation.zoneAxes = []
        empty.lineLabels = []
        let bare = try XCTUnwrap(KikuchiOverlayExport.png(patternPNG: plain, fileName: "patterns_v2.h5", overlay: empty, settings: settings))
        let drawn = try rgba(png), background = try rgba(bare)
        XCTAssertEqual(drawn.count, background.count)
        var changed = 0, blue = 0
        for k in stride(from: 0, to: drawn.count, by: 4) {
            let r = drawn[k], g = drawn[k + 1], b = drawn[k + 2]
            if r != background[k] || b != background[k + 2] { changed += 1 }
            if Self.isAccent(r: r, g: g, b: b) { blue += 1 }
        }
        XCTAssertGreaterThan(changed, 2000, "the bands, edges and labels change the picture")
        XCTAssertGreaterThan(blue, 500, "the accent colour is on the bands")
    }

    /// The export's accent blue (sRGB 0.04, 0.52, 1), allowing for the halo's blend at the strokes' edges.
    private static func isAccent(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let blueEnough: Bool = b > 200
        let lowRed: Bool = r < 80
        let midGreen: Bool = g > 90 && g < 170
        return blueEnough && lowRed && midGreen
    }

    /// Kinematical (#201): the overlay carries the point's kinematical simulation in the detector's shape, the inspector's master
    /// pattern picture exists for the point's phase, and the picture with the overlay is written with the simulation blended in.
    @MainActor func testKinematicalOverlayThroughTheSession() async throws {
        let session = try await openNickel()
        session.setOverlayOn(true)
        var settings = session.overlaySettings
        XCTAssertNil(session.overlayMasterPicture, "no master pattern picture while Kinematical is off")
        settings.kinematical = true
        settings.blend = 0.7
        session.setOverlaySettings(settings)
        guard case .success(let overlay)? = session.overlay else { return XCTFail("no overlay: \(String(describing: session.overlay))") }
        let simulated = try XCTUnwrap(overlay.simulated, "Kinematical carries the simulated pattern")
        XCTAssertEqual(simulated.count, 60 * 60)
        XCTAssertGreaterThan(simulated.max() ?? 0, simulated.min() ?? 0, "bands cross the pattern")
        XCTAssertNotNil(KikuchiOverlayLayer.simulatedImage(overlay))
        let picture = try XCTUnwrap(session.overlayMasterPicture)
        XCTAssertEqual(picture.side, 201)
        XCTAssertEqual(picture.phase, "ni")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-kinematical-\(UUID().uuidString)")
        var reports: [String] = []
        PatternsRoomState().export(.overlayPNG, from: session, directory: dir) { reports.append($0) }
        XCTAssertTrue(reports.last?.hasPrefix("Exported ") == true, reports.last ?? "")
        settings.kinematical = false
        session.setOverlaySettings(settings)
        guard case .success(let plain)? = session.overlay else { return XCTFail("no overlay") }
        XCTAssertNil(plain.simulated, "Geometrical draws no simulated pattern")
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
