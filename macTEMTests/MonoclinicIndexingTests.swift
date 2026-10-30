import XCTest
import DiffractoCore
import DiffractoScattering
import DiffractoGeometry
import TEMCore

/// V1-8 S2c: monoclinic cells (unique axis b, 2/m) in the family lists, and the beta'' CIF through the import, on
/// DiffractoKit since the switch, with no Python. The numpy and gemmi parity is tools/parity/indexing-parity, whose
/// source controls (now on the kit's files) these tests share; each test names the ones that turn it red. The cells: M-P
/// (a 7.2, b 4.9, c 5.6 A, beta 104 deg, one Al at the origin), M-C (the same, C-centred), M-sq (a = c = 5, b = 4,
/// cos beta = -1/4: accidental (h,k,l) ~ (l,k,h) coincidences) and beta'' (Mg5Si6, C2/m, Andersen et al. 1998, the CIF below
/// as tools/parity/crystal-structures writes it). Three tests of the copy's own internals (orbit canonical forms, the refusal order
/// with `unsupportedLattice`, that refusal's reason) leave with it: the kit's PointSymmetryTests and ScatteringTruthTests hold
/// them.
nonisolated final class MonoclinicIndexingTests: XCTestCase {

    private typealias Index = RingIndexing

    private static let al = [AtomSite(z: 13, fractional: [0, 0, 0])]
    private static let alC = [AtomSite(z: 13, fractional: [0, 0, 0]), AtomSite(z: 13, fractional: [0.5, 0.5, 0])]

    private static func cell(_ a: Double, _ b: Double, _ c: Double, _ al: Double, _ be: Double, _ ga: Double,
                             sites: [AtomSite] = MonoclinicIndexingTests.al) -> CrystalStructure {
        CrystalStructure.detectingSymmetry(cell: UnitCell(a: a, b: b, c: c, alphaDeg: al, betaDeg: be, gammaDeg: ga), sites: sites)
    }
    private static let mP = cell(7.2, 4.9, 5.6, 90, 104, 90)
    private static let mC = cell(7.2, 4.9, 5.6, 90, 104, 90, sites: alC)
    private static let mSq = cell(5, 4, 5, 90, acos(-0.25) * 180 / .pi, 90)

    /// The CIF `make_beta_double_prime.py` writes (cell and Table 3 set 3 of Andersen et al., Acta Mater. 46, 3283).
    static let betaCIF = """
        data_beta_double_prime_Mg5Si6
        _chemical_name_mineral            'beta-double-prime'
        _chemical_formula_sum             'Mg10 Si12'
        _chemical_formula_structural      'Mg5 Si6'
        _publ_author_name                 'Andersen, S. J.'
        _journal_name_full                'Acta Materialia'
        _journal_volume                   46
        _journal_year                     1998
        _journal_page_first               3283
        _cell_length_a                    15.16
        _cell_length_b                    4.05
        _cell_length_c                    6.74
        _cell_angle_alpha                 90.0
        _cell_angle_beta                  105.3
        _cell_angle_gamma                 90.0
        _symmetry_space_group_name_H-M    'C 2/m'
        _symmetry_Int_Tables_number       12
        loop_
        _symmetry_equiv_pos_as_xyz
          'x,y,z'
          '-x,y,-z'
          '-x,-y,-z'
          'x,-y,z'
          '1/2+x,1/2+y,z'
          '1/2-x,1/2+y,-z'
          '1/2-x,1/2-y,-z'
          '1/2+x,1/2-y,z'
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        _atom_site_occupancy
        _atom_site_B_iso_or_equiv
          Mg1   Mg    0.0000   0.0000   0.0000  1.0  0.5
          Mg2   Mg    0.3459   0.0000   0.0890  1.0  1.0
          Mg3   Mg    0.4300   0.0000   0.6520  1.0  0.8
          Si1   Si    0.0565   0.0000   0.6490  1.0  1.1
          Si2   Si    0.1885   0.0000   0.2240  1.0  0.5
          Si3   Si    0.2171   0.0000   0.6170  1.0  2.5
        """

    private static func betaDocument() throws -> CIFDocument {
        try CIFImport.read(betaCIF, fileBaseName: "beta_double_prime_Mg5Si6")
    }
    private static func beta() throws -> CrystalStructure { try betaDocument().structure }
    private static func list(_ s: CrystalStructure, kMax: Double = 1.2) throws -> [ReflectionFamily] {
        try s.kinematicReflections(kMax: kMax).families.map(\.family)
    }
    private static func hkl(_ h: Int, _ k: Int, _ l: Int) -> MillerIndex { MillerIndex(h, k, l) }
    private static func family(_ l: [ReflectionFamily], _ m: MillerIndex) -> ReflectionFamily? { l.first { $0.members.contains(m) } }

    // MARK: Lattice recognition

    /// The cell's family (read from the six parameters at 1e-9, `UnitCell.metricFamily`): unique axis b is monoclinic; beta within
    /// 1e-9 deg of 90 is orthorhombic (it was refused as `unsupportedLattice`), 1e-8 off is monoclinic; alpha or gamma 1e-8 off 90
    /// with beta off 90 is triclinic; unique axis c and a are monoclinic about their own axis (were refused), triclinic is
    /// triclinic (was refused); cubic and hexagonal are unchanged. Mutants: the family tolerance 1e-7 (beta 90 deg + 1e-8 reads
    /// orthorhombic), a unique axis taken as b, alpha / gamma ignored.
    func testLatticeRecognition() {
        func f(_ a: Double, _ b: Double, _ c: Double, _ al: Double, _ be: Double, _ ga: Double) -> UnitCell.MetricFamily {
            UnitCell(a: a, b: b, c: c, alphaDeg: al, betaDeg: be, gammaDeg: ga).metricFamily()
        }
        XCTAssertEqual(Self.mP.cell.metricFamily(), .monoclinic(uniqueAxis: .b))
        XCTAssertEqual(f(15.16, 4.05, 6.74, 90, 105.3, 90), .monoclinic(uniqueAxis: .b))
        XCTAssertEqual(f(7.2, 4.9, 5.6, 90, 90 + 1e-8, 90), .monoclinic(uniqueAxis: .b))
        XCTAssertEqual(f(7.2, 4.9, 5.6, 90, 96, 90), .monoclinic(uniqueAxis: .b))
        XCTAssertEqual(f(7.2, 4.9, 5.6, 90, 90, 90), .orthorhombic)
        XCTAssertEqual(f(7.2, 4.9, 5.6, 90, 90 + 1e-10, 90), .orthorhombic, "within 1e-9 deg of 90")
        XCTAssertEqual(f(7.2, 4.9, 5.6, 90 + 1e-8, 104, 90), .triclinic)
        XCTAssertEqual(f(7.2, 4.9, 5.6, 90 - 1e-8, 104, 90), .triclinic)
        XCTAssertEqual(f(7.2, 4.9, 5.6, 90, 104, 90 + 1e-8), .triclinic)
        XCTAssertEqual(f(7.2, 4.9, 5.6, 90, 90, 100), .monoclinic(uniqueAxis: .c))
        XCTAssertEqual(f(7.2, 4.9, 5.6, 100, 90, 90), .monoclinic(uniqueAxis: .a))
        XCTAssertEqual(f(7.2, 4.9, 5.6, 92, 95, 101), .triclinic)
        XCTAssertEqual(CrystalPresets.gold.cell.metricFamily(), .cubic)
        XCTAssertEqual(CrystalPresets.magnesium.cell.metricFamily(), .hexagonal)
    }

    // MARK: Orbits

    /// Orbit sizes on M-P: {1 1 0} 4 members, {2 0 0} 2 (k = 0), {0 1 0} 2 (h = l = 0), {0 0 1} 2; each family is one
    /// orbit and its members are the full orbit. Mutants: m5 (multiplicity as the orbit count), m12 (mirror missing).
    func testOrbitSizesAndMultiplicity() throws {
        XCTAssertEqual(Self.mP.laueClass, .twoOverM)
        let l = try Self.list(Self.mP)
        for (m, n) in [(Self.hkl(1, 1, 0), 4), (Self.hkl(2, 0, 0), 2), (Self.hkl(0, 1, 0), 2), (Self.hkl(0, 0, 1), 2), (Self.hkl(1, 1, 1), 4)] {
            let f = try XCTUnwrap(Self.family(l, m))
            XCTAssertEqual(f.multiplicity, n, "\(m)")
            XCTAssertEqual(f.orbits.count, 1)
            XCTAssertEqual(Set(f.members).count, n)
        }
        let f110 = try XCTUnwrap(Self.family(l, Self.hkl(1, 1, 0)))
        XCTAssertEqual(Set(f110.members), [Self.hkl(1, 1, 0), Self.hkl(-1, 1, 0), Self.hkl(-1, -1, 0), Self.hkl(1, -1, 0)])
        XCTAssertEqual(l.count, 392)
        XCTAssertEqual(l.map(\.multiplicity).reduce(0, +), 1384)
    }

    // MARK: The numbers

    /// The family g is the list's own: the closed forms d(h00) = a sin(beta)/h, d(0k0) = b/k, d(00l) = c sin(beta)/l and
    /// 1/d^2 = (h^2/a^2 + l^2/c^2 - 2hl cos(beta)/(ac))/sin^2(beta) + k^2/b^2 for (101) and (10-1), at 1e-12 relative.
    /// Mutants: none of the ring rule moves this alone (the cell is the kit's); it pins that the family g is the smallest
    /// member's |g| and that the two signs of l are two families.
    func testClosedFormDSpacingsOnTheMonoclinicCell() throws {
        let (a, b, c) = (7.2, 4.9, 5.6), beta = 104.0 * Double.pi / 180
        let s = sin(beta), co = cos(beta)
        let l = try Self.list(Self.mP)
        func d(_ h: Int, _ k: Int, _ ll: Int) throws -> Double {
            try XCTUnwrap(Self.family(l, Self.hkl(h, k, ll))).d
        }
        func closed(_ h: Double, _ k: Double, _ ll: Double) -> Double {
            1 / (((h * h / (a * a) + ll * ll / (c * c) - 2 * h * ll * co / (a * c)) / (s * s) + k * k / (b * b)).squareRoot())
        }
        XCTAssertEqual(try d(1, 0, 0), a * s, accuracy: 1e-12 * a)
        XCTAssertEqual(try d(0, 1, 0), b, accuracy: 1e-12 * b)
        XCTAssertEqual(try d(0, 0, 1), c * s, accuracy: 1e-12 * c)
        XCTAssertEqual(try d(1, 0, 1), closed(1, 0, 1), accuracy: 1e-12 * 7)
        XCTAssertEqual(try d(1, 0, -1), closed(1, 0, -1), accuracy: 1e-12 * 7)
        XCTAssertNotEqual(try d(1, 0, 1), try d(1, 0, -1), accuracy: 1e-3)
        XCTAssertTrue(try XCTUnwrap(Self.family(l, Self.hkl(1, 0, 1))).members.contains(Self.hkl(-1, 0, -1)))
        XCTAssertFalse(try XCTUnwrap(Self.family(l, Self.hkl(1, 0, 1))).members.contains(Self.hkl(1, 0, -1)))
    }

    /// beta'': (2 0 1) and (2 0 -1) are two rings, 4.3246 and 5.6555 A; the orbit rule
    /// that ignores the sign of l (m1) or folds it (m2) puts them in one.
    func testPlusAndMinusLAreDifferentFamilies() throws {
        let l = try Self.list(try Self.beta())
        let p = try XCTUnwrap(Self.family(l, Self.hkl(2, 0, 1))), m = try XCTUnwrap(Self.family(l, Self.hkl(2, 0, -1)))
        XCTAssertNotEqual(p.g, m.g)
        XCTAssertEqual(p.d, 4.324567590028738, accuracy: 1e-9)
        XCTAssertEqual(m.d, 5.655535439744675, accuracy: 1e-9)
        XCTAssertEqual(p.name, "{2 0 1}")
        XCTAssertEqual(m.name, "{2 0 -1}")
    }

    /// An acute beta (F1): M-P with beta 76 deg is M-P with beta 104 deg and the sign of l mirrored, so the same
    /// rings carry the swapped names: the ring named {1 0 1} at 76 deg has the d of 104 deg's {1 0 -1}, and the other way round.
    /// The cell is monoclinic b for beta < 90 deg too. Mutant m16: the family test restricted to beta > 90 deg.
    func testAcuteBetaSwapsTheNamesOfPlusAndMinusL() throws {
        let acute = Self.cell(7.2, 4.9, 5.6, 90, 76, 90)
        XCTAssertEqual(acute.laueClass, .twoOverM)
        XCTAssertEqual(acute.cell.metricFamily(), .monoclinic(uniqueAxis: .b))
        let a = try Self.list(acute), o = try Self.list(Self.mP)
        XCTAssertEqual(a.count, o.count)
        let a101 = try XCTUnwrap(Self.family(a, Self.hkl(1, 0, 1))), o10m1 = try XCTUnwrap(Self.family(o, Self.hkl(1, 0, -1)))
        let a10m1 = try XCTUnwrap(Self.family(a, Self.hkl(1, 0, -1))), o101 = try XCTUnwrap(Self.family(o, Self.hkl(1, 0, 1)))
        XCTAssertEqual(a101.g, o10m1.g, accuracy: 1e-12 * o10m1.g)
        XCTAssertEqual(a10m1.g, o101.g, accuracy: 1e-12 * o101.g)
        XCTAssertNotEqual(a101.g, a10m1.g, accuracy: 1e-3)
        XCTAssertEqual(a101.name, "{1 0 1}")
        XCTAssertEqual(a10m1.name, "{1 0 -1}")
        XCTAssertTrue(a101.members.contains(Self.hkl(-1, 0, -1)))
        XCTAssertFalse(a101.members.contains(Self.hkl(1, 0, -1)))
        XCTAssertGreaterThan(a101.d, a10m1.d, "at 76 deg (1 0 1) is the larger spacing; at 104 deg it is (1 0 -1)")
        XCTAssertGreaterThan(o10m1.d, o101.d)
    }

    /// M-C: no member with h + k odd; beta'' (C-centred) the same, and its first ten families are the registered ones
    /// (d to 4 decimals, multiplicity, name). Mutants: S2's absences-kept moves these; m6/m7 (grouping) move the ten.
    func testCentredCellsAndTheFirstBetaFamilies() throws {
        for c in [Self.mC, try Self.beta()] {
            for f in try Self.list(c) {
                for m in f.members { XCTAssertEqual((m.h + m.k) % 2, 0, "\(m)") }
            }
        }
        let first: [(String, Double, Int)] = [("{2 0 0}", 7.3113, 2), ("{0 0 1}", 6.5011, 2), ("{2 0 -1}", 5.6555, 2),
            ("{2 0 1}", 4.3246, 2), ("{1 1 0}", 3.9031, 4), ("{4 0 0}", 3.6557, 2), ("{4 0 -1}", 3.6207, 2),
            ("{1 1 -1}", 3.4554, 4), ("{2 0 -2}", 3.3124, 2), ("{0 0 2}", 3.2506, 2)]
        let fam = try Self.list(try Self.beta())
        for (i, e) in first.enumerated() {
            XCTAssertEqual(fam[i].name, e.0)
            XCTAssertEqual(fam[i].d, e.1, accuracy: 5e-5)
            XCTAssertEqual(fam[i].multiplicity, e.2)
        }
    }

    // MARK: Coincidences, near-orthorhombic

    /// DiffractoKit 0.3.0: with a = c, cos beta = -1/4 and one atom at the origin the a<->c swap (h,k,l) -> (l,k,h) is a
    /// true symmetry (0.1.0 read 2/m only, and called {1 0 0} + {0 0 1} an accidental coincidence of two orbits). The
    /// symmetry is mmm, so {1 0 0} is one orbit of 4 and {1 1 0} one of 8; what is still accidental is named by its orbits:
    /// {2 0 0} + {2 0 -1} (8, one |g|) and 27 more of the 83 families. 698 reflections. Mutants: m6/m7 (grouping at
    /// 1e-4 or 0), m14 (the name lists the first orbit only). The other accidental coincidence is
    /// testNearOrthorhombicSplitsAndMerges (beta = 90 deg + 1e-8: 163 families of two orbits).
    func testSwapEquivalentReflectionsAreOneOrbitAndCoincidencesStayNamedByTheirOrbits() throws {
        let l = try Self.list(Self.mSq)
        let a = try XCTUnwrap(Self.family(l, Self.hkl(1, 0, 0)))
        XCTAssertEqual(a.name, "{1 0 0}")
        XCTAssertEqual(a.multiplicity, 4)
        XCTAssertEqual(a.d, 4.8412, accuracy: 5e-5)
        let b = try XCTUnwrap(Self.family(l, Self.hkl(1, 1, 0)))
        XCTAssertEqual(b.name, "{1 1 0}")
        XCTAssertEqual(b.multiplicity, 8)
        let c = try XCTUnwrap(Self.family(l, Self.hkl(2, 0, 0)))
        XCTAssertEqual(c.name, "{2 0 0} + {2 0 -1}")
        XCTAssertEqual(c.multiplicity, 8)
        XCTAssertEqual(c.d, 2.4206, accuracy: 5e-5)
        XCTAssertEqual(l.count, 83)
        XCTAssertEqual(l.filter { $0.orbits.count > 1 }.count, 28)
        XCTAssertEqual(l.map(\.multiplicity).reduce(0, +), 698)
    }

    /// beta = 90 deg + 1e-4 splits the (h,k,l)/(h,k,-l) pairs (402 families, none with two orbits); + 1e-8 (still
    /// monoclinic, past the 1e-9 deg tolerance) merges them within the 1e-9 family rule (239 families, 163 with two
    /// orbits). Mutants: m6 (grouping at 1e-4: the split pairs merge), m7 (grouping at 0: the merged pairs split), m11.
    func testNearOrthorhombicSplitsAndMerges() throws {
        let splitCell = Self.cell(7.2, 4.9, 5.6, 90, 90 + 1e-4, 90)
        XCTAssertEqual(splitCell.laueClass, .twoOverM)
        let split = try Self.list(splitCell)
        XCTAssertEqual(split.count, 402)
        XCTAssertEqual(split.filter { $0.orbits.count > 1 }.count, 0)
        let mergedCell = Self.cell(7.2, 4.9, 5.6, 90, 90 + 1e-8, 90)
        XCTAssertEqual(mergedCell.laueClass, .twoOverM)
        let merged = try Self.list(mergedCell)
        XCTAssertEqual(merged.count, 239)
        XCTAssertEqual(merged.filter { $0.orbits.count > 1 }.count, 163)
    }

    // MARK: The index

    /// On beta'': q on {2 0 0} at u = 1e-3 is accepted, next {0 0 1}; q midway between {3 1 5} and {7 3 0} (1.03e-5 apart)
    /// at u = 1e-3 is ambiguous, naming both. Mutants: m6 (the pair merges into one family: accepted).
    func testIndexOnTheBetaList() throws {
        let l = try Self.list(try Self.beta())
        let f200 = try XCTUnwrap(Self.family(l, Self.hkl(2, 0, 0)))
        let a = try Index.index(q: f200.g, sigma: 1e-3 * f200.g, in: l, kMax: 1.2)
        XCTAssertEqual(a.best.family.name, "{2 0 0}")
        XCTAssertEqual(a.next?.family.name, "{0 0 1}")
        XCTAssertEqual(a.best.z, 0, accuracy: 1e-12)
        let p = try XCTUnwrap(Self.family(l, Self.hkl(3, 1, 5))), r = try XCTUnwrap(Self.family(l, Self.hkl(7, 3, 0)))
        XCTAssertEqual(abs(p.g - r.g) / min(p.g, r.g), 1.03e-5, accuracy: 5e-8)
        let q = (p.g + r.g) / 2
        do {
            _ = try Index.index(q: q, sigma: 1e-3 * q, in: l, kMax: 1.2)
            XCTFail("a pair 1e-5 apart at sigma/q = 1e-3 must be ambiguous")
        } catch {
            XCTAssertEqual(error.name, "ambiguous")
            guard case .ambiguous(let c) = error else { return XCTFail() }
            XCTAssertTrue(Set(c.map(\.family.name)).isSuperset(of: ["{3 1 5}", "{7 3 0}"]), "every family within k sigma is named, these two among them")
        }
    }

    /// beta'' through CIFImport: 22 sites (the C-centring expanded), space group 12, Laue class 2/m with a cell that reads
    /// monoclinic b (it was `model.symmetry == .monoclinic` of the copy), usable; 417 families, 1442 reflections at k_max 1.2.
    /// Mutants c1 (centring skipped: 11 sites), c2 (beta from the alpha tag), c3 (z read as y), c4 (duplicate tolerance 0.5),
    /// c5 ("1/2+x" parsed as "x") - each moves the sites, the cell or the counts.
    func testBetaDoublePrimeFromCIFText() throws {
        let s = try Self.beta()
        XCTAssertEqual(s.sites.count, 22)
        XCTAssertEqual(s.sites.filter { $0.z == 12 }.count, 10)
        XCTAssertEqual(s.sites.filter { $0.z == 14 }.count, 12)
        XCTAssertEqual(s.spaceGroupNumber, 12)
        XCTAssertEqual(s.laueClass, .twoOverM)
        XCTAssertEqual(s.cell.metricFamily(), .monoclinic(uniqueAxis: .b))
        XCTAssertTrue(s.isUsable)
        XCTAssertEqual(s.cell.betaDeg, 105.3)
        XCTAssertEqual(s.cell.a, 15.16)
        let l = try Self.list(s)
        XCTAssertEqual(l.count, 417)
        XCTAssertEqual(l.map(\.multiplicity).reduce(0, +), 1442)
        XCTAssertEqual(l.filter { $0.multiplicity == 2 }.count, 113)
        XCTAssertEqual(l.filter { $0.multiplicity == 4 }.count, 304)
        XCTAssertEqual(l.filter { $0.orbits.count > 1 }.count, 0)
    }
}
