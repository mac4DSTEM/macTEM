//
//  MetadataParityHarnessNotesTests.swift
//  The metadata-parity harness (tools/parity/metadata-parity) compares every reader note exactly, so its two Python scripts
//  must carry the notes FormatoKit's readers attach under `convention: .app`, word for word: make_fixture.py writes them into
//  the planted truth and reference.py into the expectations. These read both scripts through the repository root and require
//  each format's note as the constant both scripts name, with the literal texts the reader tests pin
//  (AcquisitionMetadataDMTests, AcquisitionMetadataTIFFTests, AcquisitionMetadataMRCTests), and none of the wording
//  FormatoKit 0.12.1 replaced.
//  Red before the harness followed FormatoKit 0.12.1: both scripts held "unvalidated: no published reader reads it" for every
//  format and "unvalidated: the mode is not checked" for an MRC camera length.
//

import Foundation
import XCTest

nonisolated final class MetadataParityHarnessNotesTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The harness's two scripts: the planted truth and the reference's expectations.
    private static let scripts = ["tools/parity/metadata-parity/make_fixture.py", "tools/parity/metadata-parity/reference.py"]

    /// Each note both scripts define: the constant's name and the text FormatoKit 0.12.1's reader attaches.
    private static let notes: [(constant: String, text: String)] = [
        // AcquisitionMetadataDMTests: a DM image object, and a TIFF's tag 65027 stream, which the DM rules read.
        ("UNVAL_DM", "no published reader reads this field; read as stored in the DM image tags"),
        // AcquisitionMetadataTIFFTests: the Velox XML and the FEI SEM INI of a TIFF.
        ("UNVAL_VELOX", "no published reader reads this field; read as stored in the Velox XML of the TIFF"),
        ("UNVAL_FEI", "no published reader reads this field; read as stored in the FEI header of the TIFF"),
        // AcquisitionMetadataMRCTests: the mode and the exposure, and the camera length, of an MRC FEI extended header.
        ("UNVAL_MRC", "no published reader reads this field; read as stored in the FEI extended header, at the offset mrcfile declares"),
        ("NOMODE", "shown as stored; the instrument mode is not checked, as no published reader decodes it"),
    ]

    /// The wording of the same notes before FormatoKit 0.12.1.
    private static let replaced = ["unvalidated: no published reader reads it", "unvalidated: the mode is not checked"]

    /// The script at `path` (relative to the repository root) as it is on disk.
    private func script(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Each script defines every note on a line of its own, as FormatoKit 0.12.1 words it, so the planted truth and the
    /// expectations carry it word for word.
    func testBothScriptsDefineEachNoteAsFormatoKitWordsIt() throws {
        for path in Self.scripts {
            let text = try script(path)
            for note in Self.notes {
                XCTAssertTrue(text.contains("\n\(note.constant) = \"\(note.text)\"\n"),
                              "\(path) has no line \(note.constant) = \"\(note.text)\"")
            }
        }
    }

    /// Neither script still expects the wording FormatoKit 0.12.1 replaced.
    func testNeitherScriptHoldsTheReplacedWording() throws {
        for path in Self.scripts {
            let text = try script(path)
            for old in Self.replaced {
                XCTAssertFalse(text.contains(old), "\(path) still holds \"\(old)\"")
            }
        }
    }
}
