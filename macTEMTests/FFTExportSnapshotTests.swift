//
//  FFTExportSnapshotTests.swift
//  Pins what the FFT room's three exports take from the selected file when their panel opens (`FFTExportSnapshot`,
//  `ExportPanels`, `ExportCommands`; V1-10 slice 2): when each command is
//  enabled, that nothing is exported while the spectrum is updating, the owner's window (not the product's default) going to
//  the shader's inputs, one ring per measured spot on THIS spectrum, the names and words, the panels' configuration and the
//  one hand-over from a snapshot to its writer (a real file written and read back). Real `FFTAnalysis` with the live cores on
//  a 96 × 64 plant; expected strings are literals worked out by hand. Tier 2.
//
//  Mutations sampled (each alone, the named test went red): the FFT commands enabled in the Image room (the availability test);
//  `isSpectrumCurrent` dropped from the rule (the updating test); the owner's window replaced by the product's default (the
//  transform test); a spot of another spectrum kept (the filter test); the snapshot's write handing the writer another
//  snapshot's value, e.g. the spots' mask radius swapped for the edge (the write-through test).
//

import ShellMetal
import AppKit
import UniformTypeIdentifiers
import XCTest
import TEMCore
import TEMSession
import ImagoCore
import ImagoFFT
@testable import macTEM

