//
//  OrientationMapDoorTests.swift
//  The Maps room's file door (`OrientationMapSession.read`) says why it does not read a file, in one sentence that names the file
//  (#292): an `.ang` on a hexagonal grid, a `.ctf` its reader refuses (the reader's reason after the name), and a file that is
//  neither. Each file is written here. The hexagonal `.ang` differs from a square one that reads in its `GRID:` line alone, so
//  the refusal is the grid's.
//  Red under: a changed sentence, the hexagonal check dropped (the map would open as if its rows were not shifted), the `.ctf`
//  reader's refusal passed on without the file's name.
//

import XCTest
import TEMCore
import TEMSession

nonisolated final class OrientationMapDoorTests: XCTestCase {

    /// A fresh temporary folder, removed after the test.
    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maps-door-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func write(_ text: String, as name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// An EDAX TSL `.ang` on `grid`: one nickel phase, four columns by three rows at 2 µm, ten columns per point, the point in row 1,
    /// column 1 not indexed (confidence index -1).
    private static func tslANG(grid: String) -> String {
        var lines = [
            "# TEM_PIXperUM          1.000000",
            "# x-star                 0.512345",
            "# y-star                 0.678901",
            "# z-star                 0.654321",
            "# WorkingDistance        15.000000",
            "#",
            "# Phase 1",
            "# MaterialName  \tNickel",
            "# Formula     \tNi",
            "# Info \t\t",
            "# Symmetry              43",
            "# LatticeConstants      3.524 3.524 3.524  90.000  90.000  90.000",
            "#",
            "# GRID: \(grid)",
            "# XSTEP: 2.000000",
            "# YSTEP: 2.000000",
            "# NCOLS_ODD: 4",
            "# NCOLS_EVEN: 4",
            "# NROWS: 3",
            "#"
        ]
        for row in 0..<3 {
            for column in 0..<4 {
                let confidence = row == 1 && column == 1 ? "-1.000" : "0.500"
                lines.append("  0.10000  0.25000  5.70000  \(column * 2).00000  \(row * 2).00000  100.0  \(confidence)  1  1000  0.500")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The sentence the door refuses `url` with; a failure when the file reads, or when the error is not the door's own.
    private func refusal(of url: URL, file: StaticString = #filePath, line: UInt = #line) async -> String? {
        do {
            let document = try await OrientationMapSession.read(url)
            XCTFail("\(url.lastPathComponent) was read as \(document.format)", file: file, line: line)
            return nil
        } catch let error as MapReadError {
            return error.text
        } catch {
            XCTFail("\(url.lastPathComponent): \(error) is not the door's refusal", file: file, line: line)
            return nil
        }
    }

    /// The same file on a square grid reads, on a hexagonal grid it is refused with the grid's name as the file writes it; the
    /// extension's case does not matter.
    func testAHexagonalANGIsRefusedAndTheSameFileOnASquareGridReads() async throws {
        let folder = try scratchFolder()
        let square = try write(Self.tslANG(grid: "SqrGrid"), as: "square.ang", in: folder)
        let document = try await OrientationMapSession.read(square)
        XCTAssertEqual(document.fileName, "square.ang")
        XCTAssertEqual(document.format, ".ang (EDAX TSL)")
        XCTAssertEqual([document.rows, document.columns], [3, 4])
        XCTAssertEqual(document.size, 12)
        XCTAssertEqual(document.notIndexedCount, 1)

        let hexagonal = try write(Self.tslANG(grid: "HexGrid"), as: "hexagonal.ang", in: folder)
        let sentence = await refusal(of: hexagonal)
        XCTAssertEqual(sentence, "hexagonal.ang is a hexagonal grid (HexGrid); only square-grid EBSD maps are read.")

        let shouting = try write(Self.tslANG(grid: "HEXGRID"), as: "SCAN.ANG", in: folder)
        let shouted = await refusal(of: shouting)
        XCTAssertEqual(shouted, "SCAN.ANG is a hexagonal grid (HEXGRID); only square-grid EBSD maps are read.")
    }

    /// A `.ctf` the reader refuses is refused by name with the reader's reason: one line that is no column line, and a column line
    /// under a header without its `Phases` line.
    func testACTFTheReaderRefusesIsRefusedByNameWithItsReason() async throws {
        let folder = try scratchFolder()
        let garbage = try write("this is not a channel text file\n", as: "garbage.ctf", in: folder)
        let noColumns = await refusal(of: garbage)
        XCTAssertEqual(noColumns,
                       "garbage.ctf: it has no `Phase X Y ...` column line in its first 1000 lines and no column names on its first line.")
        XCTAssertEqual(noColumns, "garbage.ctf: " + CTFReader.Refusal.noColumnLine.reason)

        let columnLine = ["Phase", "X", "Y", "Bands", "Error", "Euler1", "Euler2", "Euler3", "MAD", "BC", "BS"].joined(separator: "\t")
        let point = ["1", "0", "0", "8", "0", "10", "20", "30", "0.5", "100", "200"].joined(separator: "\t")
        let headless = try write(["Channel Text File", columnLine, point].joined(separator: "\n") + "\n", as: "no-phases.ctf", in: folder)
        let noPhases = await refusal(of: headless)
        XCTAssertEqual(noPhases, "no-phases.ctf: its header has no `Phases` line with a count of phases.")
    }

    /// Any other extension, or none, is not an orientation map: the sentence names the file and the four that are.
    func testAFileThatIsNeitherANGNorCTFIsRefusedByName() async throws {
        let folder = try scratchFolder()
        let text = try write("x\n", as: "x.txt", in: folder)
        let textRefusal = await refusal(of: text)
        XCTAssertEqual(textRefusal, "x.txt is not an orientation map (.ang, .ctf, .h5oina or orix's .h5).")
        let bare = try write(Self.tslANG(grid: "SqrGrid"), as: "scan", in: folder)
        let bareRefusal = await refusal(of: bare)
        XCTAssertEqual(bareRefusal, "scan is not an orientation map (.ang, .ctf, .h5oina or orix's .h5).")
    }
}
