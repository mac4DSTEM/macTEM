//
//  SEMEDSAllocationTests.swift
//  The SEM-EDS readers and the master-pattern reader size nothing from a header before checking it: SEMEDSFile.checkedCount
//  (the overflow-checked product of a header's sizes, held to the bytes the file holds for them), the spectrum image
//  builder's overflow check and pixel cap, an EDAX .spd header written here that states 2^31 x 2^32 pixels, and EMsoft's npx.
//  The committed EDAX fixtures' sizes pass exactly.
//  Mutations each test must go red under: checkedCount without its overflow check (a trap) or its file bound (no refusal);
//  the builder's ny · nx unchecked (a trap); the .spd check moved after the builder (a trap in reserveCapacity);
//  patternSide without its overflow check (a trap).
//

import Foundation
import TEMCore
import XCTest

nonisolated final class SEMEDSAllocationTests: XCTestCase {

    /// `bytes` as `<fresh temporary folder>/<name>`, removed after the test.
    private func write(_ bytes: [UInt8], named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mactem-eds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// `value` little-endian into `bytes` at `offset`, 4 bytes wide.
    private static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for k in 0..<4 { bytes[offset + k] = UInt8(truncatingIfNeeded: value >> (8 * k)) }
    }

    /// An EDAX map: the 1068-byte header (nSpectra, nx, ny, nz, countBytes, dataOffset 1068) and `data` bytes of counts.
    private static func spd(nx: UInt32, ny: UInt32, nz: UInt32, countBytes: UInt32, data: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 1068 + data)
        b.replaceSubrange(0..<15, with: Array("MAPSPECTRA_DATA".utf8))
        put32(1, at: 20, in: &b)
        put32(nx, at: 24, in: &b)
        put32(ny, at: 28, in: &b)
        put32(nz, at: 32, in: &b)
        put32(countBytes, at: 36, in: &b)
        put32(1068, at: 40, in: &b)
        return b
    }

    /// The product of the dims, refused when it overflows (in items or in bytes), when a dim is negative, or when it needs more
    /// bytes than the file holds; an empty dim gives 0.
    func testCheckedCountRefusesAnOverflowOrMoreThanTheFileHolds() throws {
        XCTAssertEqual(try SEMEDSFile.checkedCount(dims: [3, 4, 5], bytesPerItem: 2, fileLength: 120, name: "a.spd"), 60)
        XCTAssertThrowsError(try SEMEDSFile.checkedCount(dims: [3, 4, 5], bytesPerItem: 2, fileLength: 119, name: "a.spd")) { error in
            XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("a.spd") ?? false, "\(error)")
        }
        XCTAssertThrowsError(try SEMEDSFile.checkedCount(dims: [Int.max / 2, 3], bytesPerItem: 1, fileLength: .max, name: "b.spd"))
        XCTAssertThrowsError(try SEMEDSFile.checkedCount(dims: [1 << 40, 1 << 20], bytesPerItem: 8, fileLength: .max, name: "c.spd"))
        XCTAssertThrowsError(try SEMEDSFile.checkedCount(dims: [-1, 4], bytesPerItem: 1, fileLength: 100, name: "d.spd"))
        XCTAssertEqual(try SEMEDSFile.checkedCount(dims: [7, 0], bytesPerItem: 4, fileLength: 0, name: "e.spd"), 0)
    }

    /// The committed EDAX maps hold exactly the counts their headers state: each passes with its nx · ny · nz.
    func testTheCommittedEDAXHeadersPass() throws {
        for path in ["edax/spd_map_crop8.spd", "edax/spc0_61-ipr333_xrf_crop8.spd", "edax/line_scan_crop.lsd"] {
            let url = SEMParityReference.fixturesRoot.appendingPathComponent("rsciio/" + path)
            let head = SEMEDSBytes([UInt8](try Data(contentsOf: url)), name: url.lastPathComponent)
            let nx = Int(try head.i32(24)), ny = Int(try head.u32(28)), nz = Int(try head.u32(32))
            let countBytes = Int(try head.u32(36)), dataOffset = Int(try head.u32(40))
            XCTAssertEqual(try SEMEDSFile.checkedCount(dims: [ny, nx, nz], bytesPerItem: countBytes,
                                                       fileLength: head.bytes.count - dataOffset, name: url.lastPathComponent),
                           nx * ny * nz, path)
        }
    }

    /// The builder refuses a pixel count that overflows, or passes 2^28, before it reserves its row offsets; before, ny · nx
    /// trapped. A small map still builds.
    func testTheSpectrumImageBuilderRefusesAnImpossibleSize() throws {
        XCTAssertThrowsError(try CSRSpectrumImageBuilder(ny: Int.max / 2, nx: Int.max / 2, channels: 16))
        XCTAssertThrowsError(try CSRSpectrumImageBuilder(ny: 2, nx: SEMEDSFile.largestArray, channels: 16))
        var builder = try CSRSpectrumImageBuilder(ny: 2, nx: 2, channels: 4)
        builder.append(channels: [UInt16(1)], counts: [UInt32(3)])
        let cube = builder.finish()
        XCTAssertEqual(cube.rowOffsets, [0, 1, 1, 1, 1])
        XCTAssertEqual(cube.spectrum(pixel: 0), [0, 3, 0, 0])
    }

    /// An EDAX .spd whose header states 2^31 x 2^32 pixels of 2048 channels, in a file of its header alone, is refused before
    /// anything is allocated; before, the builder's reservation of 2^63 row offsets trapped. A map 4 x 4 of 16 two-byte counts
    /// with 100 of its 512 bytes still gets the sentence a short file always got.
    func testAnEDAXHeaderLargerThanItsFileIsRefusedBeforeAllocating() throws {
        let big = try write(Self.spd(nx: 0x7FFF_FFFF, ny: 0xFFFF_FFFF, nz: 2048, countBytes: 1, data: 0), named: "big.spd")
        XCTAssertThrowsError(try EDAXEDSReader.read(url: big)) { error in
            XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("big.spd") ?? false, "\(error)")
        }
        let short = try write(Self.spd(nx: 4, ny: 4, nz: 16, countBytes: 2, data: 100), named: "short.spd")
        XCTAssertThrowsError(try EDAXEDSReader.read(url: short)) { error in
            XCTAssertEqual((error as? SEMEDSReadError)?.text,
                           "short.spd holds fewer spectra than its header states (4 x 4 of 16 channels).")
        }
    }

    /// A Bruker header's size reads as the whole number Int(_:) would give, and as no size when it is no number or past Int
    /// (a damaged "1e400", which Int(_:) trapped on).
    func testABrukerHeaderSizePastIntIsNoSize() {
        XCTAssertEqual(BrukerEDSReader.whole("512"), 512)
        XCTAssertEqual(BrukerEDSReader.whole(" 75.9 "), 75)
        XCTAssertNil(BrukerEDSReader.whole("1e400"))
        XCTAssertNil(BrukerEDSReader.whole("1e19"))
        XCTAssertNil(BrukerEDSReader.whole("wide"))
        XCTAssertNil(BrukerEDSReader.whole(nil))
    }

    /// EMsoft's npx gives the pattern side 2 npx + 1; an npx that is not a number, infinite, or whose side's square overflows is
    /// refused before anything is sized from it (before, Int(_:) or the square trapped).
    func testAMasterPatternNpxThatCannotBeASideIsRefused() throws {
        XCTAssertEqual(try EMsoftMasterPatternReader.patternSide(npx: 500, path: "npx"), 1001)
        for npx in [Double.nan, Double.infinity, 2_147_483_648, 1e30] {
            XCTAssertThrowsError(try EMsoftMasterPatternReader.patternSide(npx: npx, path: "npx"), "\(npx)") { error in
                XCTAssertNotNil(error as? EBSDReadError, "\(error)")
            }
        }
    }
}
