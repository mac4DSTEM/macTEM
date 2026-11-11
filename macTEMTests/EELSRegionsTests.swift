//
//  EELSRegionsTests.swift
//  The EELS room's regions, on the planted demo (`DemoDocuments`): t/λ = 0.5 at every pixel of a noise-free 16 x 16 image, so a summed region read as one pixel must
//  give 0.5 whatever its shape and size (SpectroKit's `EELSThickness.logRatio` on the 1 x 1 sum), and a profile along a line over the t/λ map is flat at 0.5.
//
//  WHAT IS PINNED (D12, D17): the room has no arithmetic of its own. A region's pixel count is the kit's mask; its t/λ is the kit's on the sum; the planted truth
//  is the generator's. Red under: a region summed with the wrong mask (pixels differ); a layer kept for a hidden region; a profile that reads the map shifted.
//

import XCTest
import SpectroEDX
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM
import ShellEDXModel

nonisolated final class EELSRegionsTests: XCTestCase {

    @MainActor private func openRoom() async throws -> EELSSession {
        let session = EELSSession()
        await session.bind(try DemoDocuments.eels()).value
        session.setThreshold(.fixed(DemoDocuments.Truth.eelsThresholdEV))
        await session.settled()
        return session
    }

    /// Three shapes are three regions; each reads t/λ = 0.5 and holds its own pixels; hiding one drops its layer, not its row; a deleted region's name is not reused.
    @MainActor func testRegionsReadThePlantedThicknessWhateverTheirShape() async throws {
        let session = try await openRoom()
        session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4)))
        session.drawRegion(.ellipse(PixelRect(x0: 4, y0: 4, x1: 12, y1: 12)))
        session.drawRegion(.polygon([PixelPoint(x: 8, y: 0), PixelPoint(x: 16, y: 0), PixelPoint(x: 16, y: 8)]))
        session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4)))   // the same shape again is the same region
        await session.settled()
        XCTAssertEqual(session.pins.map(\.name), ["Region 1", "Region 2", "Region 3"])
        XCTAssertEqual(session.pinRows.map(\.pixels), [16, EDXRegion.ellipse(PixelRect(x0: 4, y0: 4, x1: 12, y1: 12)).pixelCount(nx: 16, ny: 16),
                                                      EDXRegion.polygon([PixelPoint(x: 8, y: 0), PixelPoint(x: 16, y: 0), PixelPoint(x: 16, y: 8)]).pixelCount(nx: 16, ny: 16)])
        for row in session.pinRows {
            XCTAssertEqual(try XCTUnwrap(row.tOverLambda, "\(row.pin.name): no t/λ"), DemoDocuments.Truth.eelsTOverLambda, accuracy: 2e-3, row.pin.name)
        }
        let channels = try XCTUnwrap(session.source?.image.channels)
        XCTAssertEqual(session.pinSpectra.values.map(\.count), [channels, channels, channels])

        let hidden = session.pins[1].id
        session.setPinVisible(hidden, false)
        await session.settled()
        XCTAssertNil(session.pinSpectra[hidden], "a hidden region has no layer")
        XCTAssertEqual(session.pinRows.count, 3, "but keeps its row")
        session.removePin(session.pins[0].id)
        session.drawRegion(.rectangle(PixelRect(x0: 12, y0: 12, x1: 14, y1: 14)))
        XCTAssertEqual(session.pins.last?.name, "Region 4", "a deleted region's name is not handed on")
    }

    /// A shape off the scan or without a pixel is not a region. Red under: an empty pin kept.
    @MainActor func testAShapeThatHoldsNoPixelIsNotKept() async throws {
        let session = try await openRoom()
        XCTAssertNil(session.drawRegion(.rectangle(PixelRect(x0: 20, y0: 20, x1: 30, y1: 30))))
        XCTAssertNil(session.drawRegion(.polygon([PixelPoint(x: 0, y: 0), PixelPoint(x: 1, y: 1)])))
        XCTAssertNil(session.drawRegion(.wholeMap))
        XCTAssertTrue(session.pins.isEmpty)
    }

    /// A line over the t/λ map reads 0.5 along its whole length, and is clamped to the scan.
    @MainActor func testAProfileAlongALineOverThicknessIsFlatAtThePlantedValue() async throws {
        let session = try await openRoom()
        let line = try XCTUnwrap(session.drawLine(from: PixelPoint(x: -2, y: 8.5), to: PixelPoint(x: 30, y: 8.5)))
        XCTAssertEqual(line.from.x, 0); XCTAssertEqual(line.to.x, 16)
        let thickness = try XCTUnwrap(session.profiles().first { $0.id == "tOverLambda" })
        XCTAssertEqual(thickness.samples.count, 17, "a line of length 16 pixels has a sample at each end and one per pixel between")
        for v in thickness.samples { XCTAssertEqual(v, DemoDocuments.Truth.eelsTOverLambda, accuracy: 2e-3) }
        XCTAssertNil(session.drawLine(from: PixelPoint(x: 1, y: 1), to: PixelPoint(x: 1.2, y: 1)), "shorter than a pixel")
    }

    /// VoiceOver names every cell of the Regions table by its region and its column, as the EDS room's table does, with the number the cell shows, and a
    /// hidden region says so in words. Red under: an edge cell with an identifier and no label ("1.2e4" with no region or edge); a hidden region told
    /// from a shown one by its dimming alone.
    func testEveryCellOfTheRegionsTableIsNamedByItsRegionAndItsColumn() throws {
        XCTAssertEqual(EELSRegionSpeech.cellLabel(region: "Region 1", edge: "Fe L2,3", kind: .atomic), "Region 1 Fe L2,3 at%")
        XCTAssertEqual(EELSRegionSpeech.cellLabel(region: "Region 1", edge: "Fe L2,3", kind: .intensity), "Region 1 Fe L2,3 intensity")
        XCTAssertEqual(EELSRegionSpeech.cellValue(12345.678, kind: .intensity, locale: Locale(identifier: "en_US")), "12350", "the four figures the cell shows")
        XCTAssertEqual(EELSRegionSpeech.cellValue(44.44, kind: .atomic, locale: Locale(identifier: "de_DE")), "44,4", "in the reader's decimal mark, as the cell")
        XCTAssertEqual(EELSRegionSpeech.cellValue(nil, kind: .intensity), "none", "a dash is not read as a number")
        XCTAssertEqual(EELSRegionSpeech.cellValue(nil, kind: .atomic), "none")
        XCTAssertEqual(EELSRegionSpeech.visibility(isVisible: false), "hidden")
        XCTAssertEqual(EELSRegionSpeech.visibility(isVisible: true), "")

        let source = try FFTRoomWiringTests.squeezedUI("EELSRegionsTable.swift")
        XCTAssertTrue(source.contains(".accessibilityLabel(EELSRegionSpeech.cellLabel(region: pin.name, edge: edge.title, kind: .intensity)) "
                                      + ".accessibilityValue(EELSRegionSpeech.cellValue(value, kind: .intensity)) "
                                      + ".accessibilityIdentifier(\"eels.regionTable.\\(pin.name).\\(edge.id)\")"), "the intensity cell")
        XCTAssertTrue(source.contains(".accessibilityLabel(EELSRegionSpeech.cellLabel(region: pin.name, edge: edge.title, kind: .atomic)) "
                                      + ".accessibilityValue(EELSRegionSpeech.cellValue(value, kind: .atomic)) "
                                      + ".accessibilityIdentifier(\"eels.regionTable.\\(pin.name).\\(edge.id).at\")"), "the at% cell")
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine) .accessibilityValue(EELSRegionSpeech.visibility(isVisible: pin.isVisible))"),
                      "the name cell is one element that says when its region is hidden")
    }

    /// The total and the t/λ cells say their numbers in the reader's decimal mark, as the cells show them. Red under: "0.5012" spoken beside a cell that
    /// shows "0,5012" (`String(format:)` always writes a point).
    func testTheTotalAndThicknessValuesAreInTheReadersDecimalMark() throws {
        let german = Locale(identifier: "de_DE"), english = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRegionSpeech.tOverLambdaValue(0.50123, locale: german), "0,5012")
        XCTAssertEqual(EELSRegionSpeech.tOverLambdaValue(0.50123, locale: english), "0.5012")
        XCTAssertEqual(EELSRegionSpeech.tOverLambdaValue(0.50123, locale: german), Num.fixed(0.50123, 4, locale: german), "the cell's own text")
        XCTAssertEqual(EELSRegionSpeech.tOverLambdaValue(nil, locale: german), "", "no t/λ: no value, as before")
        XCTAssertEqual(EELSRegionSpeech.totalValue(7_113_000.4, locale: german), "7113000", "a whole number, never grouped")
        XCTAssertEqual(EELSRegionSpeech.totalValue(7_113_000.4, locale: english), "7113000")
        XCTAssertEqual(EELSRegionSpeech.totalText(2_637_954, locale: german), "2637954", "the cell shows it never grouped, as the SEM rooms' counts")
        XCTAssertEqual(EELSRegionSpeech.totalText(2_637_954, locale: english), "2637954")
        XCTAssertEqual(EELSRegionSpeech.totalText(.nan, locale: german), UnitDisplay.noValue, "a sum that is not a number shows a dash")
        XCTAssertEqual(EELSRegionSpeech.totalValue(.nan, locale: german), "none", "and is said as none, as the edge cells' dashes")

        let source = try FFTRoomWiringTests.squeezedUI("EELSRegionsTable.swift")
        XCTAssertTrue(source.contains("Text(EELSRegionSpeech.totalText(row.totalCounts)).monospacedDigit()"),
                      "the cell shows the text its value says (it was the EDS room's thin-space grouping, \"2 637 954\")")
        XCTAssertTrue(source.contains(".accessibilityValue(EELSRegionSpeech.totalValue(row.totalCounts))"))
        XCTAssertTrue(source.contains(".accessibilityValue(EELSRegionSpeech.tOverLambdaValue(row.tOverLambda))"))
        XCTAssertFalse(source.contains("String(format:"), "no accessibility value of the table is written with a fixed point")
    }

    /// The Pixels cell's text, `pixelsText`, writes a region's pixel count never grouped, in any locale, as the total beside it. Red under: a
    /// count written with the locale's grouping ("1.722" in German, as the cell's literal `Text("\(row.pixels)")` drew it).
    func testThePixelsCellWritesItsCountWithoutGrouping() {
        let german = Locale(identifier: "de_DE"), english = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRegionSpeech.pixelsText(1722, locale: german), "1722", "a whole number, never grouped")
        XCTAssertEqual(EELSRegionSpeech.pixelsText(1722, locale: english), "1722")
        XCTAssertEqual(EELSRegionSpeech.pixelsText(12_432, locale: german), EELSRegionSpeech.totalText(12_432, locale: german),
                       "written as the total beside it")
        XCTAssertEqual(EELSRegionSpeech.pixelsText(16, locale: german), "16")
    }
}
