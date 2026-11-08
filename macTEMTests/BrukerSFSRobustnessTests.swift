//
//  BrukerSFSRobustnessTests.swift
//  A damaged Bruker .bcf container is refused in words, never trapped on and never followed round a loop: SFS containers
//  built byte by byte here (the "AAMVHFSS" header, a one-item file tree in chunk 1, the item's pointer table and data) whose
//  chunk number overflows the offset arithmetic, whose stored size passes Int.max, or whose pointer table links back to
//  itself; and a well-formed container of a two-chunk file still reads its bytes exactly.
//  Mutations each test must go red under: the chunk offset multiplied unchecked (a trap); the size converted with Int(_:) (a
//  trap); the pointer-table walk without its visited set (no refusal); a chunk read from the wrong offset (other bytes).
//

import Foundation
import TEMCore
import XCTest

nonisolated final class BrukerSFSRobustnessTests: XCTestCase {

    /// `bytes` as `<fresh temporary folder>/<name>`, removed after the test.
    private func write(_ bytes: [UInt8], named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mactem-sfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// `value` little-endian into `bytes` at `offset`, `count` bytes wide.
    private static func put(_ value: UInt64, _ count: Int, at offset: Int, in bytes: inout [UInt8]) {
        for k in 0..<count { bytes[offset + k] = UInt8(truncatingIfNeeded: value >> (8 * k)) }
    }

    /// An SFS container of `chunks` chunks of `chunkSize` bytes (chunk k's link at k · chunkSize + 0x118, its data from
    /// k · chunkSize + 0x138) whose file tree, in chunk 1, holds one file "data.bin" of `size` bytes with its pointer table in
    /// chunk `table`. The table and the data are the caller's.
    private static func container(chunkSize: Int, chunks: Int, size: UInt64, table: UInt32) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: chunks * chunkSize + 0x118)
        b.replaceSubrange(0..<8, with: Array("AAMVHFSS".utf8))
        put(UInt64(Float(2.4).bitPattern), 4, at: 0x124, in: &b)
        put(UInt64(chunkSize), 4, at: 0x128, in: &b)
        put(1, 4, at: 0x140, in: &b)                          // the tree's chunk
        put(1, 4, at: 0x144, in: &b)                          // one item
        let item = chunkSize + 0x138
        put(UInt64(table), 4, at: item, in: &b)
        put(size, 8, at: item + 4, in: &b)
        put(UInt64(UInt32.max), 4, at: item + 40, in: &b)     // parent -1: at the root
        b.replaceSubrange((item + 224)..<(item + 232), with: Array("data.bin".utf8))
        return b
    }

    /// A chunk number whose offset passes Int.max (chunk size 0xFFFFFFFF times tree chunk 0xFFFFFFFF), and a stored size of
    /// 2^63 bytes, are refused in a sentence naming the file; before, each trapped on the arithmetic.
    func testAnOffsetOrASizePastIntMaxIsRefused() throws {
        var header = [UInt8](repeating: 0, count: 0x400)
        header.replaceSubrange(0..<8, with: Array("AAMVHFSS".utf8))
        Self.put(UInt64(Float(2.4).bitPattern), 4, at: 0x124, in: &header)
        Self.put(0xFFFF_FFFF, 4, at: 0x128, in: &header)
        Self.put(0xFFFF_FFFF, 4, at: 0x140, in: &header)
        Self.put(1, 4, at: 0x144, in: &header)
        let far = try write(header, named: "far.bcf")
        XCTAssertThrowsError(try BrukerSFS(url: far)) { error in
            XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("far.bcf") ?? false, "\(error)")
        }

        let huge = try write(Self.container(chunkSize: 0x220, chunks: 5, size: 1 << 63, table: 2), named: "huge.bcf")
        XCTAssertThrowsError(try BrukerSFS(url: huge)) { error in
            XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("huge.bcf") ?? false, "\(error)")
        }
    }

    /// A file of 129 chunks needs a pointer table of two chunks; this one's first table chunk links to itself. It is refused
    /// on the second visit; before, the walk read the same chunk again and the container opened on a table of zeros (and a
    /// claimed size of terabytes kept it appending for as many steps).
    func testAPointerTableThatLinksBackToItselfIsRefused() throws {
        let chunkSize = 0x220, usable = chunkSize - 0x20
        var b = Self.container(chunkSize: chunkSize, chunks: 130, size: UInt64(129 * usable), table: 2)
        Self.put(2, 4, at: 2 * chunkSize + 0x118, in: &b)
        let url = try write(b, named: "loop.bcf")
        XCTAssertThrowsError(try BrukerSFS(url: url)) { error in
            XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("links back to chunk 2") ?? false, "\(error)")
        }
    }

    /// A well-formed container: a 600-byte file in chunks 3 and 4 (512 + 88 bytes), its one-chunk pointer table in chunk 2. It
    /// opens, plain (no "AACS" block), and reads back exactly the bytes written.
    func testAWellFormedTwoChunkContainerReadsItsBytes() throws {
        let chunkSize = 0x220, usable = chunkSize - 0x20
        let payload = (0..<600).map { UInt8(($0 * 7 + 3) % 251) }
        var b = Self.container(chunkSize: chunkSize, chunks: 5, size: UInt64(payload.count), table: 2)
        Self.put(3, 4, at: 2 * chunkSize + 0x138, in: &b)
        Self.put(4, 4, at: 2 * chunkSize + 0x138 + 4, in: &b)
        b.replaceSubrange((3 * chunkSize + 0x138)..<(3 * chunkSize + 0x138 + usable), with: payload[0..<usable])
        b.replaceSubrange((4 * chunkSize + 0x138)..<(4 * chunkSize + 0x138 + payload.count - usable), with: payload[usable...])
        let sfs = try BrukerSFS(url: try write(b, named: "good.bcf"))
        XCTAssertFalse(sfs.isZlib)
        XCTAssertEqual(sfs.chunkSize, chunkSize)
        let item = try XCTUnwrap(sfs.item(path: "data.bin"))
        XCTAssertEqual(item.size, 600)
        XCTAssertEqual(item.pointers, [3 * chunkSize + 0x138, 4 * chunkSize + 0x138])
        XCTAssertEqual(try sfs.contents(item), payload)
        XCTAssertEqual(try sfs.readPiece(item, offset: 500, length: 20), Array(payload[500..<520]), "a piece across the chunk seam")
    }
}
