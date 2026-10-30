import XCTest
import DiffractoCore
import DiffractoScattering
import TEMCore

/// macTEM's own CIF plants through DiffractoKit's `CIFImport.read` (ADR 025 "DiffractoKit 0.0.3" and its
/// correction addendum): the literals of the verbatim mac4DSTEM tests that left with the copies (`CIFImportTests`,
/// `CIFSpaceGroupOrderTests`, `CIFSymmetryBijectionTests`), each asserted where its outcome MOVED (old -> new in the test's
/// doc comment) or where HEAD's refusal must be kept. The kit holds the rest (its own CIFImportTests, SymmetryOperationTests,
/// PinsTests, RefuterRegressionTests). A structure whose operators the file lists is read with the Laue class its atoms
/// have; a file that lists none is read as the P1 it is written as.
nonisolated final class CIFThroughTheKitTests: XCTestCase {

    // MARK: Fixtures

    private static func header(_ name: String, _ a: Double, _ b: Double, _ c: Double, _ al: Double, _ be: Double, _ ga: Double) -> String {
        """
        data_\(name)
        _cell_length_a \(a)
        _cell_length_b \(b)
        _cell_length_c \(c)
        _cell_angle_alpha \(al)
        _cell_angle_beta \(be)
        _cell_angle_gamma \(ga)

        """
    }
    private static let atomLoop = """
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z

        """
    private static func ops(_ list: [String]) -> String {
        "loop_\n_symmetry_equiv_pos_as_xyz\n" + list.map { "'\($0)'" }.joined(separator: "\n") + "\n"
    }

    private static let goldP1 = header("gold", 4.0782, 4.0782, 4.0782, 90, 90, 90) + atomLoop
        + "Au1 Au 0.0 0.0 0.0\nAu2 Au 0.5 0.5 0.0\nAu3 Au 0.5 0.0 0.5\nAu4 Au 0.0 0.5 0.5\n"
    private static let goldCentring = header("gold_symm", 4.0782, 4.0782, 4.0782, 90, 90, 90)
        + ops(["x, y, z", "x+1/2, y+1/2, z", "x+1/2, y, z+1/2", "x, y+1/2, z+1/2"]) + atomLoop + "Au1 Au 0 0 0\n"
    private static let silicon = header("silicon", 5.4309, 5.4309, 5.4309, 90, 90, 90) + atomLoop
        + "Si1 Si 0.0 0.0 0.0\nSi2 Si 0.5 0.5 0.0\nSi3 Si 0.5 0.0 0.5\nSi4 Si 0.0 0.5 0.5\n"
        + "Si5 Si 0.25 0.25 0.25\nSi6 Si 0.75 0.75 0.25\nSi7 Si 0.75 0.25 0.75\nSi8 Si 0.25 0.75 0.75\n"
    /// alpha-quartz P3_221 as the mac4DSTEM test wrote it: the two asymmetric atoms and NO operators.
    private static let quartzAsSeeded = header("alpha_quartz", 4.9134, 4.9134, 5.4052, 90, 90, 120) + atomLoop
        + "Si1 Si 0.4697 0.0000 0.0000\nO1 O 0.4135 0.2669 0.1191\n"
    private static let quartzCompleted = header("alpha_quartz", 4.9134, 4.9134, 5.4052, 90, 90, 120)
        + ops(["x,y,z", "-y,x-y,z+2/3", "-x+y,-x,z+1/3", "y,x,-z", "x-y,-y,-z+1/3", "-x,-x+y,-z+2/3"]) + atomLoop
        + "Si1 Si 0.4697 0.0000 0.0000\nO1 O 0.4135 0.2669 0.1191\n"
    /// Tetragonal contents in a cell whose axes happen to be equal: Ti at the origin, O at (0.3, 0.3, 0), as seeded no operators.
    private static let tetraAsSeeded = header("tetragonal_a_equals_c", 4, 4, 4, 90, 90, 90) + atomLoop + "Ti1 Ti 0.0 0.0 0.0\nO1 O 0.3 0.3 0.0\n"
    private static let tetraCompleted = header("tetragonal_a_equals_c", 4, 4, 4, 90, 90, 90)
        + ops(["x,y,z", "-y,x,z", "-x,-y,z", "y,-x,z"]) + atomLoop + "Ti1 Ti 0.0 0.0 0.0\nO1 O 0.3 0.3 0.0\n"
    private static let magnesium = header("magnesium", 3.2094, 3.2094, 5.2108, 90, 90, 120) + atomLoop
        + "Mg1 Mg 0.3333333 0.6666667 0.25\nMg2 Mg 0.6666667 0.3333333 0.75\n"
    private static let orthorhombic = header("orthorhombic", 5, 6, 7, 90, 90, 90) + atomLoop + "Fe1 Fe 0 0 0\n"
    private static let rutherfordium = header("rutherfordium", 4, 4, 4, 90, 90, 90) + atomLoop + "Rf1 Rf 0 0 0\n"
    private static let splitAtomFCC = header("gold_split", 4.0782, 4.0782, 4.0782, 90, 90, 90) + atomLoop
        + "Au1 Au 0.0000 0.0000 0.0000\nAu2 Au 0.5000 0.5000 0.0000\nAu3 Au 0.5000 0.0000 0.5000\nAu4 Au 0.0000 0.5000 0.5000\n"
        + "Au5 Au 0.0040 0.0000 0.0000\nAu6 Au 0.0000 0.0040 0.0000\n"

    private static func read(_ text: String, _ name: String = "t") throws -> CrystalStructure {
        try CIFImport.read(text, fileBaseName: name).structure
    }

    private func siteKey(_ site: AtomSite) -> String {
        func round(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }
        return "\(site.z):\(round(site.fractional.x)),\(round(site.fractional.y)),\(round(site.fractional.z)):\(round(site.occupancy))"
    }
    private func sortedKeys(_ sites: [AtomSite]) -> [String] { sites.map(siteKey).sorted() }

    // MARK: The same sites as the presets, and the class from the atoms

    /// Gold listed atom by atom and silicon's eight sites equal the presets' sites (z, position, occupancy), the cell is the
    /// preset's, and the structure is usable. HEAD: `model.symmetry == .cubic` (the metric proposed it, the atoms confirmed
    /// it); now the Laue class is read from the atoms: m-3m. Mutants: the class detection returning the metric's family only
    /// (not m-3m for gold's literal with a stray atom: see the split-atom test), a site dropped by the expansion.
    func testGoldAndSiliconListedExplicitlyMatchTheirPresets() throws {
        let gold = try Self.read(Self.goldP1, "gold")
        XCTAssertEqual(gold.laueClass, .mThreeBarM)
        XCTAssertEqual(gold.cell.metricFamily(), .cubic, "a Laue class alone is not a family: the axes must be cubic too")
        XCTAssertEqual(gold.cell.a, CrystalPresets.gold.cell.a, accuracy: 1e-9)
        XCTAssertEqual(gold.cell.alphaDeg, 90, accuracy: 1e-9)
        XCTAssertEqual(gold.sites.count, 4)
        XCTAssertEqual(sortedKeys(gold.sites), sortedKeys(CrystalPresets.gold.sites))
        XCTAssertTrue(gold.isUsable, "\(gold.validationIssues)")
        let si = try Self.read(Self.silicon, "silicon")
        XCTAssertEqual(si.laueClass, .mThreeBarM)
        XCTAssertEqual(si.cell.metricFamily(), .cubic)
        XCTAssertEqual(si.sites.count, 8)
        XCTAssertEqual(sortedKeys(si.sites), sortedKeys(CrystalPresets.silicon.sites))
        XCTAssertTrue(si.isUsable, "\(si.validationIssues)")
    }

    /// One asymmetric-unit atom and the four centring translations expand to gold's four sites and read m-3m (the file's loop
    /// declares less than the atoms have; kit item 1). Mutant: the translations ignored (1 site).
    func testCentringOperationsExpandOneAtomToTheFccBasis() throws {
        let s = try Self.read(Self.goldCentring, "gold_symm")
        XCTAssertEqual(s.cell.metricFamily(), .cubic)
        XCTAssertEqual(s.sites.count, 4, "face-centring gives exactly 4 distinct sites")
        XCTAssertEqual(sortedKeys(s.sites), sortedKeys(CrystalPresets.gold.sites))
        XCTAssertEqual(s.laueClass, .mThreeBarM)
    }

    // MARK: Structures HEAD refused, now read with the class they have

    /// alpha-quartz in the hexagonal setting. HEAD: `symmetryNotSupportedByStructure` (a trigonal structure in a hexagonal
    /// metric was refused). As seeded (two atoms, no operators) the file is a P1 and reads -1; completed with P3_221's six
    /// operators it reads -3m with 12 sites, and its metric alone still reads hexagonal. Mutant: the class taken from the metric
    /// (6/mmm), the file's operators ignored (-1 for the completed file).
    func testQuartzInHexagonalSettingImportsAsThreeBarM() throws {
        let seeded = try Self.read(Self.quartzAsSeeded, "quartz")
        XCTAssertEqual(seeded.laueClass, .oneBar)
        XCTAssertEqual(seeded.sites.count, 2)
        XCTAssertEqual(seeded.cell.metricFamily(), .hexagonal)
        let completed = try Self.read(Self.quartzCompleted, "quartz")
        XCTAssertEqual(completed.laueClass, .threeBarM)
        XCTAssertEqual(completed.sites.count, 12)
        XCTAssertEqual(completed.cell.metricFamily(), .hexagonal)
        XCTAssertTrue(completed.isUsable)
    }

    /// Tetragonal contents (Ti, O at (0.3, 0.3, 0)) in a cell with equal axes. HEAD: refused (`symmetryNotSupportedByStructure`,
    /// it must not be admitted as cubic). As seeded (no operators) it reads mmm (the atoms' own mirrors, inversion added);
    /// completed with the four 4-fold operators it reads 4/mmm; the metric alone says cubic in both. Mutant: the metric's
    /// family taken as the class (m-3m).
    func testAccidentallyCubicMetricImportsAsFourOverMmm() throws {
        let seeded = try Self.read(Self.tetraAsSeeded, "tetra")
        XCTAssertEqual(seeded.laueClass, .mmm)
        XCTAssertEqual(seeded.cell.metricFamily(), .cubic)
        let completed = try Self.read(Self.tetraCompleted, "tetra")
        XCTAssertEqual(completed.laueClass, .fourOverMmm)
        XCTAssertEqual(completed.cell.metricFamily(), .cubic)
        XCTAssertNotEqual(completed.laueClass, .mThreeBarM)
    }

    /// HCP magnesium written with 0.3333333 / 0.6666667: HEAD `.hexagonal`
    /// (the rotation had to carry its translation); now 6/mmm. Mutant: the translation required to be zero (read as -3m or lower).
    func testMagnesiumViaScrewAxisIsSixOverMmm() throws {
        let s = try Self.read(Self.magnesium, "magnesium")
        XCTAssertEqual(s.laueClass, .sixOverMmm)
        XCTAssertEqual(s.cell.metricFamily(), .hexagonal)
    }

    /// An orthorhombic cell with one Fe. HEAD: `.identity` ("Unreduced"), usable, no orientation mapping; now mmm, usable, and
    /// its kinematic list at 1.6 per Angstrom is non-empty. Mutant: the cell coerced to another system.
    func testOrthorhombicCellIsIndexedAndListed() throws {
        let s = try Self.read(Self.orthorhombic, "ortho")
        XCTAssertEqual(s.laueClass, .mmm)
        XCTAssertEqual(s.cell.metricFamily(), .orthorhombic)
        XCTAssertEqual(s.cell.a, 5, accuracy: 1e-9)
        XCTAssertEqual(s.cell.c, 7, accuracy: 1e-9)
        XCTAssertTrue(s.isUsable, "\(s.validationIssues)")
        XCTAssertFalse(try s.kinematicReflections(kMax: 1.6).kept.isEmpty)
    }

    // MARK: Refusals that moved or stayed

    /// Rf (Z = 104) has no scattering factor. HEAD: the IMPORT threw `unsupportedElement("Rf", 104)`; now the import succeeds (the
    /// kit's element table runs to Z = 118) and the kinematic list refuses it by name. Mutant: the element check dropped (the
    /// list is built with f = 0).
    func testElementBeyondTheTableIsRefusedByTheListNotTheImport() throws {
        let s = try Self.read(Self.rutherfordium, "rf")
        XCTAssertEqual(s.sites.map(\.z), [104])
        XCTAssertThrowsError(try s.kinematicReflections(kMax: 1.2)) {
            guard case .unsupportedElements(let z)? = $0 as? KinematicError else { return XCTFail("expected unsupportedElements, got \($0)") }
            XCTAssertEqual(z, [104])
        }
    }

    /// Gold plus a split atom: two extra Au 0.0163 A from the origin atom (0.0040 fractional). HEAD: `symmetryNotSupportedByStructure`
    /// (no 3-fold permutes these seven sites). The kit reads the atoms, finds the structure invalid first (two fully occupied
    /// sites closer than any real contact, kit item 10) and refuses it as `invalidStructure`, naming the distance. Mutant: the
    /// close-contact rule dropped (the file would import as a lower Laue class).
    func testSplitAtomFccIsNotM3m() {
        XCTAssertThrowsError(try Self.read(Self.splitAtomFCC, "split")) {
            guard case .invalidStructure(let issues)? = $0 as? CIFImportError else { return XCTFail("expected invalidStructure, got \($0)") }
            XCTAssertTrue(issues.contains { $0.contains("0.0163") }, "\(issues)")
        }
    }

    /// Operators with a fractional coefficient (x/2, 1/2x), a malformed fraction (/2, 2/, 1//2) or a term run into a variable
    /// (xy, x2, x.5) are refused and named, never read as something else (F5 of macTEM's CIF refuter; HEAD's 7d6fdbd1 grammar, kept
    /// by the kit); fractions and decimals still parse. Unchanged. Mutant: "x/2" read as x + 2.
    func testFractionalCoefficientsAndMalformedFractionsStayRefused() throws {
        func cif(_ op: String) -> String {
            Self.header("symop", 4, 4, 4, 90, 90, 90) + Self.ops(["x,y,z", op]) + Self.atomLoop + "Fe1 Fe 0.1 0.2 0.3\n"
        }
        for bad in ["x/2,y,z", "1/2x,y,z", "x,y/5,z", "x,y,/2", "2/,y,z", "x,y,z+1//2",
                    "xy,y,z", "x2,y,z", "x.5,y,z", "-x/2+1/2,y,z"] {
            XCTAssertThrowsError(try CIFImport.read(cif(bad), fileBaseName: "symop"), bad) {
                XCTAssertEqual($0 as? CIFImportError, .unsupportedSymmetryOperation(bad))
            }
        }
        for good in ["x+1/2,y,z", "1/2+x,1/2+y,z", "x,y,z+0.5", "-x,-y,-z", "-x+1,-y,-z+1/2"] {
            let text = Self.header("symop", 4, 5, 6, 80, 85, 95) + Self.ops(["x,y,z", good]) + Self.atomLoop + "Fe1 Fe 0.1 0.2 0.3\n"
            XCTAssertNoThrow(try CIFImport.read(text, fileBaseName: "symop"), good)
        }
    }

    /// Rock salt declared Fm-3m (225) that lists only its 48 point operations (no F-centring) is refused, naming the group,
    /// the count listed and the count needed (it once imported as CsCl). Unchanged. Mutant: the order table lookup dropped.
    func testIncompleteFm3mListIsRefusedNamingTheGap() {
        var pointOps: [String] = []
        for perm in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            for signs in 0..<8 {
                pointOps.append((0..<3).map { axis in ((signs >> axis) & 1 == 1 ? "-" : "") + ["x", "y", "z"][perm[axis]] }.joined(separator: ","))
            }
        }
        let cif = "data_MgO\n_symmetry_space_group_name_H-M 'F m -3 m'\n_symmetry_Int_Tables_number 225\n"
            + "_cell_length_a 4.2120\n_cell_length_b 4.2120\n_cell_length_c 4.2120\n_cell_angle_alpha 90\n_cell_angle_beta 90\n_cell_angle_gamma 90\n"
            + Self.ops(pointOps) + Self.atomLoop + "Mg1 Mg 0.0 0.0 0.0\nO1 O 0.5 0.5 0.5\n"
        XCTAssertEqual(pointOps.count, 48)
        XCTAssertThrowsError(try CIFImport.read(cif, fileBaseName: "t")) {
            XCTAssertEqual($0 as? CIFImportError,
                           .incompleteSymmetryOperations(spaceGroupNumber: 225, declaredName: "F m -3 m", listed: 48, required: 192))
            // The kit's `CIFImportError` is a `CustomStringConvertible`, not a `LocalizedError` (the copy's was): the sentence is its description.
            let text = "\($0)"
            XCTAssertTrue(text.contains("48") && text.contains("192") && text.contains("225") && text.contains("incomplete"), text)
        }
    }

    // MARK: DiffractoKit 0.9.0's two CIF outcome changes, through the Diffraction room's open path (design section 7)

    private static let primitiveWithNumber = "data_p1\n_symmetry_space_group_name_H-M 'C 1 2/m 1'\n_symmetry_Int_Tables_number 12\n_cell_length_a 3.201562\n_cell_length_b 3.201562\n_cell_length_c 3.000000\n_cell_angle_alpha 90.000000\n_cell_angle_beta 90.000000\n_cell_angle_gamma 102.680383\nloop_\n_symmetry_equiv_pos_as_xyz\n'-x,-y,-z'\n'-y,-x,z'\n'x,y,z'\n'y,x,-z'\nloop_\n_atom_site_label\n_atom_site_type_symbol\n_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\nSi0 Si 0.10000000 0.90000000 0.80000000\nO1 O 0.10000000 0.50000000 0.40000000\n"
    private static let primitiveSymbolOnly = "data_p2\n_symmetry_space_group_name_H-M 'C 1 2/m 1'\n_cell_length_a 3.201562\n_cell_length_b 3.201562\n_cell_length_c 3.000000\n_cell_angle_alpha 90.000000\n_cell_angle_beta 90.000000\n_cell_angle_gamma 102.680383\nloop_\n_symmetry_equiv_pos_as_xyz\n'-x,-y,-z'\n'-y,-x,z'\n'x,y,z'\n'y,x,-z'\nloop_\n_atom_site_label\n_atom_site_type_symbol\n_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\nSi0 Si 0.10000000 0.90000000 0.80000000\nO1 O 0.10000000 0.50000000 0.40000000\n"

    private static func load(_ text: String) throws -> LoadedCrystal { try CrystalLoading.load(bytes: Data(text.utf8), fileName: "case.cif") }

    /// The room's `CrystalLoading.load` on the four cases the kit's 0.9.0 moved. Red under the kit's 0.8: case 4's first import was refused.
    /// 1 beta'' as is: 22 sites, Laue 2/m, the first family {2 0 0} at d 7.3113. 2 the same without the IT number: the symbol alone is held
    /// to the same completeness and imports. 3 the four centring-translated operations removed: refused by name with 4 of 8. 4 the primitive
    /// C2/m cell with beta = 90: 6 sites, not refused, and its first two operations alone are refused (2 of 4).
    func testCentredMonoclinicCellsAfterDiffractoKit090() throws {
        let beta = MonoclinicIndexingTests.betaCIF
        // 1
        let one = try Self.load(beta)
        XCTAssertEqual(one.structure.sites.count, 22)
        XCTAssertEqual(one.structure.laueClass, .twoOverM)
        let first = try XCTUnwrap(try one.structure.kinematicReflections(kMax: 1.2).families.first?.family)
        XCTAssertEqual(first.name.replacingOccurrences(of: " ", with: ""), "{200}")
        XCTAssertEqual(first.d, 7.3113, accuracy: 5e-5)
        // 2
        let withoutNumber = beta.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains("_symmetry_Int_Tables_number") }.joined(separator: "\n")
        XCTAssertNotEqual(withoutNumber, beta)
        let two = try Self.load(withoutNumber)
        XCTAssertEqual(two.structure.sites.count, 22)
        XCTAssertEqual(two.structure.laueClass, .twoOverM)
        XCTAssertEqual(try XCTUnwrap(try two.structure.kinematicReflections(kMax: 1.2).families.first?.family.d), 7.3113, accuracy: 5e-5)
        // 3
        let centringLines = ["1/2+x,1/2+y,z", "1/2-x,1/2+y,-z", "1/2-x,1/2-y,-z", "1/2+x,1/2-y,z"]
        let fourOnly = withoutNumber.split(separator: "\n", omittingEmptySubsequences: false).filter { line in !centringLines.contains { line.contains($0) } }.joined(separator: "\n")
        XCTAssertNotEqual(fourOnly, withoutNumber)
        XCTAssertThrowsError(try Self.load(fourOnly)) {
            XCTAssertEqual($0 as? CIFImportError, .incompleteSymmetryOperationsForSymbol(symbol: "C 2/m", listed: 4, required: 8))
        }
        // 4
        for text in [Self.primitiveWithNumber, Self.primitiveSymbolOnly] {
            let loaded = try Self.load(text)
            XCTAssertEqual(loaded.structure.sites.count, 6)
        }
        let twoOps = Self.primitiveWithNumber.replacingOccurrences(of: "'x,y,z'\n'y,x,-z'\n", with: "")
        XCTAssertNotEqual(twoOps, Self.primitiveWithNumber)
        XCTAssertThrowsError(try Self.load(twoOps)) {
            guard case .incompleteSymmetryOperations(let number, _, let listed, let required)? = $0 as? CIFImportError else { return XCTFail("\($0)") }
            XCTAssertEqual(number, 12); XCTAssertEqual(listed, 2); XCTAssertEqual(required, 4)
        }
    }
}
