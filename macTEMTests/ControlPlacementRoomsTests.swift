// Control placement standard in the Results, Image, Diffraction and FFT rooms (2026-10-22): an Export section of plain buttons
// with the reason as help, segmented controls that are MacEMUI's full-width `SegmentedPicker` with no leading label, the
// wheel zooming the pictures. Pinned at the source, in the rooms' existing style (`FFTRoomWiringTests.squeezedUI`).
import XCTest
import TEMCore
import TEMSession
import ShellMetal
@testable import macTEM

nonisolated final class ControlPlacementRoomsTests: XCTestCase {

    private func ui(_ name: String) throws -> String { try FFTRoomWiringTests.squeezedUI(name) }

    /// The Results room's export is one plain full-width button in an Export section, disabled with its reason as help, no pull-down.
    /// Red under: the adaptive menu back, the reason in a menu title, the identifier lost.
    func testResultsExportIsOnePlainButton() throws {
        let source = try ui("ResultsRoomInspector.swift")
        XCTAssertTrue(source.contains("InspectorSection(\"Export\") { InspectorActionRow { Button(ResultsExportButton.title) { ExportPanels.exportResults(appState: appState) } .disabled(!availability.results)"))
        XCTAssertTrue(source.contains(".help(ResultsExportButton.help(enabled: availability.results, hasRows: !rows.isEmpty)) .accessibilityIdentifier(\"results.export\")"))
        XCTAssertFalse(source.contains("InspectorAdaptiveMenu("), "no pull-down")
        XCTAssertEqual(ResultsExportButton.title, "All results as CSV…")
        XCTAssertEqual(ResultsExportButton.help(enabled: false, hasRows: false), "nothing measured yet")
        XCTAssertEqual(ResultsExportButton.help(enabled: false, hasRows: true), "a read is running")
        XCTAssertFalse(ResultsExportButton.help(enabled: true, hasRows: true).isEmpty)
    }

    /// Every segmented control of the Image room is the full-width `SegmentedPicker`, none a `Picker` in a row; ids kept.
    /// Red under: a `.pickerStyle(.segmented)` back, a leading `InspectorRow` label, an identifier dropped.
    func testImageRoomSegmentedControlsAreSegmentedPickers() throws {
        let measure = try ui("ImageRoomMeasure.swift")
        XCTAssertTrue(measure.contains("SegmentedPicker(label: \"Tool\""))
        XCTAssertTrue(measure.contains(".accessibilityIdentifier(\"image.tool\")"))
        let particles = try ui("ImageRoomParticles.swift")
        XCTAssertTrue(particles.contains("SegmentedPicker(label: \"Objects\""))
        XCTAssertTrue(particles.contains(".accessibilityIdentifier(\"particles.polarity\")"))
        XCTAssertTrue(particles.contains("SegmentedPicker(label: \"Connectivity\""))
        XCTAssertFalse(particles.contains("InspectorRow(\"Objects\")") || particles.contains("InspectorRow(\"Connectivity\")"), "no leading label")
        for name in ["ImageRoomMeasure.swift", "ImageRoomParticles.swift", "DiffractionRoomInspector.swift"] {
            XCTAssertFalse(try ui(name).contains(".pickerStyle(.segmented)"), "\(name): a segmented control is a SegmentedPicker")
        }
    }

    /// The Diffraction room's Tools are a section of their own holding the full-width Ring/Spot picker; Display keeps View and the
    /// log switch. Red under: the tool back in Display, a labelled row, the section missing from the room's list, the id lost.
    func testDiffractionToolsHaveTheirOwnSection() throws {
        let source = try ui("DiffractionRoomInspector.swift")
        XCTAssertTrue(source.contains("InspectorSection(\"Tools\") { SegmentedPicker(label: \"Tool\", items: [(DiffractionViewState.Tool.ring, .title(\"Ring\")), (.spot, .title(\"Spot\"))],"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"diffraction.tool\")"))
        XCTAssertFalse(source.contains("InspectorRow(\"Tool\")"))
        let display = try XCTUnwrap(source.components(separatedBy: "private struct DiffractionDisplaySection").last?
            .components(separatedBy: "private struct DiffractionExportSection").first)
        XCTAssertFalse(display.contains("Tool"), "Display no longer holds the tool")
    }

    /// The Diffraction room's sections read Calibration · Display · Tools · Crystal · Rings · Export (Centre above Calibration, which it
    /// feeds), its Display is the image rooms' one section with the log switch, and the zoom buttons are gone (§2, §5, §6).
    /// Red under: Display back after Rings, a hand-made Display, the View row of small buttons back.
    @MainActor func testDiffractionDisplayIsTheImageRoomsSectionAndSecond() throws {
        let source = try ui("DiffractionRoomInspector.swift")
        XCTAssertTrue(source.contains("DiffractionCentreSection(analysis: analysis, view: view) DiffractionCalibrationSection(image: image, analysis: analysis, view: view) DiffractionDisplaySection(view: view) DiffractionToolsSection(view: view) DiffractionCrystalSection(analysis: analysis) DiffractionRingsSection(image: image, analysis: analysis, view: view) DiffractionExportSection(image: image, analysis: analysis)"))
        XCTAssertTrue(source.contains("ImageRoomDisplaySection(presentation: view.presentation, colormapID: \"diffraction.colormap\", logID: \"diffraction.log\", log: Binding(get: { view.useLog }, set: { view.useLog = $0 }))"))
        XCTAssertFalse(source.contains("InspectorRow(\"View\")") || source.contains(".controlSize(.small)"))
        let display = try ui("ImageRoomDisplay.swift")
        XCTAssertTrue(display.contains(".accessibilityIdentifier(logID)") && display.contains(".accessibilityIdentifier(colormapID)"))
        XCTAssertEqual(DiffractionViewState().presentation.colormap, .viridis, "a pattern reads in viridis by default")
    }

    /// The pattern zooms with the wheel about its centre, shows a badge off 1×, draws through its own presentation, and has no Stop in its
    /// header: the fit runs in the infobar and ⌘. stops it (§1, §6, §7). Red under: the wheel unwired, the colormap hard-wired, the Stop back.
    func testDiffractionPaneZoomsReadsOutAndRunsInTheInfobar() throws {
        let pane = try ui("DiffractionRoom.swift")
        XCTAssertTrue(pane.contains(".onScrollWheel { event in guard event.delta != 0 else { return } view.zoom(by: Double(ScrollZoom.factor(delta: event.delta, isPrecise: event.isPrecise)), image: image) }"))
        XCTAssertTrue(pane.contains(".accessibilityIdentifier(\"diffraction.zoomBadge\")"))
        XCTAssertTrue(pane.contains("colormap: display.colormap, displayLo: display.displayFractions.low"))
        XCTAssertFalse(pane.contains("diffraction.stop") || pane.contains("colormap: .viridis"))
        XCTAssertTrue(pane.contains("appState.diffractionReadout = DiffractionReadoutText.text("))
        XCTAssertTrue(try ui("WorkspaceView.swift").contains("case .diffraction: appState.diffractionReadout"))
        XCTAssertTrue(try ui("WorkspaceView.swift").contains("InfobarRunReadout(operation: \"Ring fit\""))
        XCTAssertTrue(try ui("RoomPrimaryAction.swift").contains("case .diffraction: appState.openItems.selected?.diffraction.stop()"))
        XCTAssertTrue(InfobarRunPolicy.showsFit(area: .diffraction, fitting: true))
        XCTAssertFalse(InfobarRunPolicy.showsFit(area: .diffraction, fitting: false))
        XCTAssertFalse(InfobarRunPolicy.showsFit(area: .image, fitting: true))
    }

    /// The pattern's readout: the pixel, then R, q and d once there is a centre and a scale (§7). Red under: q from the wrong radius, d not 1/q.
    func testDiffractionReadoutText() {
        XCTAssertEqual(DiffractionReadoutText.text(column: 290.2, row: 255.6, centre: nil, calibration: nil), "x 290, y 256")
        let calibration = DiffractionCalibration(source: .typed, deltaQ: 0.0125, ring: nil)
        let text = DiffractionReadoutText.text(column: 296, row: 256, centre: DiffractionCentre(row: 256, column: 256, source: .typed), calibration: calibration)
        XCTAssertEqual(text, "x 296, y 256 \u{00B7} R \(Num.fixed(40, 1)) px \u{00B7} q \(Num.fixed(0.5, 4)) \u{00C5}\u{207B}\u{00B9} \u{00B7} d \(Num.fixed(2, 3)) \u{00C5}")
    }

    /// The image and both FFT panes zoom with the wheel through MacEMUI's bounded `zoomPanWheel`, next to `zoomPan`.
    /// Red under: a pane without the wheel, or an application-wide monitor.
    func testThePicturesTakeTheWheel() throws {
        for name in ["ImagePane.swift", "FFTSourceImagePane.swift", "FFTSpectrumImagePane.swift"] {
            XCTAssertTrue(try ui(name).range(of: #"\.zoomPan\(zoomModel, box: box(, onHover: \{[^}]*\})?\) \.zoomPanWheel\(zoomModel, box: box\)"#, options: .regularExpression) != nil, name)
            XCTAssertFalse(try ui(name).contains("addLocalMonitorForEvents"), name)
        }
    }

    /// The Image room's cursor readout is the pixel under the pointer and its raw value, nil off the pixels (§7).
    /// Red under: the display range read instead of the file's value, rows and columns swapped, an edge pixel refused.
    func testImageReadoutIsThePixelAndItsRawValue() {
        let image = CalibratedImage(width: 3, height: 2, pixels: [0, 1, 2, 30, 40, 9744], x: nil, y: nil,
                                    fileName: "t", source: "t", voltage: nil)
        XCTAssertEqual(ImageReadout.text(image, at: ImagePoint(x: 2.2, y: 0.9)), "x 2, y 1 \u{00B7} 9744")
        XCTAssertEqual(ImageReadout.text(image, at: ImagePoint(x: -0.4, y: -0.4)), "x 0, y 0 \u{00B7} 0")
        XCTAssertNil(ImageReadout.text(image, at: ImagePoint(x: 3.0, y: 0)))
        XCTAssertNil(ImageReadout.text(image, at: ImagePoint(x: 0, y: -0.6)))
    }

    /// The Image room puts its readout in the status line, draws no crosshair, shows the zoom badge, and answers View > Zoom (§6, §7).
    /// Red under: the hover not wired, the badge slot empty, the pane not a zoom command target, the app without ZoomCommands.
    func testImagePaneReadoutBadgeAndZoomCommands() throws {
        let pane = try ui("ImagePane.swift")
        XCTAssertTrue(pane.contains(".zoomPan(zoomModel, box: box, onHover: { phase in hovered(phase, box: box) }) .zoomPanWheel(zoomModel, box: box) .zoomCommandTarget(zoomModel, isTarget: true)"))
        XCTAssertTrue(pane.contains("appState.imageRoomTools.readout = ImageReadout.text(image, at: geometry.imagePoint(atPanePoint: p), particles:"))
        XCTAssertTrue(pane.contains("} trailing: { zoomBadge }") && pane.contains(".accessibilityIdentifier(\"image.zoomBadge\")"))
        XCTAssertFalse(pane.contains("Crosshair"), "no crosshair over the picture")
        XCTAssertTrue(try ui("WorkspaceView.swift").contains("case .image: appState.imageRoomTools.readout"))
        let app = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macTEM/App/macTEMApp.swift")
        XCTAssertTrue(try String(contentsOf: app, encoding: .utf8).contains("ZoomCommands()"))
    }
}
