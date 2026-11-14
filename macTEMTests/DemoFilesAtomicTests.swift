//
//  DemoFilesAtomicTests.swift
//  The demo files are written as a new file renamed over the old one, so a window still reading the file written before keeps a
//  whole file (#609); the stack writer refuses a size its 32-bit offsets cannot hold, and its pixel clamps instead of trapping.
//  Red before: the stack and the spectrum were rewritten in place (the same file, truncated, then written), and `UInt16(v)` trapped
//  for a value past 65 535.
//

import Foundation
import TEMSession
import XCTest

nonisolated final class DemoFilesAtomicTests: XCTestCase {

    private func fileNumber(_ url: URL) throws -> Int {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    /// A reader that opened the stack before it is written again still reads every byte of the file it opened.
    func testRewritingTheStackAndTheSpectrumReplacesTheFileAndAnOpenReaderKeepsItsWholeFile() throws {
        for write in [DemoDocuments.stackFile, DemoDocuments.spectrumFile] {
            let url = try write()
            let before = try Data(contentsOf: url)
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            let opened = try fileNumber(url)
            XCTAssertEqual(try write(), url)
            XCTAssertNotEqual(try fileNumber(url), opened, "\(url.lastPathComponent): a new file renamed over the old, not rewritten in place")
            XCTAssertEqual(try reader.readToEnd(), before, "\(url.lastPathComponent): the open reader still sees its whole file")
        }
    }

    func testAStackPastFourGigabytesOrOfNoPageIsRefusedBeforeAnyWrite() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString).tif")
        for (frames, side) in [(0, 8), (2, 0), (40_000, 8_192), (1, Int.max)] {
            XCTAssertThrowsError(try DemoDocuments.writeStackTIFF(to: url, frames: frames, width: side, height: side) { _, _, _ in 0 },
                                 "\(frames) x \(side)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testTheStackPixelClampsAtTheTopOf16Bits() {
        XCTAssertEqual(DemoDocuments.stackPixel(frame: 0, x: 0, y: 0), 1000)
        XCTAssertEqual(DemoDocuments.stackPixel(frame: 0, x: 60_000, y: 60_000), UInt16.max)
    }
}
