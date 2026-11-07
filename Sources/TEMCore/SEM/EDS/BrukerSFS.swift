//
//  BrukerSFS.swift
//  Role: AidAim's single file system (SFS), the container of a Bruker `.bcf`, read as RosettaSciIO 0.15.0 reads it
//        (`rsciio/bruker/_api.py`: `SFS_reader`, `SFSTreeItem`; GPL-3.0-or-later): the "AAMVHFSS" header (version, chunk size), the
//        file tree (512-byte items: pointer-table chunk, size, parent, directory flag, name), each file's chunk pointer table (which
//        continues through linked chunks when it outgrows one), and a file's bytes, plain or in AACS zlib blocks (the compression is
//        one for the whole container, read from the first file's first chunk). A file is read block by block, never whole, so a
//        hypermap of gigabytes streams through a few chunk-sized buffers. Encrypted containers and other compressions are refused.
//

import Compression
import Foundation

package nonisolated final class BrukerSFS {
    package struct Item {
        package var name: String
        package var path: String
        package var size: Int
        package var isDirectory: Bool
        /// Absolute file offsets of the file's chunks (`pointers` in rsciio: chunk number · chunk size + 0x138).
        package var pointers: [Int]
        /// zlib: the uncompressed size of a block and the number of blocks.
        package var blockSize = 0
        package var blockCount = 0
    }

    package let url: URL
    package let version: String
    package let chunkSize: Int
    package let usableChunk: Int
    package let isZlib: Bool
    package private(set) var items: [Item] = []
    private let handle: FileHandle
    private let fileLength: Int

    package init(url: URL) throws {
        self.url = url
        let name = url.lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SEMEDSReadError("\(name) could not be opened.") }
        self.handle = handle
        let fileLength = Int((try? handle.seekToEnd()) ?? 0)
        self.fileLength = fileLength
        let head = try Self.read(handle, at: 0, count: min(0x14C, fileLength), length: fileLength, name: name)
        guard head.count >= 8, Array(head[0..<8]) == Array("AAMVHFSS".utf8) else {
            throw SEMEDSReadError("\(name) is not a Bruker file: it is not an SFS container (RosettaSciIO refuses it too).")
        }
        let h = SEMEDSBytes(head, name: name)
        let v = try h.f32(0x124)
        version = String(format: "%4.2f", Double(v))
        let chunkSize = Int(try h.u32(0x128))
        guard chunkSize > 0x138 else { throw SEMEDSReadError("\(name) states an SFS chunk of \(chunkSize) bytes, too small to hold data.") }
        self.chunkSize = chunkSize
        usableChunk = chunkSize - 32
        let treeAddress = Int(try h.u32(0x140)), treeItems = Int(try h.u32(0x144))
        guard treeItems > 0, treeItems < 1_000_000 else { throw SEMEDSReadError("\(name) holds no SFS file tree.") }

        // The file tree: 0x200 bytes per item, through linked chunks when it outgrows one.
        let treeChunks = (treeItems * 0x200 + (chunkSize - 0x20) - 1) / (chunkSize - 0x20)
        var rawTree: [UInt8]
        if treeChunks == 1 {
            rawTree = try Self.read(handle, at: chunkSize * treeAddress + 0x138, count: 0x200 * treeItems, length: fileLength, name: name)
        } else {
            rawTree = []
            var address = treeAddress
            let perChunk = (chunkSize - 0x20) / 0x200
            for _ in 0..<treeChunks {
                let next = SEMEDSBytes(try Self.read(handle, at: chunkSize * address + 0x118, count: 4, length: fileLength, name: name), name: name)
                rawTree += try Self.read(handle, at: chunkSize * address + 0x138, count: perChunk * 0x200, length: fileLength, name: name)
                address = Int(try next.u32(0))
            }
            rawTree = Array(rawTree.prefix(treeItems * 0x200))
        }
        guard rawTree.count == treeItems * 0x200 else { throw SEMEDSReadError("\(name) ends inside its SFS file tree.") }

        var parsed: [(item: Item, parent: Int, pointerTable: Int)] = []
        for i in 0..<treeItems {
            let b = SEMEDSBytes(Array(rawTree[(i * 0x200)..<((i + 1) * 0x200)]), name: name)
            let pointerTable = Int(try b.i32(0))
            let size = Int(try b.u64(4))
            let parent = Int(try b.i32(40))
            let isDir = try b.u8(220) != 0
            let itemName = SEMEDSText.decode(try b.slice(224, 256), stripLeading: true)
            parsed.append((Item(name: itemName, path: "", size: size, isDirectory: isDir, pointers: []), parent, pointerTable))
        }
        for i in parsed.indices {
            var names = [parsed[i].item.name]
            var p = parsed[i].parent, guardSteps = 0
            while p >= 0, p < parsed.count, guardSteps < parsed.count {
                names.insert(parsed[p].item.name, at: 0); p = parsed[p].parent; guardSteps += 1
            }
            parsed[i].item.path = names.joined(separator: "/")
            if !parsed[i].item.isDirectory {
                parsed[i].item.pointers = try Self.pointerTable(handle, first: parsed[i].pointerTable, size: parsed[i].item.size,
                                                                chunkSize: chunkSize, usable: chunkSize - 32, length: fileLength, name: name)
            }
        }
        // The compression is the container's: the first file's first chunk starts with "AACS" or it is plain.
        var zlib = false
        if let first = parsed.first(where: { !$0.item.isDirectory && !$0.item.pointers.isEmpty }) {
            zlib = try Self.read(handle, at: first.item.pointers[0], count: 4, length: fileLength, name: name) == Array("AACS".utf8)
        }
        isZlib = zlib
        if zlib {
            for i in parsed.indices where !parsed[i].item.isDirectory {
                guard let p0 = parsed[i].item.pointers.first else { continue }
                let c = SEMEDSBytes(try Self.read(handle, at: p0, count: 16, length: fileLength, name: name), name: name)
                guard try c.u32(0) == 0x5343_4141 else {
                    throw SEMEDSReadError("\(name) is marked compressed, but \(parsed[i].item.path) has no compression header.")
                }
                parsed[i].item.blockSize = Int(try c.u32(4))
                parsed[i].item.blockCount = Int(try c.u32(12))
            }
        }
        items = parsed.map(\.item)
    }

    deinit { try? handle.close() }

    package func item(path: String) -> Item? { items.last { $0.path == path } }

    private static func read(_ handle: FileHandle, at offset: Int, count: Int, length: Int, name: String) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset + count <= length else {
            throw SEMEDSReadError("\(name) ends inside its SFS container (byte \(offset + count) of \(length)).")
        }
        if count == 0 { return [] }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw SEMEDSReadError("\(name) could not be read at byte \(offset).") }
        return [UInt8](data)
    }

    private static func pointerTable(_ handle: FileHandle, first: Int, size: Int, chunkSize: Int, usable: Int, length: Int,
                                     name: String) throws -> [Int] {
        let chunks = (size + usable - 1) / usable
        let tableChunks = (chunks + usable / 4 - 1) / (usable / 4)
        var table: [UInt8] = []
        if tableChunks > 1 {
            var next = first
            for _ in 0..<tableChunks {
                let link = SEMEDSBytes(try read(handle, at: chunkSize * next + 0x118, count: 4, length: length, name: name), name: name)
                table += try read(handle, at: chunkSize * next + 0x138, count: usable, length: length, name: name)
                next = Int(try link.u32(0))
            }
        } else {
            table = try read(handle, at: chunkSize * first + 0x138, count: min(usable, max(chunks * 4, 0)), length: length, name: name)
        }
        let t = SEMEDSBytes(table, name: name)
        return try (0..<chunks).map { Int(try t.u32($0 * 4)) * chunkSize + 0x138 }
    }

    /// `length` bytes of the stored (not decompressed) file from `offset` (rsciio `read_piece`).
    package func readPiece(_ item: Item, offset: Int, length: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var off = offset, remaining = length
        while remaining > 0 {
            let chunk = off / usableChunk, within = off % usableChunk
            guard chunk < item.pointers.count else { throw SEMEDSReadError("\(item.path) in \(url.lastPathComponent) ends early.") }
            let n = min(remaining, usableChunk - within)
            out += try Self.read(handle, at: item.pointers[chunk] + within, count: n, length: fileLength, name: url.lastPathComponent)
            off += n; remaining -= n
        }
        return out
    }

    /// The file's content block by block (decompressed when the container is zlib), for `ByteStream`.
    package func blocks(_ item: Item) -> () throws -> [UInt8]? {
        if isZlib {
            var offset = 0x80, block = 0
            return { [self] in
                guard block < item.blockCount else { return nil }
                let head = SEMEDSBytes(try readPiece(item, offset: offset, length: 16), name: url.lastPathComponent)
                let compressed = Int(try head.u32(0))
                offset += 16
                let raw = try readPiece(item, offset: offset, length: compressed)
                offset += compressed; block += 1
                return try Self.inflate(raw, name: url.lastPathComponent)
            }
        }
        var index = 0
        return { [self] in
            guard index < item.pointers.count else { return nil }
            let last = index == item.pointers.count - 1
            let rest = item.size % usableChunk
            let n = last && rest != 0 ? rest : usableChunk
            let out = try Self.read(handle, at: item.pointers[index], count: n, length: fileLength, name: url.lastPathComponent)
            index += 1
            return out
        }
    }

    /// The whole file (for the XML header, which is small).
    package func contents(_ item: Item) throws -> [UInt8] {
        var out: [UInt8] = []
        let next = blocks(item)
        while let block = try next() { out += block }
        return out
    }

    /// A zlib stream (2-byte header, deflate, Adler-32) decompressed with the Compression framework's raw deflate.
    package static func inflate(_ zlib: [UInt8], name: String) throws -> [UInt8] {
        guard zlib.count > 2, zlib[0] & 0x0F == 8, (UInt16(zlib[0]) << 8 | UInt16(zlib[1])) % 31 == 0, zlib[1] & 0x20 == 0 else {
            throw SEMEDSReadError("\(name) holds a compressed block that is not a zlib stream.")
        }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SEMEDSReadError("The zlib decoder could not be started for \(name).")
        }
        defer { compression_stream_destroy(stream) }
        let capacity = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var out: [UInt8] = []
        let body = Array(zlib[2...])
        try body.withUnsafeBufferPointer { src in
            stream.pointee.src_ptr = src.baseAddress!
            stream.pointee.src_size = src.count
            var status = COMPRESSION_STATUS_OK
            repeat {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = capacity
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw SEMEDSReadError("A compressed block of \(name) is damaged.") }
                out.append(contentsOf: UnsafeBufferPointer(start: buffer, count: capacity - stream.pointee.dst_size))
            } while status == COMPRESSION_STATUS_OK
        }
        return out
    }
}

