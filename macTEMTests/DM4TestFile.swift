//
//  DM4TestFile.swift
//  Test support, no tests: a minimal DM4 written in memory, tag by tag, for the object-rule and refusal tests
//  (ImageOpeningTests). The grammar is the one DM4Experiment walks (and tools/parity/dm4-reader-parity/dm4_writer.py
//  writes): version 4, little-endian data, big-endian tag headers, 8-byte sizes, strings as ushort arrays, an empty
//  label numbered one-based by position. DM4ImageObject and DM4Image have no package initialiser, so a test builds
//  them by listing and reading these bytes.
//

import Foundation
import XCTest

nonisolated enum DM4TestFile {

    nonisolated indirect enum Node: Sendable {
        case int(String, Int32)
        case float(String, Float)
        case double(String, Double)
        case text(String, String)
        case group(String, [Node])
        case blob(String, elementType: Int, bytes: [UInt8], count: Int)
    }

    /// One calibrated axis as the file stores it: Origin and Scale are float32, as GMS writes them.
    nonisolated struct Axis: Sendable {
        let origin: Float
        let scale: Float
        let units: String
    }

    /// The whole file: `ImageList` with `objects` in order, then `extraRoot` (a `Thumbnails` list, say).
    static func file(_ objects: [Node], extraRoot: [Node] = []) -> Data {
        let kids = [Node.group("ImageList", objects)] + extraRoot
        let body: [UInt8] = [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        return Data([0, 0, 0, 4] + u64be(0) + [0, 0, 0, 1] + body)
    }

    /// One `ImageList` entry. `axes` nil writes no `Calibrations` group (an uncalibrated object); `name` nil writes
    /// no `Name` tag. Pixels are int16 (DM type 1) unless `rgba` (type 23, the thumbnail's).
    static func object(name: String?, dims: [Int32], axes: [Axis]?, pixels: [Int16]? = nil,
                       rgba: Bool = false, voltage: Double? = nil) -> Node {
        let count = dims.reduce(1) { $0 * Int($1) }
        let blob: Node
        if rgba {
            blob = .blob("Data", elementType: 5, bytes: [UInt8](repeating: 9, count: count * 4), count: count)
        } else {
            let values = pixels ?? (0..<count).map { Int16(truncatingIfNeeded: $0) }
            precondition(values.count == count, "DM4TestFile: \(values.count) pixels for \(dims)")
            blob = .blob("Data", elementType: 2,
                         bytes: values.flatMap { le(UInt64(UInt16(bitPattern: $0)), 2) }, count: count)
        }
        var imageData: [Node] = [blob, .int("DataType", rgba ? 23 : 1), .group("Dimensions", dims.map { .int("", $0) })]
        if let axes {
            imageData.append(.group("Calibrations", [.group("Dimension", axes.map {
                .group("", [.float("Origin", $0.origin), .float("Scale", $0.scale), .text("Units", $0.units)])
            })]))
        }
        var tags: [Node] = []
        if let voltage { tags.append(.group("Microscope Info", [.double("Voltage", voltage)])) }
        var kids: [Node] = []
        if let name { kids.append(.text("Name", name)) }
        kids += [.group("ImageData", imageData), .group("ImageTags", tags)]
        return .group("", kids)
    }

    /// The root `Thumbnails` list naming object `zeroBasedIndex` (0 is ImageList.1) as the thumbnail.
    static func thumbnailList(_ zeroBasedIndex: Int32) -> Node {
        .group("Thumbnails", [.group("", [.int("ImageIndex", zeroBasedIndex)])])
    }

    /// Writes `data` as `<fresh temporary folder>/<name>` so a message naming the file can be checked exactly.
    static func write(_ data: Data, named name: String, for test: XCTestCase) throws -> String {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mactem-dm4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return url.path
    }

    // MARK: Encoding

    private static func u16be(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func u64be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) } }
    private static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> UInt64(8 * $0)) & 0xFF) } }
    private static let delimiter: [UInt8] = [37, 37, 37, 37]

    private static func head(_ tag: UInt8, _ label: String) -> [UInt8] {
        [tag] + u16be(label.utf8.count) + Array(label.utf8) + u64be(0)
    }

    private static func encode(_ node: Node) -> [UInt8] {
        switch node {
        case .int(let l, let v):
            return head(21, l) + delimiter + u64be(1) + u64be(3) + le(UInt64(UInt32(bitPattern: v)), 4)
        case .float(let l, let v):
            return head(21, l) + delimiter + u64be(1) + u64be(6) + le(UInt64(v.bitPattern), 4)
        case .double(let l, let v):
            return head(21, l) + delimiter + u64be(1) + u64be(7) + le(v.bitPattern, 8)
        case .text(let l, let s):
            let units = Array(s.utf16)
            return head(21, l) + delimiter + u64be(3) + u64be(20) + u64be(4) + u64be(UInt64(units.count))
                + units.flatMap { le(UInt64($0), 2) }
        case .group(let l, let kids):
            return head(20, l) + [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        case .blob(let l, let elementType, let bytes, let count):
            return head(21, l) + delimiter + u64be(3) + u64be(20) + u64be(UInt64(elementType))
                + u64be(UInt64(count)) + bytes
        }
    }
}
