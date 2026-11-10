//
//  JEOLMapReadProgressTests.swift
//  A JEOL `.pts` map says how far its read is and can be stopped (#296). The committed 512 x 512 map holds four complete sweeps in
//  196 414 event words: the read reports the share of the stream read after each (49 660, 98 602, 147 633 and 196 414 words), the
//  open then reports 1, and the counts are the ones the parity bundle keeps (88 272 X-rays in 88 059 nonzero cells). A read whose
//  task is cancelled while it reports the first sweep throws `CancellationError` before the second and hands nothing over. Damaged
//  copies read as they did when the whole file was held in memory: one cut a byte into the word after its first sweep is that sweep,
//  one whose stream offset points into its header is an empty map, one cut inside its header is refused in the reader's sentence.
//
//  Red before the change: the open reported once, when the whole file had been read, so the five reports were one and the
//  cancelled read returned its map. The damaged copies read the same before and after: that test guards the mapped read.
//

import Foundation
import SpectroCore
import TEMCore
import XCTest

nonisolated final class JEOLMapReadProgressTests: XCTestCase {

    /// The committed map: 512 x 512 pixels, four complete sweeps, its event stream from byte 16 384.
    private static var map: URL {
        SEMParityReference.fixturesRoot.appendingPathComponent("rsciio/jeol/View000_0000006_4frames.pts")
    }

    /// The event words of its stream, and the word each of its sweeps ends at.
    private static let words = 196_414
    private static let sweepEnds = [49_660, 98_602, 147_633, 196_414]

    /// A fresh temporary folder, removed after the test.
    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mactem-pts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Each complete sweep reports the share of the event stream read so far, then the open reports 1; the counts are unchanged.
    func testAJEOLMapReportsEachSweepOfItsEventStream() throws {
        let reported = ReportedFractions()
        let loaded = try EDXOpening.open(url: Self.map, progress: { reported.add($0) })
        var expected: [Double] = Self.sweepEnds.map { Double($0) / Double(Self.words) }
        expected.append(1)
        XCTAssertEqual(reported.values, expected)
        XCTAssertEqual(loaded.nx, 512)
        let cube = try XCTUnwrap(loaded.image as? CSRSpectrumImage)
        XCTAssertEqual(cube.counts.count, 88_059)
        XCTAssertEqual(cube.counts.reduce(UInt64(0)) { $0 + UInt64($1) }, 88_272)
    }

    /// A read whose task is cancelled as it reports its first sweep stops before the second: `CancellationError`, and no map.
    func testACancelledJEOLMapReadStopsBeforeItsNextSweep() async throws {
        let reported = ReportedFractions()
        let url = Self.map
        let task = Task { () async throws -> Int in
            try EDXOpening.open(url: url, progress: { fraction in
                reported.add(fraction)
                withUnsafeCurrentTask { $0?.cancel() }
            }).nx
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled read returned its map")
        } catch is CancellationError {}
        XCTAssertEqual(reported.values, [Double(Self.sweepEnds[0]) / Double(Self.words)])
    }

    /// A copy cut one byte into the word after its first sweep reads as that sweep (the odd byte is no word). A copy whose stream
    /// offset points into its header still finds the header and reads an empty map (its first frame is incomplete). A copy cut
    /// inside its header is refused, the sentence stating the file's own length.
    func testADamagedMapReadsOrIsRefusedAsBefore() throws {
        let folder = try scratchFolder()
        let whole = try Data(contentsOf: Self.map)

        let oneSweep = folder.appendingPathComponent("one-sweep.pts")
        try whole.prefix(16_384 + 2 * Self.sweepEnds[0] + 1).write(to: oneSweep)
        let cube = try XCTUnwrap(try JEOLEDSReader.read(url: oneSweep).spectrumImages.first).cube
        XCTAssertEqual(cube.counts.reduce(UInt64(0)) { $0 + UInt64($1) }, 22_355)

        // The stream offset (the little-endian word at byte 28) as 1000: inside the header tree, which starts at byte 317.
        var early = whole
        early[28] = 0xE8
        early[29] = 0x03
        early[30] = 0
        early[31] = 0
        let earlyStream = folder.appendingPathComponent("early-stream.pts")
        try early.write(to: earlyStream)
        let empty = try XCTUnwrap(try JEOLEDSReader.read(url: earlyStream).spectrumImages.first)
        XCTAssertEqual(empty.cube.nx, 512)
        XCTAssertEqual(empty.cube.counts.count, 0)

        let cutHeader = folder.appendingPathComponent("cut-header.pts")
        try whole.prefix(8_000).write(to: cutHeader)
        XCTAssertThrowsError(try JEOLEDSReader.read(url: cutHeader)) { error in
            let text = (error as? SEMEDSReadError)?.text ?? ""
            XCTAssertTrue(text.contains("ends before its header says it does"), "\(error)")
            XCTAssertTrue(text.hasSuffix("of 8000)."), "\(error)")
        }
    }
}

/// The fractions a read reported, in order.
private nonisolated final class ReportedFractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ fraction: Double) { lock.withLock { stored.append(fraction) } }
    var values: [Double] { lock.withLock { stored } }
}
