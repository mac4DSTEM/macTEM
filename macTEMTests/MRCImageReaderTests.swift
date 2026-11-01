//
//  MRCImageReaderTests.swift
//  The MRC reader on MRC2014 files built in memory with known values: the planted truth is the bytes
//  written here. The parity against mrcfile is FormatoKit's; these pin the reader's own rules without
//  Python — modes and byte order, the extended header, the Å scale, the non-positive cell, the refusals.
//

import ImagoCore
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class MRCImageReaderTests: XCTestCase {

    func testMode0IsSignedAndRowZeroIsTheFilesFirstRow() throws {
        let values: [Int8] = [-128, -1, 0, 1, 127, -77]
        let file = MRCBuilder(nx: 3, ny: 2, mode: 0, data: values.map { UInt8(bitPattern: $0) })
        let image = try MRCImageReader.read(data: file.build(), fileName: "m0.mrc")
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.pixels, values.map(Float.init))
    }

    func testEveryModeInBothByteOrders() throws {
        let i16: [Int16] = [-32_768, -2, 0, 3, 32_767, 1_234]
        let u16: [UInt16] = [0, 40_000, 65_535, 1, 2, 3]
        let f32: [Float] = [-1.5, 0, 3.25e-7, 1e30, 42, -0.0]
        let f16: [Float16] = [-2.5, 0, 0.000_06103515625, 65_504, 1, -1]
        for big in [false, true] {
            func read(_ mode: Int, _ words: [UInt8]) throws -> [Float] {
                var file = MRCBuilder(nx: 3, ny: 2, mode: mode, data: words)
                file.bigEndian = big
                return try MRCImageReader.read(data: file.build(), fileName: "m.mrc").pixels
            }
            let e = { (v: UInt16) in big ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)] }
            let e32 = { (v: UInt32) in (big ? [24, 16, 8, 0] : [0, 8, 16, 24]).map { UInt8((v >> UInt32($0)) & 0xFF) } }
            XCTAssertEqual(try read(1, i16.flatMap { e(UInt16(bitPattern: $0)) }), i16.map(Float.init), "int16, big \(big)")
            XCTAssertEqual(try read(6, u16.flatMap(e)), u16.map(Float.init), "uint16, big \(big)")
            XCTAssertEqual(try read(2, f32.flatMap { e32($0.bitPattern) }).map(\.bitPattern), f32.map(\.bitPattern))
            XCTAssertEqual(try read(12, f16.flatMap { e($0.bitPattern) }), f16.map(Float.init), "float16, big \(big)")
        }
    }

    func testTheExtendedHeaderIsSkipped() throws {
        var file = MRCBuilder(nx: 2, ny: 1, mode: 0, data: [5, 6])
        file.extended = [UInt8](repeating: 0xEE, count: 1024)
        XCTAssertEqual(try MRCImageReader.read(data: file.build(), fileName: "ext.mrc").pixels, [5, 6])
    }

    func testScaleIsTheCellOverTheSamplingInAngstrom() throws {
        var file = MRCBuilder(nx: 40, ny: 24, mode: 0, data: [UInt8](repeating: 1, count: 960))
        file.cell = (52.3, 31.7)
        file.sampling = (40, 24)
        let image = try MRCImageReader.read(data: file.build(), fileName: "cell.mrc")
        XCTAssertEqual(image.x, AxisCalibration(scale: Double(Float(Double(Float(52.3)) / 40)), unit: "Å", origin: 0))
        XCTAssertEqual(image.y, AxisCalibration(scale: Double(Float(Double(Float(31.7)) / 24)), unit: "Å", origin: 0))
        XCTAssertNotEqual(image.x?.scale, image.y?.scale, "x and y are not swapped")
        XCTAssertEqual(image.notes, [])
    }

    func testANonPositiveCellOpensUncalibratedAndSaysWhy() throws {
        var file = MRCBuilder(nx: 2, ny: 1, mode: 0, data: [1, 2])
        file.cell = (-80, 10)
        let image = try MRCImageReader.read(data: file.build(), fileName: "de.mrc")
        XCTAssertNil(image.x)
        XCTAssertNil(image.y)
        XCTAssertEqual(image.notes, [MRCImageReader.Note.nonPositiveCell])
        XCTAssertEqual(MRCImageReader.Note.nonPositiveCell, "uncalibrated: the cell length is not positive", "the wording, pinned literally")
    }

    func testAnFEISizedExtendedHeaderIsNotReadAsACellCalibration() throws {
        var file = MRCBuilder(nx: 2, ny: 1, mode: 0, data: [1, 2])
        file.extended = [UInt8](repeating: 0, count: 128 * 1024)
        file.cell = (3, 1.5)
        let image = try MRCImageReader.read(data: file.build(), fileName: "fei.mrc")
        XCTAssertNil(image.x)
        XCTAssertEqual(image.notes, [MRCImageReader.Note.feiHeader])
        XCTAssertEqual(MRCImageReader.Note.feiHeader, "uncalibrated: an FEI extended header holds the pixel size, not read", "the wording, pinned literally")
    }

    func testRefusalsAreNamed() {
        func refusal(_ edit: (inout MRCBuilder) -> Void) -> MRCImageReader.Refusal? {
            var file = MRCBuilder(nx: 2, ny: 2, mode: 0, data: [1, 2, 3, 4])
            edit(&file)
            do { _ = try MRCImageReader.read(data: file.build(), fileName: "x.mrc"); return nil }
            catch { return error as? MRCImageReader.Refusal }
        }
        XCTAssertEqual(refusal { $0.nz = 3; $0.data += [UInt8](repeating: 0, count: 8) }, .stack(frames: 3))
        XCTAssertEqual(refusal { $0.mode = 4 }, .mode(4))
        XCTAssertEqual(refusal { $0.mode = 101 }, .mode(101))
        XCTAssertEqual(refusal { $0.stamp = [0, 0, 0, 0] }, .byteOrder(stamp: [0, 0, 0, 0]))
        XCTAssertEqual(refusal { $0.map = "NOPE" }, .notMRC("no \"MAP \" id"))
        XCTAssertEqual(refusal { $0.axes = (2, 1, 3) }, .axisOrder(mapc: 2, mapr: 1, maps: 3))
        XCTAssertEqual(refusal { $0.data.removeLast() }, .truncated)
        XCTAssertEqual(refusal { $0.claimedExtended = 4096 }, .truncated)
        XCTAssertEqual(refusal { $0.nx = 0 }, .notMRC("0 × 2 × 1"))
        XCTAssertEqual(refusal { $0.nz = 0 }, .notMRC("2 × 2 × 0"))
        XCTAssertEqual(refusal { $0.mode = 3; $0.nz = 3 }, .mode(3), "two defects: the mode is named before the stack")
        XCTAssertThrowsError(try MRCImageReader.read(data: Data(count: 100), fileName: "short.mrc"))
    }
}

