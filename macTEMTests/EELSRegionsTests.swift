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
}