/// A contiguous byte stream over a sequence of blocks (rsciio's `DataStream` in `unbcf_fast.pyx`: the rest of a block joined to
/// the next when a read runs past its end).
package nonisolated struct SEMEDSByteStream {
    private var buffer: [UInt8] = []
    private var position = 0
    /// Bytes dropped from the front of `buffer` so far: `consumed + position` is the absolute offset.
    private var consumed = 0
    private let next: () throws -> [UInt8]?
    private let name: String

    package init(name: String, next: @escaping () throws -> [UInt8]?) {
        self.name = name; self.next = next
    }

    private mutating func need(_ n: Int) throws {
        while buffer.count - position < n {
            guard let block = try next() else { throw SEMEDSReadError("The spectral data of \(name) ends early.") }
            if position > 0 { buffer.removeFirst(position); consumed += position; position = 0 }
            buffer += block
        }
    }

    package mutating func seek(_ offset: Int) throws { try skip(offset - consumed - position) }
    package mutating func skip(_ n: Int) throws { try need(n); position += n }
    package mutating func u16() throws -> UInt16 {
        try need(2); defer { position += 2 }
        return UInt16(buffer[position]) | UInt16(buffer[position + 1]) << 8
    }
    package mutating func u32() throws -> UInt32 {
        try need(4); defer { position += 4 }
        return UInt32(buffer[position]) | UInt32(buffer[position + 1]) << 8 | UInt32(buffer[position + 2]) << 16 | UInt32(buffer[position + 3]) << 24
    }
    /// The next `n` bytes, consumed.
    package mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        try need(n); defer { position += n }
        return buffer[position..<(position + n)]
    }
}
