//
//  InspectorFileIOTests.swift
//  The file reads and writes of the Particles section and the Diffraction inspector live in the app layer, not in the views (#282):
//  the CSV written into `--export-dir` keeps its name and its bytes, a CIF is read into the kit's crystal, the two view files touch
//  no file, and the Particles section builds its CSV when Export CSV… is pressed, not in its body. The export-folder write goes
//  through `ExportFile.write`, as the File menu's exports do (#269): any bytes as given, and a folder where the file goes refused
//  in that writer's words and kept.
//  Red before the change: no `ExportDirectoryFile`, no `DiffractionReadoutExport`; the views called `FileManager`, `Data(contentsOf:)`
//  and `write(to:)`, and the section's `fileExporter` built the whole CSV on every body evaluation. Red before the
//  `ExportFile.write` change: the export folder took only text, and a folder where the file goes was the system's own sentence,
//  not `ExportFile`'s refusal.
//

import XCTest
import DiffractoCore
import TEMCore
@testable import macTEM

nonisolated final class InspectorFileIOTests: XCTestCase {

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inspector-file-io-\(UUID().uuidString)", isDirectory: true)
    }

    /// A CSV goes into the export folder under the image's name, the folder made on the way, the bytes the text's UTF-8 and nothing more.
    /// Red under: another name than the journeys wait for, a byte order mark or a changed line ending, a missing folder refused.
    func testACSVIsWrittenIntoTheExportFolderByteForByte() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "# unit: \u{00B5}m, \u{00C5}\r\nlabel,counted\n1,1\n"
        let particles = try ParticleExport.write(text, imageFileName: "Camera Ceta 1305.tif", into: dir.appendingPathComponent("a"))
        XCTAssertEqual(particles.lastPathComponent, "Camera Ceta 1305 particles.csv")
        XCTAssertEqual(try Data(contentsOf: particles), Data(text.utf8))
        let readout = try DiffractionReadoutExport.write(text, imageFileName: "Au rings.dm4", into: dir.appendingPathComponent("b"))
        XCTAssertEqual(readout.lastPathComponent, "Au rings diffraction.csv")
        XCTAssertEqual(try Data(contentsOf: readout), Data(text.utf8))
        let plain = try ExportDirectoryFile.write("x", named: "note.txt", into: dir)
        XCTAssertEqual(plain.lastPathComponent, "note.txt")
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "x")
    }

    /// Bytes go into the export folder exactly as given, under the given name, the folder made on the way, bytes that are not UTF-8
    /// too (a PNG's signature); a second write replaces the file whole and leaves nothing beside it. Red under: no way to write bytes,
    /// the bytes read as text, a longer old file not cut to the new bytes.
    func testBytesAreWrittenIntoTheExportFolderAsGiven() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("made")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xFE])
        let url = try ExportDirectoryFile.write(bytes, named: "dual maps.png", into: folder)
        XCTAssertEqual(url.lastPathComponent, "dual maps.png")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "made")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let shorter = Data([0x01, 0x02])
        XCTAssertEqual(try ExportDirectoryFile.write(shorter, named: "dual maps.png", into: folder), url)
        XCTAssertEqual(try Data(contentsOf: url), shorter)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["dual maps.png"], "nothing beside the file")
    }

    /// A folder where the CSV goes is refused in `ExportFile`'s own words, the sentence naming it, and left as it was with what it
    /// held. Red under: the bytes written past `ExportFile.write` (the system's own sentence, not the refusal by name).
    func testAFolderWhereTheCSVGoesIsRefusedAndKept() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Au rings diffraction.csv", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        XCTAssertThrowsError(try DiffractionReadoutExport.write("a,b\n", imageFileName: "Au rings.dm4", into: dir)) { error in
            XCTAssertEqual(error as? ExportFile.Failure, .writeFailed("\u{201C}Au rings diffraction.csv\u{201D} is a folder."))
            XCTAssertEqual(error.localizedDescription, "The file could not be written. \u{201C}Au rings diffraction.csv\u{201D} is a folder.")
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("inside.txt"), encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Au rings diffraction.csv"],
                       "nothing was left beside the folder")
    }

    /// The names the save panels offer are the written files' names without the extension.
    func testTheOfferedNamesAreTheWrittenOnes() {
        XCTAssertEqual(ParticleExport.baseName(of: "Camera Ceta 1305.tif"), "Camera Ceta 1305 particles")
        XCTAssertEqual(DiffractionReadoutExport.baseName(of: "Au rings.dm4"), "Au rings diffraction")
        XCTAssertEqual(DiffractionReadoutExport.baseName(of: "no extension"), "no extension diffraction")
    }

    /// A CIF on disk becomes the crystal the kit reads from the same bytes under the same file name; bytes that are not UTF-8 are
    /// the kit's refusal. Red under: the file's bytes not the ones handed over, another name than the file's as the fallback name.
    func testACIFIsReadIntoTheKitsCrystal() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data(BetaDoublePrimeCIF.text.utf8)
        let file = dir.appendingPathComponent("beta.cif")
        try bytes.write(to: file)
        let loaded = try await DiffractionCIF.load(file)
        let expected = try CrystalLoading.load(bytes: bytes, fileName: "beta.cif")
        XCTAssertEqual(loaded.sha256, expected.sha256)
        XCTAssertEqual(loaded.byteCount, bytes.count)
        XCTAssertEqual(loaded.displayName, expected.displayName)

        let broken = dir.appendingPathComponent("broken.cif")
        try Data([0xFF, 0xFE, 0x00]).write(to: broken)
        do {
            _ = try await DiffractionCIF.load(broken)
            XCTFail("bytes that are not UTF-8 were read as a CIF")
        } catch {
            XCTAssertEqual(error as? CrystalLoading.Refusal, .notUTF8)
        }
    }

    /// The two view files touch no file: what they read and write goes through the app layer.
    /// Red under: a writer or a reader back in a view file.
    func testTheTwoInspectorsTouchNoFile() throws {
        for name in ["ImageRoomParticles.swift", "DiffractionRoomInspector.swift"] {
            let text = try FFTRoomWiringTests.squeezedUI(name)
            for call in ["FileManager.default", "Data(contentsOf:", ".write(to:", "startAccessingSecurityScopedResource"] {
                XCTAssertFalse(text.contains(call), "\(name) calls \(call)")
            }
        }
        let inspector = try FFTRoomWiringTests.squeezedUI("DiffractionRoomInspector.swift")
        XCTAssertTrue(inspector.contains("let url = try DiffractionReadoutExport.write(text, imageFileName: image.fileName, into: directory)"))
        XCTAssertTrue(inspector.contains("defaultFilename: DiffractionReadoutExport.baseName(of: image.fileName)) { result in"))
    }

    /// The Particles section makes its CSV document when Export CSV… is pressed and drops it when the panel is done; the body
    /// builds none. Red under: the document built in the `fileExporter` call again (the whole CSV on every body evaluation).
    func testTheParticlesCSVIsBuiltWhenExportIsPressed() throws {
        let section = try FFTRoomWiringTests.squeezedUI("ImageRoomParticles.swift")
        XCTAssertTrue(section.contains("@State private var exportDocument: EDXExportFile?"))
        XCTAssertTrue(section.contains(
            ".fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }), "
                + "document: exportDocument, contentType: .commaSeparatedText, defaultFilename: ParticleExport.baseName(of: image.fileName)) { result in"))
        XCTAssertFalse(section.contains("document: EDXExportFile("), "no document made in the body")
        XCTAssertTrue(section.contains("let text = csv(analysis) guard let directory = appState.exportDirectory else { "
            + "exportDocument = EDXExportFile(data: Data(text.utf8)) return }"))
        XCTAssertEqual(section.components(separatedBy: "csv(analysis)").count - 1, 1, "the CSV is built in one place, the export")
    }
}
