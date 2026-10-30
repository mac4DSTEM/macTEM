import XCTest
import DiffractoCore
import DiffractoScattering
import TEMCore

/// A crystal from the bytes of a CIF (R9): the 5 MiB cap, strict UTF-8, the kit's `CIFImport`, a SHA-256 of the bytes as the
/// fingerprint, and the kit's own error text. The fingerprints are hashlib's (tools/parity/diffraction-room-parity R9 holds the kit's
/// and the planted CIF files, including the BOM, CRLF and decomposed-accent ones). Red under: the fingerprint over re-encoded text,
/// a cap off by one, the kit's error wrapped in a text of the app's own.
nonisolated final class CrystalLoadingTests: XCTestCase {

    private static let goldLines = [
        "data_gold", "_cell_length_a 4.0782", "_cell_length_b 4.0782", "_cell_length_c 4.0782",
        "_cell_angle_alpha 90.0", "_cell_angle_beta 90.0", "_cell_angle_gamma 90.0",
        "loop_", "_atom_site_label", "_atom_site_type_symbol", "_atom_site_fract_x", "_atom_site_fract_y", "_atom_site_fract_z",
        "Au1 Au 0.0 0.0 0.0", "Au2 Au 0.5 0.5 0.0", "Au3 Au 0.5 0.0 0.5", "Au4 Au 0.0 0.5 0.5",
    ]
    private static let gold = Data((goldLines.joined(separator: "\n") + "\n").utf8)
    private static let goldSHA256 = "bf108e52f55ce1bbd50ca9c1221a6f93f2b178cd05fe745696348dd298f64d41"
    private static let goldWithBOMSHA256 = "c9a81b01e7381658cbbedbe2bc07b7451ade8c6878fbedb8a05606783ce9ce4d"
    private static let goldCRLFSHA256 = "7a485fa28efc06c25985402f28fd8e9c0ba7b0f8ac3e5592b289c27acbb8892a"

    func testReadsGoldAndTheStructureIsTheKits() throws {
        let loaded = try CrystalLoading.load(bytes: Self.gold, fileName: "gold.cif")
        let kit = try CIFImport.read(String(decoding: Self.gold, as: UTF8.self), fileBaseName: "gold")
        XCTAssertEqual(loaded.structure, kit.structure)
        XCTAssertEqual(loaded.displayName, "gold")
        XCTAssertEqual(loaded.structure.cell.a, 4.0782)
        XCTAssertEqual(loaded.byteCount, 323)
    }

    /// The fingerprint is the SHA-256 of the file's bytes, lower-case hex.
    func testFingerprintIsTheSHA256OfTheBytes() throws {
        XCTAssertEqual(try CrystalLoading.load(bytes: Self.gold, fileName: "gold.cif").sha256, Self.goldSHA256)
        XCTAssertEqual(CrystalLoading.fingerprint(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// A byte-order mark or CRLF line ends change the fingerprint (the bytes), though the text reads the same.
    func testFingerprintFollowsTheBytesNotTheText() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Self.gold
        let crlf = Data((Self.goldLines.joined(separator: "\r\n") + "\r\n").utf8)
        XCTAssertEqual(try CrystalLoading.load(bytes: bom, fileName: "gold.cif").sha256, Self.goldWithBOMSHA256)
        XCTAssertEqual(try CrystalLoading.load(bytes: crlf, fileName: "gold.cif").sha256, Self.goldCRLFSHA256)
        XCTAssertEqual(try CrystalLoading.load(bytes: crlf, fileName: "gold.cif").structure, try CrystalLoading.load(bytes: Self.gold, fileName: "gold.cif").structure)
    }

    /// Exactly 5 MiB is read; one byte more is refused by name, before the kit sees it.
    func testTheCapIsFiveMebibytesInclusive() throws {
        XCTAssertEqual(CrystalLoading.maximumBytes, 5 * 1024 * 1024)
        let padding = Data(repeating: UInt8(ascii: "\n"), count: CrystalLoading.maximumBytes - Self.gold.count)
        let atCap = Self.gold + padding
        XCTAssertEqual(atCap.count, CrystalLoading.maximumBytes)
        XCTAssertEqual(try CrystalLoading.load(bytes: atCap, fileName: "gold.cif").byteCount, CrystalLoading.maximumBytes)
        XCTAssertThrowsError(try CrystalLoading.load(bytes: atCap + Data([0x0A]), fileName: "gold.cif")) { error in
            XCTAssertEqual(error as? CrystalLoading.Refusal, .tooLarge(bytes: CrystalLoading.maximumBytes + 1))
            XCTAssertEqual((error as? CrystalLoading.Refusal)?.name, "tooLarge")
        }
    }

    func testInvalidUTF8IsRefusedByName() {
        let bad = Data("# ".utf8) + Data([0xC3, 0x28]) + Data("\n".utf8) + Self.gold
        XCTAssertThrowsError(try CrystalLoading.load(bytes: bad, fileName: "bad.cif")) { error in
            XCTAssertEqual(error as? CrystalLoading.Refusal, .notUTF8)
        }
    }

    /// The kit's error comes through unchanged: the same value, and `localizedDescription` is the kit's `description`.
    func testTheKitsErrorPropagatesWithItsOwnText() {
        for text in ["", "not a cif", "data_x\n_cell_length_a 4\n"] {
            XCTAssertThrowsError(try CrystalLoading.load(bytes: Data(text.utf8), fileName: "x.cif")) { error in
                let kit = error as? CIFImportError
                XCTAssertNotNil(kit, "\(text.debugDescription)")
                XCTAssertEqual(error.localizedDescription, kit?.description)
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    /// The text of every refusal and every kit error has no application name in it.
    func testNoApplicationNameInAnyErrorText() {
        let texts: [String] = [
            CrystalLoading.Refusal.tooLarge(bytes: 6_000_000).localizedDescription, CrystalLoading.Refusal.notUTF8.localizedDescription,
            CIFImportError.noAtomSites.localizedDescription, CIFImportError.missingTag("_cell_length_a").localizedDescription,
            CIFImportError.invalidStructure(["a"]).localizedDescription,
            KinematicError.unsupportedElements([118]).localizedDescription, KinematicError.invalidCut(-1).localizedDescription,
            ReflectionListError.invalidKMax(0).localizedDescription, ReflectionListError.cellTooLargeOrInvalid(estimatedReflections: 1e12).localizedDescription,
        ]
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("mac4DSTEM"), text)
            XCTAssertFalse(text.contains("ACOM"), text)
        }
        XCTAssertEqual(CIFImportError.noAtomSites.localizedDescription, CIFImportError.noAtomSites.description)
        XCTAssertEqual(KinematicError.invalidCut(-1).localizedDescription, KinematicError.invalidCut(-1).description)
    }
}
