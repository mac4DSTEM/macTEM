//
//  EELSMemoryTests.swift
//  The EELS room's memory (macTEM#571): the 1.46 GB float32 145_STEM spectrum image cost 2.8 GB open (widened to Double) and 8.9 GB after
//  Align (the file's cube, the aligned one and a pass's third). A GMS cube is now held as read, four bytes a count, and after Align the room holds
//  the aligned cubes only; a second Align reads the file again. exSpy and GMS hold one float32 cube.
//
//  THE TRUTH: the planted GMS file (Fixtures/eels-planted.dm4), opened through the room as a file is.
//

import XCTest
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSMemoryTests: XCTestCase {
    private static let planted = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/eels-planted.dm4")

    private static func address(_ counts: EELSCounts) -> UInt? {
        if let singles = counts.singles { return singles.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) } }
        return counts.doubles.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }

    /// Red before: the reader's Floats were widened (eight bytes a count).
    func testAGMSCubeIsHeldAtFourBytesACount() throws {
        let loaded = try EELSOpening.open(url: Self.planted)
        XCTAssertEqual(loaded.image.storedCounts.precision.bytes, 4)
        XCTAssertEqual(loaded.fileAxis.channels, loaded.image.channels)
        XCTAssertEqual(EELSOpening.estimatedBytes(nx: 2, ny: 3, channels: 5, bytesPerCount: 4), 120)
    }

    /// After Align the room's cube IS the aligned one (one storage, not two); the Info rows and Align's readout keep the file's axis; a second Align
    /// with other options reads the file again and lands. Red before: `source.image` kept the file's cube beside `alignment.aligned`.
    @MainActor func testAfterAlignTheRoomHoldsOneCube() async throws {
        let session = EELSSession()
        await session.open(url: Self.planted).value
        await session.settled()
        let file = try XCTUnwrap(session.source).fileAxis
        await session.align()?.value
        let alignment = try XCTUnwrap(session.alignment, session.failure ?? "no alignment")
        let source = try XCTUnwrap(session.source)
        XCTAssertTrue(source.cubesAreAligned)
        XCTAssertEqual(Self.address(source.image.storedCounts), Self.address(alignment.aligned.storedCounts), "one cube, shared")
        XCTAssertEqual(source.image.storedCounts.precision.bytes, 4, "still four bytes a count after Align")
        XCTAssertEqual(source.fileAxis, file, "the file's axis is kept")
        let rows = EELSInfoFormat.rows(source, beamEnergyKeV: nil, beamEnergySource: nil, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(rows.contains { $0.label == "Channels" && $0.value == "\(file.channels)" }, "\(rows)")

        session.setAlignCrop(!session.alignChoice.crop)
        await session.align()?.value
        XCTAssertNil(session.failure)
        let again = try XCTUnwrap(session.alignment)
        XCTAssertEqual(again.keptChannels.upperBound <= file.channels, true)
        XCTAssertEqual(session.alignmentReadout?.contains("of \(file.channels) channels"), true, session.alignmentReadout ?? "")
        XCTAssertEqual(Self.address(try XCTUnwrap(session.source).image.storedCounts), Self.address(again.aligned.storedCounts))
    }

    /// A box gives its value once.
    func testAHandoffGivesItsValueOnce() {
        let box = CubeHandoff([Float](repeating: 1, count: 4))
        XCTAssertFalse(box.isEmpty)
        XCTAssertEqual(box.take(), [1, 1, 1, 1])
        XCTAssertTrue(box.isEmpty)
        XCTAssertNil(box.take())
    }
}
