//
//  ParticleViewTests.swift
//  The Particles view's presentation: the pointer readout names the object under the pointer while the objects are shown, the object
//  table is its own window (not a sheet over the inspector), and the Particles section sits above Measure in the Image room's inspector.
//  The numbers are the compute's (`ParticleTests`); here only what the room shows of them.
//

import XCTest
import ImagoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class ParticleViewTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private static func image(scale: Double = 0.5) -> CalibratedImage {
        let axis = AxisCalibration(scale: scale, unit: "nm")
        return CalibratedImage(width: ParticleTests.width, height: ParticleTests.height, pixels: ParticleTests.planted(), x: axis, y: axis,
                               fileName: "p.dm4", source: "", voltage: nil)
    }

    // MARK: The pointer readout

    /// Over a found object the readout adds the object's number and its length and width in the scale's unit, the kit's moments times the
    /// pixel size; off the objects, or with no report, it is the pixel readout alone. Red under: the readout ignoring the report.
    func testTheReadoutNamesTheObjectUnderThePointer() throws {
        let image = Self.image()
        let report = try ParticleCompute.analyse(pixels: image.pixels, width: image.width, height: image.height, settings: ParticleSettings())
        let scale = ParticleCompute.scale(of: image)
        let at = ImagePoint(x: 30, y: 30)
        let label = report.labels.labels[30 * image.width + 30]
        XCTAssertGreaterThan(label, 0, "the planted ellipse is under (30, 30)")
        let object = try XCTUnwrap(report.objects.first { $0.id == label })
        let text = try XCTUnwrap(ImageReadout.text(image, at: at, particles: report, scale: scale))
        XCTAssertEqual(text, try XCTUnwrap(ImageReadout.text(image, at: at)) + " · object \(label): "
                       + "\(ParticleFormat.number(object.moments.lengthPx * 0.5)) × \(ParticleFormat.number(object.moments.widthPx * 0.5)) nm")
        let background = ImagePoint(x: 2, y: 70)
        XCTAssertEqual(ImageReadout.text(image, at: background, particles: report, scale: scale), ImageReadout.text(image, at: background))
        XCTAssertEqual(ImageReadout.text(image, at: at, particles: nil, scale: scale), ImageReadout.text(image, at: at))
        XCTAssertNil(ImageReadout.text(image, at: ImagePoint(x: -3, y: 4), particles: report, scale: scale), "off the pixels")
    }

    /// An object on the edge says so, as the table's note does.
    func testTheReadoutMarksAnEdgeObject() throws {
        let image = Self.image()
        let report = try ParticleCompute.analyse(pixels: image.pixels, width: image.width, height: image.height, settings: ParticleSettings())
        let text = try XCTUnwrap(ImageReadout.text(image, at: ImagePoint(x: 98, y: 42), particles: report, scale: ParticleCompute.scale(of: image)))
        XCTAssertTrue(text.hasSuffix(" nm (edge)"), text)
    }

    /// The pane asks for the readout with the file's report only while its objects are shown. Red under: the pane's call left as before.
    func testThePaneReadsTheObjectsWhileTheyAreShown() throws {
        let pane = squeezed(try source("macTEM/UI/ImagePane.swift"))
        XCTAssertTrue(pane.contains("ImageReadout.text(image, at: geometry.imagePoint(atPanePoint: p), particles: item.particles.showsObjects ? item.particles.report : nil, scale: ParticleCompute.scale(of: image))"))
    }

    // MARK: The table is a window

    /// The object table opens in its own window, so it stays beside the image while rows are selected; the inspector no longer presents a
    /// sheet. Red under: the sheet back.
    func testTheObjectTableIsAWindow() throws {
        let section = squeezed(try source("macTEM/UI/ImageRoomParticles.swift"))
        XCTAssertTrue(section.contains("Button(\"Object Table…\") { openWindow(id: ParticleTableWindow.id) }"))
        XCTAssertFalse(section.contains(".sheet(isPresented: $showTable)"))
        let app = squeezed(try source("macTEM/App/macTEMApp.swift"))
        XCTAssertTrue(app.contains("Window(\"Objects\", id: ParticleTableWindow.id) { ParticleTableWindow(appState: appState) }"))
        XCTAssertEqual(ParticleTableWindow.id, "particles")
    }

    // MARK: The section's place

    /// Particles sits above Measure in the Image room's Settings, so it is in view without scrolling past the measuring tools. Red under:
    /// the old order.
    func testParticlesSitsAboveMeasure() throws {
        let inspector = try source("macTEM/UI/ImageRoomInspector.swift")
        let particles = try XCTUnwrap(inspector.range(of: "ImageRoomParticlesSection("))
        let measure = try XCTUnwrap(inspector.range(of: "ImageRoomMeasureSection("))
        XCTAssertLessThan(particles.lowerBound, measure.lowerBound)
    }
}
