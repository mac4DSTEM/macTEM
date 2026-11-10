//
//  NORDIFOpeningTests.swift
//  A NORDIF acquisition at the Patterns room's door (NORDIFOpening through EBSDOpening and FileRouting): `Pattern.dat` opens as an
//  `EBSDDataset` whose patterns are read from the file by map position and equal NORDIFScan's bit for bit (the scan's parity against
//  kikuchipy 0.13.1 is NORDIFReaderTests); a `.dat` counts only with a NORDIF `Setting.txt` beside it; a short pattern file reads its
//  whole records and the rest as 0, with a note; a `Setting.txt` that is there and may not be read is named in the refusal.
//

import XCTest
import Darwin
import FormatoCore
import TEMCore

nonisolated final class NORDIFOpeningTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sem/nordif")
    private func url(_ name: String) -> URL { Self.folder.appendingPathComponent(name) }
    private var scratch: [URL] = []

    override func tearDown() {
        for folder in scratch { try? FileManager.default.removeItem(at: folder) }
        scratch = []
        super.tearDown()
    }

    /// A fresh folder holding the given pattern bytes as `Pattern.dat` and, when `settings` names one, that fixture as `Setting.txt`.
    private func folder(patternBytes: Data, settings: String? = "Setting.txt") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nordif-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scratch.append(folder)
        if let settings { try FileManager.default.copyItem(at: url(settings), to: folder.appendingPathComponent("Setting.txt")) }
        try patternBytes.write(to: folder.appendingPathComponent("Pattern.dat"))
        return folder
    }

    func testPatternDatOpensAsADatasetWithTheSettingsGridDetectorAndHeader() throws {
        let (dataset, _) = try EBSDOpening.open(url: url("Pattern.dat"))
        XCTAssertEqual(dataset.format, .nordif)
        XCTAssertEqual(dataset.manufacturer, "NORDIF")
        XCTAssertEqual(dataset.version, "3.1.2")
        XCTAssertEqual([dataset.scanRows, dataset.scanColumns, dataset.patternRows, dataset.patternColumns], [3, 3, 60, 60])
        XCTAssertEqual(dataset.dataType, .uint8)
        XCTAssertEqual([dataset.stepY, dataset.stepX], [1.5, 1.5])
        XCTAssertEqual(dataset.scanUnit, "um")
        XCTAssertEqual(dataset.detector.sampleTilt, 70)
        XCTAssertEqual(dataset.detector.tilt, 0)
        XCTAssertEqual(dataset.detector.projectionCenters, [SIMD3(0.5, 0.5, 0.5)])
        XCTAssertEqual(dataset.sem, EBSDSEMHeader(beamEnergyKeV: 20, magnification: 200, workingDistanceMM: 24.7, microscope: "Hitachi SU-6600"))
        XCTAssertEqual(dataset.notes, [])
        let background = try XCTUnwrap(dataset.staticBackground)
        XCTAssertEqual(background.shape, [60, 60])
        XCTAssertEqual(background.bytes, Data(try NORDIFBitmap.read(path: url("Background acquisition pattern.bmp").path).pixels))
    }

    func testThePatternsReadFromTheFileEqualTheScanBitForBit() throws {
        let scan = try NORDIFScan.read(patternFile: url("Pattern.dat").path)
        let (dataset, reader) = try EBSDOpening.open(url: url("Pattern.dat"))
        for row in 0..<3 {
            for column in 0..<3 {
                XCTAssertEqual(try reader.pattern(row: row, column: column).bytes, Data(scan.pattern(row: row, column: column)), "(\(row), \(column))")
            }
            let start = row * 3 * 3600
            XCTAssertEqual(try reader.row(row).bytes, Data(scan.patterns[start..<(start + 3 * 3600)]), "row \(row)")
        }
        XCTAssertEqual(try dataset.allPatterns().bytes, Data(scan.patterns))
    }

    func testAShortPatternFileReadsItsWholeRecordsAndTheRestAsZero() throws {
        let whole = try Data(contentsOf: url("Pattern.dat"))
        let folder = try folder(patternBytes: whole.prefix(whole.count - 3600 - 100))
        let (dataset, reader) = try EBSDOpening.open(url: folder.appendingPathComponent("Pattern.dat"))
        XCTAssertEqual(dataset.notes, ["Pattern.dat holds 7 of the 3 x 3 patterns of 60 x 60 px the settings give; the missing ones read 0."])
        XCTAssertEqual(try reader.pattern(row: 2, column: 0).bytes, whole[(6 * 3600)..<(7 * 3600)])
        XCTAssertEqual(try reader.pattern(row: 2, column: 1).bytes, Data(count: 3600), "the incomplete record reads 0")
        XCTAssertEqual(try reader.pattern(row: 2, column: 2).bytes, Data(count: 3600))
    }

    func testTheRoutingSendsPatternDatToThePatternsRoomOnlyWithItsSettings() throws {
        XCTAssertTrue(EBSDOpening.isVendorFile(url("Pattern.dat")))
        XCTAssertEqual(FileRouting.inventory(path: url("Pattern.dat").path), FileInventory(ebsdPatterns: true))
        XCTAssertEqual(FileRouting.inventory(path: url("Pattern.dat").path).landing, .patterns)
        let lone = try folder(patternBytes: Data([1, 2, 3]), settings: nil)
        let other = lone.appendingPathComponent("Pattern.dat")
        XCTAssertFalse(NORDIFOpening.isNORDIFFile(other), "no Setting.txt beside it")
        XCTAssertFalse(EBSDOpening.isVendorFile(other))
        let routed = FileRouting.inventory(path: other.path)
        XCTAssertFalse(routed.ebsdPatterns)
        XCTAssertNotNil(routed.refusal, "an unknown .dat keeps the general refusal")
        XCTAssertTrue(FileRouting.openableExtensions.contains("dat"))
    }

    func testABrokenSettingsFileIsRefusedAtTheDoorWithItsSentence() throws {
        let whole = try Data(contentsOf: url("Pattern.dat"))
        let folder = try folder(patternBytes: whole)
        let settings = folder.appendingPathComponent("Setting.txt")
        let lines = try String(contentsOf: settings, encoding: .isoLatin1).components(separatedBy: "\r\n").filter { !$0.hasPrefix("Number of samples") }
        try lines.joined(separator: "\r\n").data(using: .isoLatin1)!.write(to: settings)
        let pattern = folder.appendingPathComponent("Pattern.dat")
        let sentence = "Setting.txt cannot be read: its [Area] section has no 'Number of samples' line."
        XCTAssertEqual(FileRouting.inventory(path: pattern.path), FileInventory(refusal: sentence))
        XCTAssertThrowsError(try EBSDOpening.open(url: pattern)) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text, sentence)
        }
    }

    /// A `Setting.txt` that is there and may not be read (the sandbox's case: a signed build is granted the picked `Pattern.dat`, not
    /// its folder) is named in the refusal, with the folder; file mode 000 stands in for the sandbox. A `.dat` with no settings file,
    /// or with one that opens, gets no such sentence. Red before: the general "is not a format macTEM opens".
    func testASettingsFileThatMayNotBeReadIsNamedInTheRefusal() throws {
        XCTAssertNotEqual(geteuid(), 0, "root reads a mode-000 file; run this as a user")
        let folder = try folder(patternBytes: try Data(contentsOf: url("Pattern.dat")))
        let settings = folder.appendingPathComponent("Setting.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }
        let pattern = folder.appendingPathComponent("Pattern.dat")
        XCTAssertFalse(NORDIFOpening.isNORDIFFile(pattern), "a settings file that cannot be opened cannot be recognised")
        let sentence = "Setting.txt beside Pattern.dat cannot be read: macOS does not let macTEM open it (Permission denied); "
            + "a NORDIF scan needs the acquisition's folder, not Pattern.dat alone."
        XCTAssertEqual(NORDIFOpening.unreadableSettingsRefusal(pattern), sentence)
        XCTAssertEqual(FileRouting.inventory(path: pattern.path), FileInventory(refusal: sentence))
        let lone = try self.folder(patternBytes: Data([1, 2, 3]), settings: nil)
        XCTAssertNil(NORDIFOpening.unreadableSettingsRefusal(lone.appendingPathComponent("Pattern.dat")), "no Setting.txt beside it")
        XCTAssertNil(NORDIFOpening.unreadableSettingsRefusal(url("Pattern.dat")), "its Setting.txt opens")
        XCTAssertNil(NORDIFOpening.unreadableSettingsRefusal(settings), "not a .dat")
    }

    /// The probe an Open decides by (the app's `FolderGrants.asksForFolder`): 0 for a settings file that opens, ENOENT for none
    /// beside the `.dat`, the file mode's EACCES, nil for a file that is not a `.dat`; the sandbox's refusal is EPERM, which only a
    /// signed build shows. Red under: the probe answering anything but the open's errno (a file mode would read as the sandbox's).
    func testTheSettingsProbeTellsAReadableAMissingAndALockedSettingsFileApart() throws {
        XCTAssertNotEqual(geteuid(), 0, "root reads a mode-000 file; run this as a user")
        XCTAssertEqual(NORDIFOpening.settingsOpenError(url("Pattern.dat")), 0)
        XCTAssertNil(NORDIFOpening.settingsOpenError(url("Setting.txt")), "not a .dat")
        let lone = try folder(patternBytes: Data([1, 2, 3]), settings: nil)
        XCTAssertEqual(NORDIFOpening.settingsOpenError(lone.appendingPathComponent("Pattern.dat")), ENOENT)
        let locked = try folder(patternBytes: Data([1, 2, 3]))
        let settings = locked.appendingPathComponent("Setting.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }
        XCTAssertEqual(NORDIFOpening.settingsOpenError(locked.appendingPathComponent("Pattern.dat")), EACCES)
    }
}