nonisolated final class FFTExportSnapshotTests: XCTestCase {

    private static let software = "macTEM 0.1.0 (1)"
    private static let url = URL(fileURLWithPath: "/data/run1/plant.dm4")

    private struct TimedOut: Error {}

    @MainActor private func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for: \(what)")
        throw TimedOut()
    }

    /// An owner showing the plant with region A transformed and its spectrum landed.
    @MainActor private func landed() async throws -> (image: CalibratedImage, analysis: FFTAnalysis) {
        let image = FFTAnalysisTests.plant()
        let analysis = FFTAnalysis()
        analysis.setRegion(FFTAnalysisTests.regionA, committed: true)
        analysis.show(image, contentVersion: 1)
        try await until("the spectrum lands") { analysis.isSpectrumCurrent }
        return (image, analysis)
    }

    @MainActor private func measure(_ analysis: FFTAnalysis, row: Int, col: Int, count: Int) async throws {
        analysis.measureSpot(row: row, col: col)
        try await until("the spot is answered") {
            analysis.spots.count == count && !analysis.spots.contains { if case .measuring = $0.outcome { true } else { false } }
        }
    }

    // MARK: - Enabled

    /// The three need the FFT room, an image, no read and a current spectrum; the profile also a bin, the spots a measured spot.
    /// Red under: the Image room enabling them; the loading or current-spectrum condition dropped; the spots command following
    /// the transform alone.
    @MainActor func testTheFFTCommandsAreEnabledOnlyInTheFFTRoomWithACurrentSpectrum() {
        func available(hasImage: Bool = true, area: WorkspaceArea = .fft, isLoading: Bool = false, current: Bool = true,
                       bins: Bool = true, spots: Int = 2) -> FFTExportAvailability {
            ExportSnapshot.fftAvailability(hasImage: hasImage, area: area, isLoading: isLoading, spectrumIsCurrent: current,
                                           profileHasBins: bins, measuredSpots: spots)
        }
        XCTAssertEqual(available(), FFTExportAvailability(transform: true, profile: true, spots: true))
        XCTAssertEqual(available(bins: false), FFTExportAvailability(transform: true, profile: false, spots: true))
        XCTAssertEqual(available(spots: 0), FFTExportAvailability(transform: true, profile: true, spots: false))
        let off = FFTExportAvailability(transform: false, profile: false, spots: false)
        XCTAssertEqual(available(hasImage: false), off)
        XCTAssertEqual(available(isLoading: true), off)
        XCTAssertEqual(available(current: false), off, "an updating spectrum is not exported")
        for area in WorkspaceArea.allCases where area != .fft {
            XCTAssertEqual(available(area: area), off, "\(area.title)")
        }
        XCTAssertEqual(ExportSnapshot.fftAvailability(of: AppState()), off, "a window with nothing open exports nothing")
    }

    // MARK: - Nothing stale

    /// Before the spectrum lands, and while another region's is asked for, there is nothing to export. Red under:
    /// `isSpectrumCurrent` dropped from the snapshots.
    @MainActor func testNothingIsSnapshotWhileTheSpectrumIsUpdating() async throws {
        let image = FFTAnalysisTests.plant()
        let analysis = FFTAnalysis()
        analysis.setRegion(FFTAnalysisTests.regionA, committed: true)
        analysis.show(image, contentVersion: 1)
        XCTAssertNil(ExportSnapshot.transformSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
        try await until("the spectrum lands") { analysis.isSpectrumCurrent }
        XCTAssertNotNil(ExportSnapshot.transformSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
        analysis.setRegion(FFTAnalysisTests.regionC, committed: false)       // another region asked for, the old one on screen
        XCTAssertFalse(analysis.isSpectrumCurrent)
        XCTAssertNil(ExportSnapshot.transformSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
        XCTAssertNil(ExportSnapshot.radialProfileSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
        XCTAssertNil(ExportSnapshot.spotsSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
    }

    /// Only the measured spots of the spectrum on screen are listed or drawn. Red under: the key filter dropped; an unmeasured
    /// spot kept.
    @MainActor func testOnlyMeasuredSpotsOfThisSpectrumAreKept() throws {
        let here = FFTSpectrumKey(contentVersion: 1, crop: FFTAnalysisTests.regionA)
        let elsewhere = FFTSpectrumKey(contentVersion: 1, crop: FFTAnalysisTests.regionB)
        let m = try FFTAnalysisTests.measured(row: 37, col: 40)
        let spots = [FFTSpot(number: 1, row: 37, col: 40, spectrumKey: here, outcome: .measured(m)),
                     FFTSpot(number: 2, row: 37, col: 40, spectrumKey: elsewhere, outcome: .measured(m)),
                     FFTSpot(number: 3, row: 32, col: 33, spectrumKey: here, outcome: .refused(.nearDC)),
                     FFTSpot(number: 4, row: 5, col: 5, spectrumKey: here, outcome: .refused(.noPower)),
                     FFTSpot(number: 5, row: 29, col: 44, spectrumKey: here, outcome: .measuring)]
        XCTAssertEqual(ExportSnapshot.measuredSpots(on: here, in: spots).map(\.number), [1])
    }

    // MARK: - The transform

    /// The transform goes to the shader's inputs as the pane gets them: the owner's window (here set), grey, gamma 1, the
    /// spectrum's own size and range, one ring per measured spot at its centroid labelled by its number, the name with the
    /// region, the message, the options' defaults. Red under: the product's default window used; the gamma not 1; a ring at
    /// the clicked bin; the colormap not grey.
    @MainActor func testTheTransformSnapshotCarriesTheOwnersWindowAndOneRingPerMeasuredSpot() async throws {
        let (image, analysis) = try await landed()
        let spectrum = try XCTUnwrap(analysis.spectrum)
        let range = try XCTUnwrap(spectrum.canvas.rawRange)
        let low = range.lowerBound + 0.25 * (range.upperBound - range.lowerBound)
        let high = range.lowerBound + 0.75 * (range.upperBound - range.lowerBound)
        analysis.spectrumWindowLow = low
        analysis.spectrumWindowHigh = high
        try await measure(analysis, row: 37, col: 40, count: 1)
        let snapshot = try XCTUnwrap(ExportSnapshot.transformSnapshot(image: image, url: Self.url, analysis: analysis,
                                                                      software: Self.software))
        XCTAssertEqual(snapshot.display.width, 64); XCTAssertEqual(snapshot.display.height, 64)
        XCTAssertEqual(snapshot.display.normalized, spectrum.canvas.normalized)
        let fractions = DisplayWindow.fractions(low: low, high: high, rawRange: range)
        XCTAssertEqual(snapshot.display.low, fractions.low)
        XCTAssertEqual(snapshot.display.high, fractions.high)
        XCTAssertEqual(snapshot.display.windowLow, low)
        XCTAssertEqual(snapshot.display.windowHigh, high)
        XCTAssertEqual(snapshot.display.gamma, 1)
        XCTAssertEqual(snapshot.display.colormap, "gray")
        XCTAssertEqual(snapshot.display.lut, Colormaps.lutRGBA(.gray))
        XCTAssertEqual(snapshot.display.rawRange, range)
        let m = try XCTUnwrap(analysis.spots.first?.measured)
        XCTAssertEqual(snapshot.marks, [ImageExport.Mark(kind: .spot, points: [ImagePoint(x: m.centroidCol, y: m.centroidRow)],
                                                         width: 1, label: "1")])
        XCTAssertEqual(snapshot.defaultName, "plant-fft-r64x64-x16-y0")
        XCTAssertEqual(snapshot.directory?.path, "/data/run1")
        XCTAssertEqual(snapshot.message, "Transform of region 64 \u{00D7} 64 px at (16, 0), 64 \u{00D7} 64 bins, log\u{2081}\u{2080}|F|\u{00B2} in the window shown."
                       + " This region is 64 \u{00D7} 64 bins: the PNG has one pixel per bin, so it is 1 : 1 where the room shows it 1 : 1.25.")
        XCTAssertEqual(snapshot.defaults, ExportImageDefaults(scaleBar: true, marks: true, offersMarks: true))
        XCTAssertEqual(snapshot.header.crop, FFTAnalysisTests.regionA)
        XCTAssertEqual(snapshot.header.spacingX, spectrum.spacingX)
        XCTAssertEqual(snapshot.header.fileName, "plant")
    }

    /// With no owner window the product's default is the window; with no spot Spots is not offered. Red under: the default
    /// ignored; Spots offered with none.
    @MainActor func testWithoutAWindowTheDefaultWindowAndWithoutSpotsNoSpotsOption() async throws {
        let (image, analysis) = try await landed()
        let spectrum = try XCTUnwrap(analysis.spectrum)
        let snapshot = try XCTUnwrap(ExportSnapshot.transformSnapshot(image: image, url: nil, analysis: analysis, software: Self.software))
        let expected = FFTSpectrumLayout.window(low: nil, high: nil, spectrum: spectrum)
        XCTAssertEqual(snapshot.display.low, expected.low)
        XCTAssertEqual(snapshot.display.high, expected.high)
        XCTAssertEqual(snapshot.display.windowLow, spectrum.defaultWindow?.low)
        XCTAssertFalse(snapshot.defaults.offersMarks)
        XCTAssertTrue(snapshot.marks.isEmpty)
        XCTAssertNil(snapshot.directory)
    }

    // MARK: - The CSVs

    @MainActor func testTheRadialProfileSnapshotNamesBinsAndUnits() async throws {
        let (image, analysis) = try await landed()
        let spectrum = try XCTUnwrap(analysis.spectrum)
        let profile = try XCTUnwrap(spectrum.profile)
        let snapshot = try XCTUnwrap(ExportSnapshot.radialProfileSnapshot(image: image, url: Self.url, analysis: analysis,
                                                                          software: Self.software))
        let bins = profile.points.count
        XCTAssertEqual(snapshot.bins, profile.count.filter { $0 > 0 }.count - 1, "bin 0 is not counted: the chart does not draw it")
        XCTAssertEqual(snapshot.bins, bins)
        XCTAssertEqual(snapshot.defaultName, "plant-radial-profile-r64x64-x16-y0")
        XCTAssertEqual(snapshot.message, "\(bins) bins \u{00B7} |q| in nm\u{207B}\u{00B9} and 1/nm \u{00B7} mean |F|\u{00B2} of the transform, unwindowed")
    }

    /// The list: the measured spots in order, the others counted as not listed, the mask as the owner has it, the accuracy
    /// note at 64 px. Red under: an unmeasured spot listed; the omitted count dropped; the note dropped.
    @MainActor func testTheSpotsSnapshotListsMeasuredSpotsAndCountsTheRest() async throws {
        let (image, analysis) = try await landed()
        try await measure(analysis, row: 37, col: 40, count: 1)
        try await measure(analysis, row: 32, col: 32, count: 2)               // the centre: any snap stays within 3 bins of it, refused
        let snapshot = try XCTUnwrap(ExportSnapshot.spotsSnapshot(image: image, url: Self.url, analysis: analysis,
                                                                  software: Self.software))
        XCTAssertEqual(snapshot.rows.map(\.number), [1])
        XCTAssertEqual(snapshot.omitted, 1)
        XCTAssertEqual(snapshot.maskRadius, 3); XCTAssertEqual(snapshot.maskEdge, 2)
        XCTAssertEqual(snapshot.notes, ["With noise, d is good to 1\u{2013}5 % at 64 px and 0.5\u{2013}3 % at 128 px."])
        XCTAssertEqual(snapshot.defaultName, "plant-spots-r64x64-x16-y0")
        XCTAssertEqual(snapshot.message, "1 spot measured \u{00B7} 1 not listed (refused, still measuring or no peak)")
    }

    @MainActor func testNoMeasuredSpotMeansNoSpotsSnapshot() async throws {
        let (image, analysis) = try await landed()
        XCTAssertNil(ExportSnapshot.spotsSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
    }

    // MARK: - Names and words

    func testTheNamesAreBareStemsWithTheRegionAndTheLinesNameWhatWasDrawn() {
        XCTAssertEqual(ExportSnapshot.fftName(fileName: "scan.dm4", product: "fft", crop: nil), "scan-fft")
        XCTAssertEqual(ExportSnapshot.fftName(fileName: "scan.v2.dm4", product: "spots", crop: PixelCrop(row: 404, col: 812, height: 256, width: 256)),
                       "scan.v2-spots-r256x256-x812-y404")
        XCTAssertEqual(ExportSnapshot.transformDoneLine(name: "a.png", width: 64, height: 64, spots: 0, barLeftOut: false),
                       "Exported a.png \u{2014} 64 \u{00D7} 64 bins")
        XCTAssertEqual(ExportSnapshot.transformDoneLine(name: "a.png", width: 64, height: 64, spots: 1, barLeftOut: false),
                       "Exported a.png \u{2014} 64 \u{00D7} 64 bins (1 spot drawn)")
        XCTAssertEqual(ExportSnapshot.transformDoneLine(name: "a.png", width: 64, height: 64, spots: 3, barLeftOut: true),
                       "Exported a.png without the scale bar (the transform is too small) \u{2014} 64 \u{00D7} 64 bins (3 spots drawn)")
        XCTAssertEqual(ExportSnapshot.radialProfileDoneLine(name: "p.csv", bins: 1), "Exported p.csv \u{2014} 1 bin")
        XCTAssertEqual(ExportSnapshot.spotsDoneLine(name: "s.csv", spots: 4), "Exported s.csv \u{2014} 4 spots")
        XCTAssertEqual(ExportSnapshot.transformMessage(crop: nil, imageWidth: 96, imageHeight: 64, width: 96, height: 64,
                                                        spacingX: 0.5, spacingY: 0.5),
                       "Transform of the whole image, 96 \u{00D7} 64 bins, log\u{2081}\u{2080}|F|\u{00B2} in the window shown.")
    }

    /// The PNG is one square pixel per bin; when that shape is not the room's (width·Δq_x : height·Δq_y) the panel's message says so
    /// in words, and when it is, it says nothing. Red under: the sentence dropped, or written for a matching shape.
    func testThePanelSaysWhenThePngIsNotTheShapeTheRoomShows() {
        // 256 x 128 bins of a square-pixel image: the room's box is 1 : 1 (256*dq == 128*dq*2), the PNG is 2 : 1.
        let dq = 0.0390625
        let message = ExportSnapshot.transformMessage(crop: PixelCrop(row: 0, col: 0, height: 128, width: 256), imageWidth: 512, imageHeight: 512,
                                                      width: 256, height: 128, spacingX: dq, spacingY: dq * 2)
        XCTAssertTrue(message.hasSuffix(" This region is 256 \u{00D7} 128 bins: the PNG has one pixel per bin, so it is 2 : 1 where the room shows it 1 : 1."), message)
        XCTAssertEqual(ExportSnapshot.aspectSentence(width: 64, height: 64, spacingX: dq, spacingY: dq), "")
        XCTAssertEqual(ExportSnapshot.aspectSentence(width: 256, height: 128, spacingX: dq, spacingY: dq), "", "a box shown at the file's own shape")
    }

    // MARK: - The panels

    @MainActor func testThePanelsAreNamedAndPlacedAsTheDesignSays() async throws {
        let (image, analysis) = try await landed()
        try await measure(analysis, row: 37, col: 40, count: 1)
        let transform = try XCTUnwrap(ExportSnapshot.transformSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
        let choices = ExportImageChoices(transform.defaults, kind: .spots)
        let png = ExportPanels.transformPanel(for: transform, choices: choices)
        XCTAssertEqual(png.allowedContentTypes, [.png])
        XCTAssertEqual(png.nameFieldStringValue, "plant-fft-r64x64-x16-y0")
        XCTAssertEqual(png.nameFieldLabel, "Export As:")
        XCTAssertEqual(png.prompt, "Export")
        XCTAssertEqual(png.directoryURL?.path, "/data/run1")
        XCTAssertFalse(png.isExtensionHidden)
        XCTAssertNotNil(png.accessoryView)
        XCTAssertEqual(choices.kind.title, "Spots")
        XCTAssertEqual(choices.kind.identifier, "export.spotsToggle")
        let profile = ExportPanels.radialProfilePanel(for: try XCTUnwrap(ExportSnapshot.radialProfileSnapshot(
            image: image, url: Self.url, analysis: analysis, software: Self.software)))
        let spots = ExportPanels.spotsPanel(for: try XCTUnwrap(ExportSnapshot.spotsSnapshot(
            image: image, url: Self.url, analysis: analysis, software: Self.software)))
        for panel in [profile, spots] {
            XCTAssertEqual(panel.allowedContentTypes, [.commaSeparatedText])
            XCTAssertNil(panel.accessoryView)
            XCTAssertEqual(panel.directoryURL?.path, "/data/run1")
        }
        XCTAssertEqual(profile.nameFieldStringValue, "plant-radial-profile-r64x64-x16-y0")
        XCTAssertEqual(spots.nameFieldStringValue, "plant-spots-r64x64-x16-y0")
        XCTAssertEqual(ExportImageChoices(transform.defaults).kind.title, "Marks", "the Image room's accessory is unchanged")
    }

    // MARK: - What OK writes

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FFTExportSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Each snapshot writes its own values to the chosen file and nothing else: the profile's bins, the spots' rows and mask,
    /// and a PNG of the spectrum's size whose Description is the transform's. Red under: a snapshot's write handing the writer
    /// another value (the mask radius and edge swapped, the provenance dropped, the marks or the options not passed).
    @MainActor func testTheSnapshotsWriteTheirOwnValuesToTheChosenFile() async throws {
        let (image, analysis) = try await landed()
        try await measure(analysis, row: 37, col: 40, count: 1)
        analysis.setMask(radius: 5, edge: 1)
        let directory = try scratch()

        let profileSnapshot = try XCTUnwrap(ExportSnapshot.radialProfileSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
        let profileURL = directory.appendingPathComponent("p.csv")
        try await profileSnapshot.write(to: profileURL)
        let profileText = try String(contentsOf: profileURL, encoding: .utf8)
        XCTAssertEqual(profileText, RadialProfileCSV.text(profileSnapshot.profile, header: profileSnapshot.header))
        XCTAssertEqual(profileText.split(separator: "\n").filter { !$0.hasPrefix("#") }.count, profileSnapshot.bins + 1)

        let spotsSnapshot = try XCTUnwrap(ExportSnapshot.spotsSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
        let spotsURL = directory.appendingPathComponent("s.csv")
        try await spotsSnapshot.write(to: spotsURL)
        let spotsText = try String(contentsOf: spotsURL, encoding: .utf8)
        XCTAssertTrue(spotsText.contains("# mask: radius 5 bins, edge 1 bins"))
        XCTAssertEqual(spotsText.split(separator: "\n").filter { !$0.hasPrefix("#") }.count, 2)

        let transform = try XCTUnwrap(ExportSnapshot.transformSnapshot(image: image, url: Self.url, analysis: analysis, software: Self.software))
        let pngURL = directory.appendingPathComponent("t.png")
        let rendered = try await transform.write(to: pngURL, options: ExportSnapshot.options(scaleBar: true, marks: true, offersMarks: true))
        XCTAssertEqual(rendered.width, 64); XCTAssertEqual(rendered.height, 64)
        // A 64-bin transform is too small for the plate: the bar is left out and the result says so (the bar itself is pinned
        // by FFTExportTests and export-parity on larger transforms).
        XCTAssertEqual(rendered.barLeftOut, rendered.bar == nil)
        let data = try Data(contentsOf: pngURL)
        XCTAssertEqual(data, rendered.png)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"space\":\"reciprocal\""))
        XCTAssertTrue(text.contains("\"spots_drawn\":\"1\""))
        XCTAssertTrue(text.contains("\"kind\":\"spot\""))

        // Spots off: none drawn and none counted.
        let bare = directory.appendingPathComponent("bare.png")
        _ = try await transform.write(to: bare, options: ExportSnapshot.options(scaleBar: false, marks: false, offersMarks: true))
        let bareText = String(decoding: try Data(contentsOf: bare), as: UTF8.self)
        XCTAssertTrue(bareText.contains("\"spots_drawn\":\"0\""))
        XCTAssertFalse(bareText.contains("\"kind\":\"spot\""))
    }
}