/// A minimal MRC2014 writer for planted files.
private nonisolated struct MRCBuilder {
    var nx: Int, ny: Int, nz = 1, mode: Int
    var data: [UInt8]
    var bigEndian = false
    var cell: (Float, Float) = (10, 10)
    var sampling: (Int, Int)?
    var axes = (1, 2, 3)
    var extended: [UInt8] = []
    var claimedExtended: Int?
    var map = "MAP "
    var stamp: [UInt8]?

    init(nx: Int, ny: Int, mode: Int, data: [UInt8]) {
        (self.nx, self.ny, self.mode, self.data) = (nx, ny, mode, data)
    }

    func build() -> Data {
        var header = [UInt8](repeating: 0, count: 1024)
        func put(_ index: Int, _ v: UInt32) {
            let b = (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) }
            header.replaceSubrange((4 * index)..<(4 * index + 4), with: bigEndian ? b.reversed() : b)
        }
        func put(_ index: Int, int v: Int) { put(index, UInt32(bitPattern: Int32(v))) }
        put(0, int: nx); put(1, int: ny); put(2, int: nz); put(3, int: mode)
        put(7, int: sampling?.0 ?? nx); put(8, int: sampling?.1 ?? ny); put(9, int: nz)
        put(10, cell.0.bitPattern); put(11, cell.1.bitPattern); put(12, Float(1).bitPattern)
        put(16, int: axes.0); put(17, int: axes.1); put(18, int: axes.2)
        put(23, int: claimedExtended ?? extended.count)
        header.replaceSubrange(208..<212, with: Array(map.utf8))
        header.replaceSubrange(212..<216, with: stamp ?? (bigEndian ? [0x11, 0x11, 0, 0] : [0x44, 0x44, 0, 0]))
        return Data(header + extended + data)
    }
}
