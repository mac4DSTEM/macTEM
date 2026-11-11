//
//  DiffractionPatternCanvasTests.swift
//  How the Diffraction room's pattern reaches the screen (#336): the canvas of the display values is TEMSession's
//  (`CanvasPixels.pattern`, beside the Image room's `CanvasPixels.make`), and showing a pattern is asked of the view's owner
//  (`DiffractionViewState.show`: the bind, the pattern's extent, the canvas), as the FFT room asks its own. The pixels drawn are the
//  ones the view built before: the same normalisation of the same values, the same version, the same histogram.
//  Red before the change: no `CanvasPixels.pattern`, no `DiffractionViewState.show`; the view's task did the three steps itself
//  through two statics no test reached.
//

import XCTest
import ShellMetal
import ImagoCore
import TEMCore
import TEMSession

nonisolated final class DiffractionPatternCanvasTests: XCTestCase {

    /// The canvas holds the pattern's display values, log or linear, exactly as `DiffractionPattern.normalized` gives them; its range is
    /// 0…1, its version is the view's content version of those values, and its histogram is of those values (the ones drawn).
    /// Red under: the raw pixels normalised linearly for a log display, the histogram of the raw pixels, the range of the raw data.
    func testThePatternsCanvasIsItsDisplayValues() {
        let image = DemoDocuments.diffractionPattern()
        var versions: [Int] = []
        for log in [true, false] {
            let canvas = CanvasPixels.pattern(pixels: image.pixels, width: image.width, height: image.height, log: log)
            let expected = TEMCore.DiffractionPattern(qy: image.height, qx: image.width, pixels: image.pixels).normalized(useLog: log)
            XCTAssertEqual(canvas.width, image.width)
            XCTAssertEqual(canvas.height, image.height)
            XCTAssertEqual(canvas.normalized, expected, "log \(log): the display values, bit for bit")
            XCTAssertEqual(canvas.rawRange, Float(0)...Float(1))
            XCTAssertEqual(canvas.histogram, IntensityHistogram.compute(expected), "the histogram of what is drawn")
            XCTAssertEqual(canvas.contentVersion, MetalImageView.contentVersion(of: expected, width: image.width, height: image.height))
            versions.append(canvas.contentVersion)
        }
        XCTAssertNotEqual(versions[0], versions[1], "log and linear are two pictures: the view uploads again")
    }

    /// Showing a pattern binds the results owner to the image, opens the view on the pattern's own extent and draws the canvas, in log
    /// first; switching Log draws the linear canvas and starts the contrast window whole again, and the same canvas again keeps it.
    /// Red under: the analysis left unbound (no centre), the extent not set (the pane opens on the whole frame), the window kept
    /// across a log switch (a window in log values over linear ones), or reset on every pass.
    @MainActor func testShowingAPatternBindsFindsTheExtentAndDrawsTheCanvas() async {
        let image = DemoDocuments.diffractionPattern()
        let analysis = DiffractionAnalysis()
        let view = DiffractionViewState()
        XCTAssertNil(analysis.centre)
        XCTAssertNil(view.presentation.canvas)

        await view.show(image: image, analysis: analysis)
        let centre = DiffractionCentre.imageCentre(width: image.width, height: image.height)
        XCTAssertEqual(analysis.centre, centre, "the results owner is bound to the image")
        let extent = DiffractionCompute.contentRadius(pixels: image.pixels, width: image.width, height: image.height, centre: centre)
        XCTAssertNotNil(extent, "the demo pattern has an extent of its own")
        XCTAssertEqual(view.autoHalfSide, extent, "the view opens on the pattern")
        XCTAssertEqual(view.presentation.canvas, CanvasPixels.pattern(pixels: image.pixels, width: image.width, height: image.height, log: true))

        view.presentation.windowLow = 0.25
        view.useLog = false
        await view.show(image: image, analysis: analysis)
        XCTAssertEqual(view.presentation.canvas, CanvasPixels.pattern(pixels: image.pixels, width: image.width, height: image.height, log: false))
        XCTAssertNil(view.presentation.windowLow, "a window in log values means nothing in linear ones")

        view.presentation.windowLow = 0.25
        await view.show(image: image, analysis: analysis)
        XCTAssertEqual(view.presentation.windowLow, 0.25, "the same picture again keeps its window")
    }

    /// The room's task makes the one call, and the view file computes nothing off the main actor itself.
    /// Red under: the bind, the extent or the canvas back in the view's task.
    func testTheRoomAsksItsOwnerToShowThePattern() throws {
        let room = try FFTRoomWiringTests.squeezedUI("DiffractionRoom.swift")
        XCTAssertTrue(room.contains(".task(id: DisplayKey(id: item.id, log: view.useLog, width: image.width, height: image.height)) { "
            + "await view.show(image: image, analysis: analysis) }"))
        XCTAssertFalse(room.contains("@concurrent"), "nothing is computed in the view file")
        XCTAssertFalse(room.contains("analysis.bind("), "the bind is the owner's")
        XCTAssertFalse(room.contains("CanvasPixels("), "the canvas is TEMSession's")
    }
}
