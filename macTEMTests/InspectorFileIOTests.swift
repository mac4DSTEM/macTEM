//
//  InspectorFileIOTests.swift
//  The file reads and writes of the Particles section and the Diffraction inspector live in the app layer, not in the views (#282):
//  the CSV written into `--export-dir` keeps its name and its bytes, a CIF is read into the kit's crystal, the two view files touch
//  no file, and the Particles section builds its CSV when Export CSV… is pressed, not in its body.
//  Red before the change: no `ExportDirectoryFile`, no `DiffractionReadoutExport`; the views called `FileManager`, `Data(contentsOf:)`
//  and `write(to:)`, and the section's `fileExporter` built the whole CSV on every body evaluation.
//

import XCTest
import DiffractoCore
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
