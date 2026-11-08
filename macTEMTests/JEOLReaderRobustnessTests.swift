//
//  JEOLReaderRobustnessTests.swift
//  Damaged JEOL files are refused in words, never trapped on and never followed round a loop: an OLE date that is not a
//  number, infinite or past Int64's microseconds; an image whose Size is under a pixel or infinite; a project (.asw) that
//  names itself; a project member that climbs out of the project's folder. The files are written here with a small writer of
//  JEOL's tagged header tree (`_parsejeol`'s layout). The committed seq project still reads its image and spectra.
//  Mutations each test must go red under: oleDate back to Int64(_:) (a trap); the Size guard dropped (an image 0 pixels wide,
//  which CalibratedImage traps on, or a trap on Int(inf)); readASW without its visited set (a stack overflow); the member
//  join without its ".." refusal (the file outside the folder is read).
//

import Foundation
import TEMCore
import XCTest

nonisolated final class JEOLReaderRobustnessTests: XCTestCase {

    /// One node of a JEOL header tree.
    private nonisolated enum Tag {
        case group(String, [Tag])
        case text(String, String)
        case doubles(String, [Double])
        case float(String, Float)
        case int(String, Int32)
        case bytes(String, [UInt8])
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    /// A node as `_parsejeol` reads it: mark 1, the key's length and NUL-terminated bytes, the value's type code and byte
    /// length, the value (none for a group, whose children follow), then mark -1.
    private static func encode(_ tag: Tag) -> [UInt8] {
        let field: (key: String, type: Int32, value: [UInt8])
        switch tag {
        case .group(let k, _): field = (k, 0, [])
        case .text(let k, let s): field = (k, 12, Array(s.utf8) + [0])
        case .doubles(let k, let vs): field = (k, 5, vs.flatMap { le($0.bitPattern) })
        case .float(let k, let v): field = (k, 4, le(v.bitPattern))
        case .int(let k, let v): field = (k, 3, le(v))
        case .bytes(let k, let bs): field = (k, 6, bs)
        }
        let name = Array(field.key.utf8) + [0]
        var out: [UInt8] = [1]
        out += le(Int32(name.count))
        out += name
        out += le(field.type)
        out += le(Int32(field.value.count))
        out += field.value
        if case .group(_, let kids) = tag {
            for kid in kids { out += encode(kid) }
        }
        out.append(0xFF)
        return out
    }

    /// A project file: word 0, then from byte 12 a tree naming `members` under SampleInfo/0/ViewInfo/0/ViewData.
    private static func project(_ members: [String]) -> [UInt8] {
        let views = members.enumerated().map { Tag.group(String($0.offset), [.text("Filename", $0.element)]) }
        let view = Tag.group("0", [.group("ViewData", views)])
        let sample = Tag.group("0", [.group("ViewInfo", [view])])
        let tree = Tag.group("SampleInfo", [sample])
        var out = [UInt8](repeating: 0, count: 12)
        out += encode(tree)
        out.append(0xFF)
        return out
    }

    /// An image file: word 52, the tree's position (48) at byte 44, and from byte 60 the fields readIMG reads, Size as doubles.
    private static func image(size: [Double], bits: [UInt8]) -> [UInt8] {
        let picture = Tag.group("Image", [.doubles("Size", size), .bytes("Bits", bits), .doubles("Created", [44000.5]), .text("Title", "BF")])
        let instrument = Tag.group("Instrument", [.float("ScanSize", 198), .int("Mag", 1000), .float("AccV", 200)])
        var out = [UInt8](repeating: 0, count: 60)
        out[0] = 52
        out[44] = 48
        out += encode(picture)
        out += encode(instrument)
        out.append(0xFF)
        return out
    }

    /// A fresh temporary folder, removed after the test.
    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mactem-jeol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// An OLE date that is not a number, infinite, or more microseconds than Int64 holds is refused naming the file; a real
    /// one reads as Python's datetime gives it. Before, Int64(_:) trapped on each of the four.
    func testADamagedOLEDateIsRefused() throws {
        for days in [Double.nan, Double.infinity, -Double.infinity, 1e9] {
            XCTAssertThrowsError(try SEMEDSText.oleDate(days, file: "met03.EDS"), "\(days)") { error in
                XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("met03.EDS") ?? false, "\(error)")
            }
        }
        let when = try SEMEDSText.oleDate(44489.81627314815, file: "x.img")
        XCTAssertEqual(when.date, "2021-10-20")
        XCTAssertEqual(when.time, "19:35:26")
    }

    /// An image whose Size is half a pixel, or infinite, is refused; before, the first read as an image 0 pixels wide (which
    /// CalibratedImage traps on when the Image room opens it) and the second trapped on Int(inf). A 2 x 2 image still reads.
    func testAnImageOfADamagedSizeIsRefused() throws {
        let folder = try scratchFolder()
        for (label, size) in [("half", [0.5, 0.5]), ("infinite", [Double.infinity, 4])] {
            let url = folder.appendingPathComponent("\(label).img")
            try Data(Self.image(size: size, bits: [7, 7, 7, 7])).write(to: url)
            XCTAssertThrowsError(try JEOLEDSReader.read(url: url), label) { error in
                XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("\(label).img") ?? false, "\(error)")
            }
        }
        let good = folder.appendingPathComponent("good.img")
        try Data(Self.image(size: [2, 2], bits: [1, 2, 3, 4])).write(to: good)
        let file = try JEOLEDSReader.read(url: good)
        let image = try XCTUnwrap(file.images.first)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.pixels, [1, 2, 3, 4])
        XCTAssertEqual(image.metadata.date, "2020-06-18")
    }

    /// A project that names itself is refused when it comes round again; before, readASW called itself until the stack
    /// overflowed.
    func testAProjectThatNamesItselfIsRefused() throws {
        let url = try scratchFolder().appendingPathComponent("self.asw")
        try Data(Self.project(["self.asw"])).write(to: url)
        XCTAssertThrowsError(try JEOLEDSReader.read(url: url)) { error in
            XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("self.asw") ?? false, "\(error)")
        }
    }

    /// A project member is joined below the project's folder, `.` parts dropped; one that climbs out (`..`) or names a drive is
    /// refused. Through the reader: a project naming `..\outside.img` is refused, where before it read the image beside its
    /// folder; one naming `.\View\inside.img` reads it.
    func testAProjectMemberStaysInsideItsFolder() throws {
        let root = URL(fileURLWithPath: "/a", isDirectory: true)
        XCTAssertEqual(try JEOLEDSReader.projectMember(folder: root, filename: "c.pts").path, "/a/c.pts")
        XCTAssertEqual(try JEOLEDSReader.projectMember(folder: root, filename: ".\\Sample\\00_View002\\v.img").path,
                       "/a/Sample/00_View002/v.img")
        for climbing in ["../b.pts", "..\\b.pts", "Sample\\..\\..\\b.pts", "C:\\data\\b.pts"] {
            XCTAssertThrowsError(try JEOLEDSReader.projectMember(folder: root, filename: climbing), climbing)
        }

        let folder = try scratchFolder()
        let inner = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: inner.appendingPathComponent("View", isDirectory: true), withIntermediateDirectories: true)
        try Data(Self.image(size: [2, 2], bits: [1, 2, 3, 4])).write(to: folder.appendingPathComponent("outside.img"))
        try Data(Self.image(size: [2, 2], bits: [5, 6, 7, 8])).write(to: inner.appendingPathComponent("View/inside.img"))
        let climb = inner.appendingPathComponent("climb.asw")
        try Data(Self.project(["..\\outside.img"])).write(to: climb)
        XCTAssertThrowsError(try JEOLEDSReader.read(url: climb)) { error in
            XCTAssertTrue((error as? SEMEDSReadError)?.text.contains("outside.img") ?? false, "\(error)")
        }
        let stay = inner.appendingPathComponent("stay.asw")
        try Data(Self.project([".\\View\\inside.img"])).write(to: stay)
        XCTAssertEqual(try JEOLEDSReader.read(url: stay).images.map(\.pixels), [[5, 6, 7, 8]])
    }

    /// The committed seq project (`.\Sample\00_View002\...`) still reads its image and its two spectra.
    func testTheCommittedSeqProjectStillReads() throws {
        let url = SEMParityReference.fixturesRoot.appendingPathComponent("rsciio/jeol/seq/1.ASW")
        let file = try JEOLEDSReader.read(url: url)
        XCTAssertEqual(file.images.count, 1)
        XCTAssertEqual(file.spectra.count, 2)
        XCTAssertEqual(file.images.first?.width, 512)
    }
}
