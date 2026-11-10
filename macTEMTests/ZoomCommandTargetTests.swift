//
//  ZoomCommandTargetTests.swift
//  View > Zoom In, Zoom Out and Zoom to Fit (⌘+, ⌘−, ⌘0) in the FFT and Diffraction rooms (#316): which FFT pane answers the menu
//  (`FFTZoomTarget`), what the menu's model asks of the pattern (`DiffractionZoomCommand`, on MacEMUI's real `PaneZoomModel`), and
//  the lines that publish each pane's zoom. That the menu items are enabled in the live window is a focused scene value, which no
//  unit test reaches: the Diffraction and FFT journeys choose the items.
//

import XCTest
import ShellControls
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class ZoomCommandTargetTests: XCTestCase {

    private func ui(_ name: String) throws -> String { try FFTRoomWiringTests.squeezedUI(name) }

    /// The menu acts on the pane pressed last, on the transform until a pane is pressed, and never on a pane with nothing drawn.
    /// Red under: the source as the default, both panes answering at once, a pane without a picture offered.
    func testTheFFTRoomZoomsThePanePressedLast() {
        XCTAssertTrue(FFTZoomTarget.isTarget(pane: .spectrum, lastClicked: nil, hasPicture: true), "the transform until a pane is pressed")
        XCTAssertFalse(FFTZoomTarget.isTarget(pane: .source, lastClicked: nil, hasPicture: true))
        XCTAssertTrue(FFTZoomTarget.isTarget(pane: .source, lastClicked: .source, hasPicture: true))
        XCTAssertFalse(FFTZoomTarget.isTarget(pane: .spectrum, lastClicked: .source, hasPicture: true))
        XCTAssertTrue(FFTZoomTarget.isTarget(pane: .spectrum, lastClicked: .spectrum, hasPicture: true))
        XCTAssertFalse(FFTZoomTarget.isTarget(pane: .source, lastClicked: .spectrum, hasPicture: true))
        XCTAssertFalse(FFTZoomTarget.isTarget(pane: .spectrum, lastClicked: .spectrum, hasPicture: false), "nothing drawn, nothing to zoom")
        XCTAssertFalse(FFTZoomTarget.isTarget(pane: .source, lastClicked: .source, hasPicture: false))
        let presses: [FFTKeyPane?] = [nil, .source, .spectrum]
        for last in presses {
            let answering = [FFTKeyPane.source, FFTKeyPane.spectrum].filter { FFTZoomTarget.isTarget(pane: $0, lastClicked: last, hasPicture: true) }
            XCTAssertEqual(answering.count, 1, "exactly one pane answers the menu")
        }
    }

    /// The menu's model holds the badge's number (the fit's half-side over the one shown), inside the model's own range.
    /// Red under: the ratio upside down, the range not held (a model past ×64 would step back on Zoom In), a zero half-side divided by.
    func testTheMenusModelHoldsThePatternsZoom() {
        XCTAssertEqual(DiffractionZoomCommand.mirrored(fitHalfSide: 80, halfSide: 80), 1)
        XCTAssertEqual(DiffractionZoomCommand.mirrored(fitHalfSide: 80, halfSide: 40), 2)
        XCTAssertEqual(DiffractionZoomCommand.mirrored(fitHalfSide: 80, halfSide: 160), 0.5)
        XCTAssertEqual(DiffractionZoomCommand.mirrored(fitHalfSide: 1024, halfSide: 8), ZoomPan.maximumZoom, "×128 is held to the model's ×64")
        XCTAssertEqual(DiffractionZoomCommand.mirrored(fitHalfSide: 40, halfSide: 256), ZoomPan.minimumZoom)
        XCTAssertEqual(DiffractionZoomCommand.mirrored(fitHalfSide: 0, halfSide: 80), 1)
        XCTAssertEqual(DiffractionZoomCommand.mirrored(fitHalfSide: 80, halfSide: 0), 1)
        XCTAssertEqual(DiffractionZoomCommand.mirrored(fitHalfSide: 80, halfSide: .nan), 1)
    }

    /// What the menu asked for: nothing while the model and the pane agree, the fit at 1×, else the step as a factor.
    /// Red under: a follow read as a command (every wheel step applied twice), Zoom to Fit read as a zoom out, the factor inverted.
    func testAMenuStepIsReadFromTheModel() {
        XCTAssertNil(DiffractionZoomCommand.asked(model: 2, mirrored: 2), "the model only followed the pane")
        XCTAssertNil(DiffractionZoomCommand.asked(model: 64, mirrored: 64), "a step that stopped at the model's limit")
        XCTAssertEqual(DiffractionZoomCommand.asked(model: 4, mirrored: 2), .zoom(by: 2))
        XCTAssertEqual(DiffractionZoomCommand.asked(model: 1.5, mirrored: 3), .zoom(by: 0.5))
        XCTAssertEqual(DiffractionZoomCommand.asked(model: 1, mirrored: 2), .fit)
        XCTAssertEqual(DiffractionZoomCommand.asked(model: 1, mirrored: 0.5), .fit)
        XCTAssertEqual(DiffractionZoomCommand.asked(model: 1, mirrored: 64), .fit, "Zoom to Fit from any zoom")
        XCTAssertNil(DiffractionZoomCommand.asked(model: .nan, mirrored: 2))
    }

    /// The whole round on the real model and view state, in the order the room's modifier runs it: a menu step is performed on the
    /// pattern and the model then follows what the pane shows; a zoom of the pane itself is followed and asks for nothing.
    /// Red under: Zoom In not halving the half-side, Zoom to Fit leaving a typed half-side, a wheel step applied twice, the model
    /// left past the pane's 8 px limit (the next Zoom Out would then do nothing).
    @MainActor func testTheViewMenuStepsThePatternThroughItsModel() {
        let image = DemoDocuments.diffractionPattern()      // 512 px across: the whole image is ±256
        let view = DiffractionViewState()
        view.setAutoExtent(80)
        let model = PaneZoomModel()
        func menu(_ step: () -> Void) {
            step()
            DiffractionZoomCommand.perform(from: model, on: view, image: image)
            DiffractionZoomCommand.follow(view, image: image, with: model)
        }
        func pane(_ zoom: () -> Void) {
            zoom()
            DiffractionZoomCommand.follow(view, image: image, with: model)
            DiffractionZoomCommand.perform(from: model, on: view, image: image)
        }
        DiffractionZoomCommand.follow(view, image: image, with: model)
        XCTAssertEqual(model.state.zoom, 1, "the pane opens at the fit")

        menu { model.zoomIn() }
        XCTAssertEqual(view.viewHalfSide(for: image), 40, "Zoom In halves the half-side")
        XCTAssertEqual(model.state.zoom, 2)
        menu { model.zoomIn() }
        XCTAssertEqual(view.viewHalfSide(for: image), 20)
        menu { model.zoomOut() }
        XCTAssertEqual(view.viewHalfSide(for: image), 40)
        menu { model.fit() }
        XCTAssertNil(view.zoomHalfSide, "Zoom to Fit is the double-click's fit")
        XCTAssertEqual(view.viewHalfSide(for: image), 80)
        XCTAssertEqual(model.state.zoom, 1)

        pane { view.zoom(by: 4, image: image) }
        XCTAssertEqual(view.viewHalfSide(for: image), 20, "the pane's own zoom is not applied a second time")
        XCTAssertEqual(model.state.zoom, 4)

        menu { model.zoomIn() }
        menu { model.zoomIn() }
        XCTAssertEqual(view.viewHalfSide(for: image), 8, "never closer than 8 px")
        XCTAssertEqual(model.state.zoom, 10, "the model shows what the pane shows")
        menu { model.zoomOut() }
        XCTAssertEqual(view.viewHalfSide(for: image), 16)
        XCTAssertEqual(model.state.zoom, 5)
        XCTAssertEqual(model.state.offset, .zero, "no pan: the view stays centred on the pattern")

        // A step the pane cannot take leaves the model on what the pane shows, so the next step the other way is taken at once.
        view.setAutoExtent(nil)             // no extent of its own: the fit is the whole image, ±256
        pane { view.fitView() }
        XCTAssertEqual(view.viewHalfSide(for: image), 256)
        XCTAssertEqual(model.state.zoom, 1)
        menu { model.zoomOut() }
        XCTAssertEqual(view.viewHalfSide(for: image), 256, "never more than the whole image")
        XCTAssertEqual(model.state.zoom, 1, "a step the pane did not take leaves the model on the pane's zoom")
        menu { model.zoomIn() }
        XCTAssertEqual(view.viewHalfSide(for: image), 128, "so the next Zoom In zooms at once")
        XCTAssertEqual(model.state.zoom, 2)
    }

    /// Each pane publishes its zoom to the View menu. Red under: a pane's line removed (its commands dim again), the FFT panes
    /// both always targets (the last one mounted would win), the Diffraction modifier not mounted or its two halves unhooked, the
    /// model not put back on the pane's zoom after a menu step.
    func testThePanesPublishTheirZoomToTheViewMenu() throws {
        XCTAssertTrue(try ui("FFTSpectrumImagePane.swift").contains(
            ".zoomCommandTarget(zoomModel, isTarget: FFTZoomTarget.isTarget(pane: .spectrum, lastClicked: keyPane, hasPicture: spectrum != nil && failure == nil))"))
        XCTAssertTrue(try ui("FFTSourceImagePane.swift").contains(
            ".zoomCommandTarget(zoomModel, isTarget: FFTZoomTarget.isTarget(pane: .source, lastClicked: keyPane, hasPicture: layer != nil))"))
        let diffraction = try ui("DiffractionRoom.swift")
        XCTAssertTrue(diffraction.contains("DiffractionPatternPane(image: image, analysis: analysis, view: view, rows: rows) .modifier(DiffractionZoomCommands(image: image, view: view))"))
        XCTAssertTrue(diffraction.contains(".zoomCommandTarget(model, isTarget: true)"))
        XCTAssertTrue(diffraction.contains(".onChange(of: DiffractionZoomCommand.mirrored(view, image: image), initial: true) { DiffractionZoomCommand.follow(view, image: image, with: model) }"))
        // After a menu step the model follows the pane too: a step the pane did not take changes no mirrored value.
        XCTAssertTrue(diffraction.contains(".onChange(of: model.state.zoom) { DiffractionZoomCommand.perform(from: model, on: view, image: image) DiffractionZoomCommand.follow(view, image: image, with: model) }"))
    }
}
