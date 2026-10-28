import XCTest
import DiffractoCore
import DiffractoScattering
import DiffractoGeometry
import TEMCore

/// V1-8 S2 (ADR 022), on DiffractoKit's `RingIndexing` and kinematic lists since the switch (ADR 025): the family
/// lists and the decision, with no Python. Exact dyadic lists (g in {1, 1.5, 2}, sigma 0.125) pin z, the k test, the margin
/// and the reach to the last bit; the real crystals pin the lists, the orbit names and the refusals. The numpy parity is
/// tools/parity/indexing-parity, whose source controls (now on the kit's files) these tests share; each test names the ones that
/// turn it red. What the registration of the switch (archive: roadmap-registrations-2026-10-15.md, "DiffractoKit 0.0.3") changes in this file: the cell's lattice
/// is no longer recognised or refused here (every crystal system is indexed; the Laue class is read), the list builder's
/// refusals are `KinematicError`s, and elements are checked before k_max.
nonisolated final class DSpacingIndexingTests: XCTestCase {

    // MARK: Helpers

    private typealias Index = RingIndexing
    private static let kMax = 1.2

    private static func structure(_ cell: UnitCell, _ sites: [AtomSite]) -> CrystalStructure {
        CrystalStructure.detectingSymmetry(cell: cell, sites: sites)
    }

    /// The rings of `s` after the |F| cut (the kit's `kinematicReflections(kMax:).families`).
    private static func rings(_ s: CrystalStructure, kMax: Double = 1.2) throws -> [ReflectionFamily] {
        try s.kinematicReflections(kMax: kMax).families.map(\.family)
    }

    private static func hcp(_ a: Double, c: Double) -> CrystalStructure {
        structure(.hexagonal(a: a, c: c), [AtomSite(z: 12, fractional: [0, 0, 0]), AtomSite(z: 12, fractional: [2.0 / 3, 1.0 / 3, 0.5])])
    }

    /// An orthorhombic cell (a 2, b 1, c 1/2 A, one Al) whose rings at g = 1, 1.5, 2, 3, ... are exact doubles
    /// (g = h/2, k, 2 l), for dyadic arithmetic, as DiffractoKit's own indexing tests do.
    private static func dyadic(_ gs: [Double]) throws -> [ReflectionFamily] {
        let all = try rings(structure(.orthorhombic(a: 2, b: 1, c: 0.5), [AtomSite(z: 13, fractional: [0, 0, 0])]), kMax: 4)
        return try gs.map { g in try XCTUnwrap(all.first { $0.g == g }, "the dyadic cell has no ring at exactly g = \(g)") }
    }

    private func verdict(_ q: Double, _ sigma: Double, _ list: [ReflectionFamily], kMax: Double = 4, k: Double = 3)
        -> Result<Index.Assignment, Index.Refusal> {
        do throws(Index.Refusal) { return .success(try Index.index(q: q, sigma: sigma, in: list, kMax: kMax, coverage: k)) }
        catch { return .failure(error) }
    }

    private func accepted(_ r: Result<Index.Assignment, Index.Refusal>, file: StaticString = #filePath, line: UInt = #line) -> Index.Assignment? {
        if case .success(let a) = r { return a }
        if case .failure(let e) = r { XCTFail("expected an assignment, got \(e.name): \(e.reason)", file: file, line: line) }
        return nil
    }

    private func refusal(_ r: Result<Index.Assignment, Index.Refusal>, file: StaticString = #filePath, line: UInt = #line) -> Index.Refusal? {
        if case .failure(let e) = r { return e }
        XCTFail("expected a refusal, got an assignment", file: file, line: line)
        return nil
    }

    private func family(_ list: [ReflectionFamily], containing m: MillerIndex, file: StaticString = #filePath, line: UInt = #line) -> ReflectionFamily? {
        let f = list.first { $0.members.contains(m) }
        if f == nil { XCTFail("no family holds \(m)", file: file, line: line) }
        return f
    }

    private static let au = CrystalPresets.gold
    private static let auA = 4.0782

    // MARK: The lists

    /// Au has 8 families and {111} holds 8 members. Mutants: absences kept (Au 8 -> 20), the multiplicity as the orbit
    /// count (8 -> 1), grouping at 0 or 1e-2 (the count moves for Mg, not here: see the Mg test).
    func testGoldFamilies() throws {
        XCTAssertEqual(Self.au.laueClass, .mThreeBarM)
        XCTAssertEqual(Self.au.cell.metricFamily(), .cubic)      // the class alone is not the family
        let au = try Self.rings(Self.au)
        XCTAssertEqual(au.count, 8)
        let first = try XCTUnwrap(au.first)
        XCTAssertEqual(first.multiplicity, 8)
        XCTAssertEqual(first.orbits, [MillerIndex(1, 1, 1)])
        XCTAssertEqual(first.name, "{1 1 1}")
        XCTAssertEqual(first.g, 3.0.squareRoot() / Self.auA, accuracy: 1e-12)
        XCTAssertEqual(first.d, Self.auA / 3.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(try Self.rings(CrystalPresets.aluminum).count, 8)
        // A family's g rises strictly.
        XCTAssertEqual(au.map(\.g), au.map(\.g).sorted())
    }

    /// The intensity of a family is S1's: the sum of |F|^2 over its members. Mutant: none moves this alone; it pins that the
    /// field is carried (the decision does not use it).
    func testFamilyIntensityIsTheSumOverMembers() throws {
        let list = try Self.au.kinematicReflections(kMax: Self.kMax)
        let reflection = try XCTUnwrap(list.kept.first)
        XCTAssertEqual(try XCTUnwrap(list.families.first).intensity, 8 * reflection.structureFactor.intensity,
                       accuracy: 1e-12 * reflection.structureFactor.intensity * 8)
    }

    /// Mg (hcp): {10-10} 6 members, {0002} 2, {10-11} and {11-20} named in Miller-Bravais indices, {11-20} ONE orbit although
    /// its member (-1, -1, 0) has fewer than two non-negative entries, Mg has 24 families and {10-15}, {21-32} stay apart
    /// (0.156 % in g). Mutants: hexagonal orbits by the cubic rule, hexagonal without the negation, grouping at 1e-2
    /// (24 -> 22), the multiplicity as the orbit count, grouping at 0 (the count rises).
    func testMagnesiumFamiliesAndOrbits() throws {
        XCTAssertEqual(CrystalPresets.magnesium.laueClass, .sixOverMmm)
        XCTAssertEqual(CrystalPresets.magnesium.cell.metricFamily(), .hexagonal)
        let mg = try Self.rings(CrystalPresets.magnesium)
        XCTAssertEqual(mg.count, 24)
        let prism = try XCTUnwrap(family(mg, containing: MillerIndex(1, 0, 0)))
        XCTAssertEqual(prism.multiplicity, 6)
        XCTAssertEqual(prism.name, "{1 0 -1 0}")
        let basal = try XCTUnwrap(family(mg, containing: MillerIndex(0, 0, 2)))
        XCTAssertEqual(basal.multiplicity, 2)
        XCTAssertEqual(basal.name, "{0 0 0 2}")
        let pyramid = try XCTUnwrap(family(mg, containing: MillerIndex(1, 0, 1)))
        XCTAssertEqual(pyramid.name, "{1 0 -1 1}")
        XCTAssertEqual(pyramid.multiplicity, 12)
        let eleven = try XCTUnwrap(family(mg, containing: MillerIndex(1, 1, 0)))
        XCTAssertEqual(eleven.name, "{1 1 -2 0}")
        XCTAssertEqual(eleven.orbits.count, 1, "(1 1 0) and (-1 -1 0) are one orbit")
        XCTAssertEqual(eleven.multiplicity, 6)
        let a = try XCTUnwrap(family(mg, containing: MillerIndex(1, 0, 5)))
        let b = try XCTUnwrap(family(mg, containing: MillerIndex(2, 1, 2)))
        XCTAssertNotEqual(a.g, b.g, "Mg {10-15} and {21-32} are two rings")
        XCTAssertEqual(abs(b.g / a.g - 1), 1.5e-3, accuracy: 1e-4)
    }

    /// Si (diamond): {333} and {511} are one ring of 32 members and two orbits; Si has 10 families. Mutants: the
    /// multiplicity as the orbit count (32 -> 2), absences kept (10 -> 36).
    func testSiliconCoincidentOrbitsAreOneFamily() throws {
        let si = try Self.rings(CrystalPresets.silicon)
        XCTAssertEqual(si.count, 10)
        let ring = try XCTUnwrap(family(si, containing: MillerIndex(3, 3, 3)))
        XCTAssertEqual(ring.multiplicity, 32)
        XCTAssertEqual(ring.orbits, [MillerIndex(5, 1, 1), MillerIndex(3, 3, 3)])
        XCTAssertEqual(ring.name, "{5 1 1} + {3 3 3}")
        XCTAssertTrue(ring.members.contains(MillerIndex(5, 1, 1)))
    }

    /// Ideal c/a hcp (c = a sqrt(8/3)): {30-32} and {0006} coincide: one ring of 14 members (12 + 2). Mutant: grouping at 0
    /// splits them at the roundoff of |g|.
    func testIdealHcpCoincidentOrbitsAreOneFamily() throws {
        let a = 3.2094
        let list = try Self.rings(Self.hcp(a, c: a * (8.0 / 3.0).squareRoot()))
        XCTAssertEqual(list.count, 23)
        let ring = try XCTUnwrap(family(list, containing: MillerIndex(3, 0, 2)))
        XCTAssertEqual(ring.multiplicity, 14)
        XCTAssertEqual(ring.orbits.count, 2)
        XCTAssertTrue(ring.members.contains(MillerIndex(0, 0, 6)))
    }

    /// S1's cut keeps weak families: the Weak-cut cell (a second Cu site at occupancy 0.99815) has 10. Mutant: S1's cut
    /// raised to 1e-2 (10 -> 6).
    func testWeakFamiliesCount() throws {
        let weak = Self.structure(.cubic(a: 3), [AtomSite(z: 29, fractional: [0, 0, 0]),
                                                 AtomSite(z: 29, fractional: [0.5, 0.5, 0.5], occupancy: 0.9981472011156598)])
        XCTAssertEqual(try Self.rings(weak).count, 10)
    }

    /// The cell's family is read within 1e-9 (relative lengths, degrees), and the Laue class from the atoms: b = a(1 + 1e-11)
    /// stays m-3m (8 rings) and gamma = 120 deg + 1e-10 deg 6/mmm (24); b = a(1 + 1e-6) and 1e-8 are no longer refused as
    /// `unsupportedLattice` but read 4/mmm along b (15 rings; mmm at 0.0.3), gamma + 1e-8 deg 2/m (24), alpha + 1e-8 deg -3m (8). Mutants: the
    /// metric tolerance 0 (the near cells fall to a lower class), any cell taken as cubic.
    func testMetricToleranceKeepsNearCubicAndNearHexagonalCells() throws {
        let a = Self.auA
        let fcc = Self.au.sites
        func read(_ cell: UnitCell, _ sites: [AtomSite]) throws -> (LaueClass?, UnitCell.MetricFamily, Int) {
            let s = Self.structure(cell, sites)
            return (s.laueClass, s.cell.metricFamily(), try Self.rings(s).count)
        }
        let nearCubic = try read(UnitCell(a: a, b: a * (1 + 1e-11), c: a, alphaDeg: 90, betaDeg: 90, gammaDeg: 90), fcc)
        XCTAssertEqual(nearCubic.0, .mThreeBarM); XCTAssertEqual(nearCubic.1, .cubic); XCTAssertEqual(nearCubic.2, 8)
        let mg = CrystalPresets.magnesium
        let nearHex = try read(UnitCell(a: mg.cell.a, b: mg.cell.b, c: mg.cell.c, alphaDeg: 90, betaDeg: 90, gammaDeg: 120 + 1e-10), mg.sites)
        XCTAssertEqual(nearHex.0, .sixOverMmm); XCTAssertEqual(nearHex.1, .hexagonal); XCTAssertEqual(nearHex.2, 24)
        for eps in [1e-6, 1e-8] {
            let off = try read(UnitCell(a: a, b: a * (1 + eps), c: a, alphaDeg: 90, betaDeg: 90, gammaDeg: 90), fcc)
            // DiffractoKit 0.1.0 (archive: roadmap-registrations-2026-10-15.md "DiffractoKit 0.1.0, second registration"): a = c with b different is tetragonal along b.
            XCTAssertEqual(off.0, .fourOverMmm, "b = a(1 + \(eps))"); XCTAssertEqual(off.1, .tetragonal(uniqueAxis: .b)); XCTAssertEqual(off.2, 15)
        }
        let gamma = try read(UnitCell(a: mg.cell.a, b: mg.cell.b, c: mg.cell.c, alphaDeg: 90, betaDeg: 90, gammaDeg: 120 + 1e-8), mg.sites)
        XCTAssertEqual(gamma.0, .twoOverM); XCTAssertEqual(gamma.1, .monoclinic(uniqueAxis: .c)); XCTAssertEqual(gamma.2, 24)
        let alpha = try read(UnitCell(a: a, b: a, c: a, alphaDeg: 90 + 1e-8, betaDeg: 90, gammaDeg: 90), fcc)
        XCTAssertEqual(alpha.0, .threeBarM); XCTAssertEqual(alpha.1, .rhombohedral); XCTAssertEqual(alpha.2, 8)
    }

    // MARK: The deviation, z, margin and reach (exact)

    /// delta of q = 1.01 g is g/q - 1 = -0.00990099..., not 1 - q/g = -0.01. Mutant: delta over the measured d reversed.
    func testSignedDeviationIsOverTheMeasuredD() throws {
        let au = try Self.rings(Self.au)
        let g = try XCTUnwrap(au.first).g
        let q = 1.01 * g
        let a = try XCTUnwrap(accepted(verdict(q, 0.005 * q, au, kMax: Self.kMax)))
        XCTAssertEqual(a.best.deviation, 1 / 1.01 - 1, accuracy: 1e-14)
        XCTAssertEqual(a.best.deviation, -0.0099009900990099, accuracy: 1e-14)
        XCTAssertEqual(a.best.relativeDeviation, 0.0099009900990099, accuracy: 1e-14)
        XCTAssertEqual(a.dMeasured, 1 / q, accuracy: 1e-15)
        XCTAssertEqual(a.best.z, 0.01 * g / (0.005 * q), accuracy: 1e-12)
    }

    /// Exact z and margin: g in {1, 1.5, 2}, sigma 0.125, q = 1: z = 0, the next (1.5) at z = 4, margin (16 - 0)/2 = 8.
    /// Mutants: z as |q - g|/(sigma q) (z = 0.5), the margin as z2 - z1 (4), the next as the upper neighbour (still 1.5:
    /// see the Au {200} test), the margin clause tightened.
    func testDyadicZAndMargin() throws {
        let list = try Self.dyadic([1, 1.5, 2])
        let a = try XCTUnwrap(accepted(verdict(1, 0.125, list)))
        XCTAssertEqual(a.best.z, 0)
        XCTAssertEqual(try XCTUnwrap(a.next).z, 4)
        XCTAssertEqual(try XCTUnwrap(a.next).family.g, 1.5)
        XCTAssertEqual(try XCTUnwrap(a.next).deviation, 0.5)
        XCTAssertEqual(try XCTUnwrap(a.margin), 8)
        // z = |q - g|/sigma at a point that is not a family: q = 1.0625 -> z = 0.5
        let b = try XCTUnwrap(accepted(verdict(1.0625, 0.125, list)))
        XCTAssertEqual(b.best.z, 0.5)
        XCTAssertEqual(b.best.deviation, 1 / 1.0625 - 1, accuracy: 1e-15)
    }

    /// z <= k, not z^2 <= k: q = 1.375, sigma = 0.125 on {1, 2, 3} is z = 3 and accepted at the default k = 3 (the next, 2, at
    /// z = 5: margin 8); at k = 2.9 it is `noneWithinTolerance`. Also pins the default k = 3 and z = 2.5 accepted. Mutants:
    /// z^2 <= k (refused: 9 > 3), z over sigma q.
    func testWithinIsZAtMostKAndDefaultKIsThree() throws {
        XCTAssertEqual(Index.defaultCoverage, 3)
        let list = try Self.dyadic([1, 2, 3])
        let at3 = try XCTUnwrap(accepted(verdict(1.375, 0.125, list)))
        XCTAssertEqual(at3.best.z, 3)
        XCTAssertEqual(at3.coverage, 3)
        XCTAssertEqual(try XCTUnwrap(at3.next).z, 5)
        let viaDefault = try XCTUnwrap(accepted(.success(try Index.index(q: 1.375, sigma: 0.125, in: list, kMax: 4))))
        XCTAssertEqual(viaDefault.coverage, 3)
        let none = try XCTUnwrap(refusal(verdict(1.375, 0.125, list, k: 2.9)))
        XCTAssertEqual(none.name, "noneWithinTolerance")
        let at25 = try XCTUnwrap(accepted(verdict(1.3125, 0.125, list)))
        XCTAssertEqual(at25.best.z, 2.5)
        XCTAssertEqual(try XCTUnwrap(at25.margin), (5.5 * 5.5 - 2.5 * 2.5) / 2)
    }

    /// Two families both at z = 2 <= k = 2 (g {1, 1.5}, q = 1.25, sigma 0.125) are `ambiguous`, payload in (z, g) order. Mutant:
    /// z^2 <= k (z = 2: 4 > 2, none within), the second-within check (see the next test).
    func testBothWithinKIsAmbiguousInOrder() throws {
        let list = try Self.dyadic([1, 1.5, 2])
        let r = try XCTUnwrap(refusal(verdict(1.25, 0.125, list, k: 2)))
        guard case .ambiguous(let candidates) = r else { return XCTFail("expected ambiguous, got \(r.name)") }
        XCTAssertEqual(candidates.map(\.family.g), [1, 1.5])
        XCTAssertEqual(candidates.map(\.z), [2, 2])
    }

    /// Two families within k with a margin far above ln 19 are still `ambiguous` (z = 0 and z = 4 at k = 4: margin 8). Mutant:
    /// the second-within check dropped (the pair is accepted on its margin).
    func testTwoWithinKIsAmbiguousEvenWithALargeMargin() throws {
        let list = try Self.dyadic([1, 1.5, 2])
        let r = try XCTUnwrap(refusal(verdict(1, 0.125, list, k: 4)))
        guard case .ambiguous(let candidates) = r else { return XCTFail("expected ambiguous, got \(r.name)") }
        XCTAssertEqual(candidates.map(\.family.g), [1, 1.5])
    }

    /// One family within k whose margin to the next is below ln 19 (q = 1, sigma 0.25, k = 1: z = 0 and 2, margin 2 < 2.944)
    /// is `ambiguous` with [best, next]. Mutant: the margin clause dropped.
    func testMarginBelowLn19IsAmbiguous() throws {
        let list = try Self.dyadic([1, 1.5, 2])
        let r = try XCTUnwrap(refusal(verdict(1, 0.25, list, k: 1)))
        guard case .ambiguous(let candidates) = r else { return XCTFail("expected ambiguous, got \(r.name)") }
        XCTAssertEqual(candidates.map(\.family.g), [1, 1.5])
        XCTAssertEqual(Index.minimumMargin, log(19.0))
    }

    /// The registered margin plant: Au {331} -> {420}, sigma = gap/5.7, z = 2.5 (next 3.2, margin 1.995 < ln 19):
    /// `ambiguous`. Mutants: the margin clause dropped, the margin as z2 - z1 (0.7 < ln 19 is still refused: only the
    /// dyadic margin test sees it), second-within (z 3.2 > 3 is not within, so it does not fire here).
    func testAuMarginPlantIsAmbiguous() throws {
        let au = try Self.rings(Self.au)
        let f331 = try XCTUnwrap(family(au, containing: MillerIndex(3, 3, 1)))
        let f420 = try XCTUnwrap(family(au, containing: MillerIndex(4, 2, 0)))
        let sigma = (f420.g - f331.g) / 5.7
        let q = f331.g + 2.5 * sigma
        let r = try XCTUnwrap(refusal(verdict(q, sigma, au, kMax: Self.kMax)))
        guard case .ambiguous(let candidates) = r else { return XCTFail("expected ambiguous, got \(r.name)") }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].z, 2.5, accuracy: 1e-9)
        XCTAssertEqual(candidates[1].z, 3.2, accuracy: 1e-9)
    }

    /// The reach on a dyadic list {1, 1.5, 2}, q = 1, sigma 0.125: the next (1.5) is 0.5 away, so q + R = 1.5. At k_max 1.5
    /// it is accepted (1.5 is not above k_max); at k_max 1.4375 it is `beyondKMax`, though q + k sigma = 1.375 is below
    /// the edge. Mutant: the reach at k sigma alone.
    func testReachIncludesTheDistanceToTheNextFamily() throws {
        let list = try Self.dyadic([1, 1.5, 2])
        let inside = try XCTUnwrap(accepted(verdict(1, 0.125, list, kMax: 1.5)))
        XCTAssertEqual(inside.best.family.g, 1)
        let r = try XCTUnwrap(refusal(verdict(1, 0.125, list, kMax: 1.4375)))
        guard case .beyondKMax(let reach, let kMax) = r else { return XCTFail("expected beyondKMax, got \(r.name)") }
        XCTAssertEqual(reach, 1.5)
        XCTAssertEqual(kMax, 1.4375)
        XCTAssertEqual(Index.reach(coverage: 3), (9 + 2 * log(19.0)).squareRoot(), accuracy: 1e-15)
    }

    // MARK: Which family, which next

    /// Au {200} measured just above its g: the best is {200} and the next is {111}, the nearer of its two neighbours
    /// ({220} is farther). Mutants: the next as the upper neighbour ({220}), the nearest as the first g >= q.
    func testAuNextIsTheNearerNeighbour() throws {
        let au = try Self.rings(Self.au)
        let f200 = try XCTUnwrap(family(au, containing: MillerIndex(2, 0, 0)))
        let q = f200.g * 1.0001
        let a = try XCTUnwrap(accepted(verdict(q, 1e-3 * q, au, kMax: Self.kMax)))
        XCTAssertEqual(a.best.family.g, f200.g)
        XCTAssertEqual(try XCTUnwrap(a.next).family.g, try XCTUnwrap(family(au, containing: MillerIndex(1, 1, 1))).g)
        XCTAssertGreaterThan(try XCTUnwrap(a.next).z, 100)
    }

    /// The nearest family of a `noneWithinTolerance`, with its z and signed deviation; a tie in z goes to the smaller g.
    /// Mutant: the nearest as the first g >= q (g = 2 here).
    func testNoneCarriesTheNearestFamily() throws {
        let list = try Self.dyadic([1, 1.5, 2])
        let r = try XCTUnwrap(refusal(verdict(1.75, 0.0625, list)))
        guard case .noneWithinTolerance(let nearest?) = r else { return XCTFail("expected none with a nearest, got \(r.name)") }
        XCTAssertEqual(nearest.family.g, 1.5)
        XCTAssertEqual(nearest.z, 4)
        XCTAssertEqual(nearest.deviation, 1.5 / 1.75 - 1, accuracy: 1e-15)
    }

    // MARK: The edges of the list

    /// A one-family list (Au, k_max 0.45): accepted with no next and no margin; an empty list (k_max 0.3) is
    /// `noneWithinTolerance` with no nearest. Mutants: the next as the upper neighbour (nil -> crash or wrong), none of the
    /// refusals reordered.
    func testOneFamilyAndEmptyLists() throws {
        let one = try Self.rings(Self.au, kMax: 0.45)
        XCTAssertEqual(one.count, 1)
        let g = one[0].g
        let a = try XCTUnwrap(accepted(verdict(g, 1e-3 * g, one, kMax: 0.45)))
        XCTAssertNil(a.next)
        XCTAssertNil(a.margin)
        let empty = try Self.rings(Self.au, kMax: 0.3)
        XCTAssertEqual(empty.count, 0)
        let r = try XCTUnwrap(refusal(verdict(0.2, 2e-4, empty, kMax: 0.3)))
        guard case .noneWithinTolerance(let nearest) = r else { return XCTFail("expected none, got \(r.name)") }
        XCTAssertNil(nearest)
        let beyond = try XCTUnwrap(refusal(verdict(0.299, 3e-4, empty, kMax: 0.3)))
        XCTAssertEqual(beyond.name, "beyondKMax")
    }

    /// Mg {20-25} (the list's last family) and Si {620} (its listed next, {531}, is nearer than the edge but the true next,
    /// {533}, is past it) at their own g, and q = 1.25, are `beyondKMax`. Mutant: the reach at k sigma alone (Si {620} is
    /// accepted), the reach as the nearest family's distance alone.
    func testBeyondKMax() throws {
        let mg = try Self.rings(CrystalPresets.magnesium)
        let last = try XCTUnwrap(mg.last)
        XCTAssertEqual(try XCTUnwrap(refusal(verdict(last.g, 1e-3 * last.g, mg, kMax: Self.kMax))).name, "beyondKMax")
        let si = try Self.rings(CrystalPresets.silicon)
        let f620 = try XCTUnwrap(family(si, containing: MillerIndex(6, 2, 0)))
        XCTAssertEqual(try XCTUnwrap(refusal(verdict(f620.g, 1e-3 * f620.g, si, kMax: Self.kMax))).name, "beyondKMax")
        let au = try Self.rings(Self.au)
        XCTAssertEqual(try XCTUnwrap(refusal(verdict(1.25, 1.25e-3, au, kMax: Self.kMax))).name, "beyondKMax")
    }

    /// Kinematically forbidden positions are `noneWithinTolerance`: Si {200}, Si {222}, Mg {0001}, Au {100}, and Au {111}
    /// against Al's list. Mutant: absences kept (the forbidden position finds a family).
    func testForbiddenPositionsAreNone() throws {
        let si = try Self.rings(CrystalPresets.silicon)
        let siA = 5.4309
        for g in [2 / siA, 12.0.squareRoot() / siA] {
            XCTAssertEqual(try XCTUnwrap(refusal(verdict(g, 1e-3 * g, si, kMax: Self.kMax))).name, "noneWithinTolerance")
        }
        let mg = try Self.rings(CrystalPresets.magnesium)
        let q0001 = 1 / 5.2108
        XCTAssertEqual(try XCTUnwrap(refusal(verdict(q0001, 1e-3 * q0001, mg, kMax: Self.kMax))).name, "noneWithinTolerance")
        let au = try Self.rings(Self.au)
        let q100 = 1 / Self.auA
        XCTAssertEqual(try XCTUnwrap(refusal(verdict(q100, 1e-3 * q100, au, kMax: Self.kMax))).name, "noneWithinTolerance")
        let al = try Self.rings(CrystalPresets.aluminum)
        let g111 = 3.0.squareRoot() / Self.auA
        XCTAssertEqual(try XCTUnwrap(refusal(verdict(g111, 1e-3 * g111, al, kMax: Self.kMax))).name, "noneWithinTolerance")
    }

    /// Mg {10-15} and {21-32}, 0.156 % apart, with the measurement 40 % of the way: `ambiguous` at u = 1e-3. Mutants:
    /// grouping at 1e-2 (the pair is one family and the answer changes), the second-within check.
    func testMgNearPairIsAmbiguous() throws {
        let mg = try Self.rings(CrystalPresets.magnesium)
        let a = try XCTUnwrap(family(mg, containing: MillerIndex(1, 0, 5)))
        let b = try XCTUnwrap(family(mg, containing: MillerIndex(2, 1, 2)))
        let q = a.g + 0.4 * (b.g - a.g)
        XCTAssertEqual(try XCTUnwrap(refusal(verdict(q, 1e-3 * q, mg, kMax: Self.kMax))).name, "ambiguous")
    }

    /// A margin of exactly ln 19 is accepted (the clause is `margin < ln 19`, not `<=`). ln 19 is irrational, so the test
    /// scans sigma by ulps, at four q, for measurements on {1, 2} whose computed margin IS `minimumMargin`, and counts the
    /// ones that are accepted; it also counts the ones whose margin is one ulp short, which must be ambiguous. It fails if no
    /// exact measurement is found (widen the scan). Mutant: margin <= ln 19.
    func testMarginExactlyLn19IsAccepted() throws {
        let list = try Self.dyadic([1, 2])
        let target = Index.minimumMargin
        var exact = 0, acceptedExact = 0, shortAmbiguous = 0
        for offset in [0.0, 0.125, 0.25, 0.375] {
            let q = 1 + offset
            // z_best = offset/sigma, z_next = (1 - offset)/sigma, margin = ((1 - offset)^2 - offset^2)/(2 sigma^2)
            var sigma = ((1 - 2 * offset) / (2 * target)).squareRoot()
            for _ in 0..<3000 { sigma = sigma.nextDown }
            for _ in 0..<6000 {
                sigma = sigma.nextUp
                let k = (offset / sigma + (1 - offset) / sigma) / 2         // z_best <= k < z_next
                let zb = abs(q - 1) / sigma, zn = abs(q - 2) / sigma
                let margin = (zn * zn - zb * zb) / 2
                if margin == target {
                    exact += 1
                    if case .success = verdict(q, sigma, list, k: k) { acceptedExact += 1 }
                } else if margin == target.nextDown {
                    if case .failure(let e) = verdict(q, sigma, list, k: k), e.name == "ambiguous" { shortAmbiguous += 1 }
                }
            }
        }
        XCTAssertGreaterThan(exact, 0, "no measurement with a margin of exactly ln 19 was found")
        XCTAssertEqual(acceptedExact, exact, "a margin of exactly ln 19 must be accepted")
        XCTAssertGreaterThan(shortAmbiguous, 0)
    }

    /// The label is carried ("Unvalidated stays labelled"): it begins "none", and an assignment reports it.
    func testValidationLabelIsNone() throws {
        XCTAssertTrue(Index.validation.hasPrefix("none:"))
        let a = try XCTUnwrap(accepted(verdict(1, 0.125, try Self.dyadic([1, 1.5, 2]))))
        XCTAssertEqual(a.validation, Index.validation)
    }

    /// Two reflections of one |g| to 1e-5, not 1e-9 (ideal hcp with c stretched by 1e-5): {30-32} and {0006} are two rings
    /// (24 families, not 23). Mutant: the family tolerance 1e-4 merges them.
    func testNearCoincidentHcpOrbitsStaySeparate() throws {
        let a = 3.2094
        let list = try Self.rings(Self.hcp(a, c: a * (8.0 / 3.0).squareRoot() * (1 + 1e-5)))
        XCTAssertEqual(list.count, 24)
        let x = try XCTUnwrap(family(list, containing: MillerIndex(3, 0, 2)))
        let y = try XCTUnwrap(family(list, containing: MillerIndex(0, 0, 6)))
        XCTAssertNotEqual(x.g, y.g)
        XCTAssertEqual(x.multiplicity, 12)
        XCTAssertEqual(y.multiplicity, 2)
    }

    // MARK: The refusals, by name and in order

    /// k_max outside (0, 4] is refused by the list builder as `KinematicError.reflectionList(.invalidKMax)` (0, negative, NaN,
    /// infinite, above 4; it was `Refusal.invalidInput` before the switch), and `index` refuses q, sigma, k and k_max each at
    /// 0, -1, NaN, +/-infinity as `invalidInput`. Mutants: sigma = 0 accepted, the k_max bound dropped (k_max = 5 is built).
    func testInvalidInputIsRefusedByName() throws {
        for kMax in [0, -1, .nan, .infinity, -.infinity, 4.5, 5] as [Double] {
            XCTAssertThrowsError(try Self.au.kinematicReflections(kMax: kMax), "k_max \(kMax)") {
                guard case .reflectionList(.invalidKMax)? = $0 as? KinematicError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertNoThrow(try Self.au.kinematicReflections(kMax: 4))
        let au = try Self.rings(Self.au)
        let bad: [Double] = [0, -1, .nan, .infinity, -.infinity]
        for x in bad {
            XCTAssertEqual(try XCTUnwrap(refusal(verdict(x, 1e-3, au, kMax: Self.kMax))).name, "invalidInput", "q = \(x)")
            XCTAssertEqual(try XCTUnwrap(refusal(verdict(0.42, x, au, kMax: Self.kMax))).name, "invalidInput", "sigma = \(x)")
            XCTAssertEqual(try XCTUnwrap(refusal(verdict(0.42, 1e-3, au, kMax: Self.kMax, k: x))).name, "invalidInput", "k = \(x)")
            XCTAssertEqual(try XCTUnwrap(refusal(verdict(0.42, 1e-3, au, kMax: x))).name, "invalidInput", "k_max = \(x)")
        }
    }

    /// Every crystal system is indexed (it was `unsupportedLattice` for all but cubic, hexagonal and monoclinic b): a tetragonal
    /// cell (4, 4, 5; one Cu) reads 4/mmm with 58 rings and its {0 0 1} ring first at 1/c, an orthorhombic (3, 4, 5) mmm with
    /// 74, and b = a(1 + 1e-6) 4/mmm (tetragonal along b; mmm at 0.0.3) with 15. An element beyond the table (Z = 104) is refused by the list as
    /// `unsupportedElements([104])`. Mutants: any cell taken as cubic, unsupported elements ignored.
    func testLowerSymmetryCellsAreIndexedAndAnUnsupportedElementIsRefused() throws {
        let cu = [AtomSite(z: 29, fractional: [0, 0, 0])]
        let tetra = Self.structure(.tetragonal(a: 4, c: 5), cu)
        XCTAssertEqual(tetra.laueClass, .fourOverMmm)
        let tr = try Self.rings(tetra)
        XCTAssertEqual(tr.count, 58)
        XCTAssertEqual(try XCTUnwrap(tr.first).g, 1.0 / 5, accuracy: 1e-13)
        XCTAssertEqual(try XCTUnwrap(tr.first).multiplicity, 2)
        let ortho = Self.structure(.orthorhombic(a: 3, b: 4, c: 5), cu)
        XCTAssertEqual(ortho.laueClass, .mmm)
        XCTAssertEqual(try Self.rings(ortho).count, 74)
        let off = Self.structure(UnitCell(a: Self.auA, b: Self.auA * (1 + 1e-6), c: Self.auA, alphaDeg: 90, betaDeg: 90, gammaDeg: 90), Self.au.sites)
        XCTAssertEqual(off.laueClass, .fourOverMmm)     // a = c, b different: tetragonal along b (DiffractoKit 0.1.0; mmm at 0.0.3)
        XCTAssertEqual(try Self.rings(off).count, 15)
        let withZ104 = Self.structure(.cubic(a: Self.auA), Self.au.sites + [AtomSite(z: 104, fractional: [0.5, 0.5, 0.5])])
        XCTAssertThrowsError(try withZ104.kinematicReflections(kMax: 1.2)) {
            guard case .unsupportedElements(let z)? = $0 as? KinematicError else { return XCTFail("expected unsupportedElements, got \($0)") }
            XCTAssertEqual(z, [104])
        }
    }

    /// The first that applies: a tetragonal cell with k_max 0 is refused for k_max; with a Z = 104 site it is
    /// `unsupportedElements`, and the element is checked BEFORE k_max (it was k_max first, then the lattice, then the
    /// element); `index` refuses a NaN q before every other check. Mutants: the element check moved after k_max.
    func testFirstThatAppliesPairs() throws {
        let tetra = [AtomSite(z: 29, fractional: [0, 0, 0])]
        let s = Self.structure(.tetragonal(a: 4, c: 5), tetra)
        XCTAssertThrowsError(try s.kinematicReflections(kMax: 0)) {
            guard case .reflectionList(.invalidKMax)? = $0 as? KinematicError else { return XCTFail("\($0)") }
        }
        let tetraZ = Self.structure(.tetragonal(a: 4, c: 5), tetra + [AtomSite(z: 104, fractional: [0.5, 0.5, 0.5])])
        for kMax in [1.2, 0] {
            XCTAssertThrowsError(try tetraZ.kinematicReflections(kMax: kMax), "k_max \(kMax)") {
                guard case .unsupportedElements(let z)? = $0 as? KinematicError else { return XCTFail("\($0)") }
                XCTAssertEqual(z, [104])
            }
        }
        // In `index`: invalid q beats every other check, even on a list where the family would be beyond k_max.
        let au = try Self.rings(Self.au)
        XCTAssertEqual(try XCTUnwrap(refusal(verdict(.nan, 0, au, kMax: Self.kMax))).name, "invalidInput")
    }

    /// The refusals' names are a stable key and the reason is a sentence: no number is needed to tell them apart.
    func testRefusalNamesAndReasons() throws {
        let au = try Self.rings(Self.au)
        let none = try XCTUnwrap(refusal(verdict(0.2452, 2.4e-4, au, kMax: Self.kMax)))
        XCTAssertEqual(none.name, "noneWithinTolerance")
        XCTAssertTrue(none.reason.contains("possible causes, unranked"))
        XCTAssertEqual(none.errorDescription, none.reason)
    }
}
