//
//  LatticeUnitTests.swift
//  macEM#614 (bundle C of #603): the lattice unit from file to overlay. A source that states its unit carries it (.ang and .ctf: Å; an
//  EMsoft master pattern and so a refined map: nm; a preset or a CIF: Å) and the overlay converts by it; only a source with no unit
//  (orix's .h5, which keeps what its writer had: kikuchipy keeps EMsoft's nm) is guessed. Red before: every lattice was guessed, so a
//  stated 1.9 Å cell was taken as nm (×10) and a stated 2.1 nm cell as Å (÷10 against the truth).
//

import Foundation
import TEMCore
import XCTest

nonisolated final class LatticeUnitTests: XCTestCase {

    private func a(_ phase: CrystalPhase) throws -> Double { try XCTUnwrap(KikuchiOverlay.lattice(of: phase)).a }

    func testAStatedUnitIsUsedOnEitherSideOfTheGuess() throws {
        XCTAssertEqual(try a(CrystalPhase(name: "x", lattice: [1.9, 1.9, 1.9, 90, 90, 90], latticeUnit: .angstrom)), 1.9, accuracy: 1e-12)
        XCTAssertEqual(try a(CrystalPhase(name: "x", lattice: [2.1, 2.1, 2.1, 90, 90, 90], latticeUnit: .nanometre)), 21, accuracy: 1e-12)
        XCTAssertEqual(try a(CrystalPhase(name: "Ni", lattice: [0.3524, 0.3524, 0.3524, 90, 90, 90], latticeUnit: .nanometre)), 3.524,
                       accuracy: 1e-12)
        XCTAssertEqual(try a(CrystalPhase(name: "Ni", lattice: [3.524, 3.524, 3.524, 90, 90, 90], latticeUnit: .angstrom)), 3.524, accuracy: 1e-12)
        // No unit: the guess, as before.
        XCTAssertEqual(try a(CrystalPhase(name: "Ni", lattice: [0.3524, 0.3524, 0.3524, 90, 90, 90])), 3.524, accuracy: 1e-12)
        XCTAssertEqual(try a(CrystalPhase(name: "Ni", lattice: [3.524, 3.524, 3.524, 90, 90, 90])), 3.524, accuracy: 1e-12)
    }

    func testTheSameNickelThroughEveryPathGivesTheSameBands() throws {
        let inNM = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m", lattice: [0.3524, 0.3524, 0.3524, 90, 90, 90], latticeUnit: .nanometre)
        let inA = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m", lattice: [3.524, 3.524, 3.524, 90, 90, 90], latticeUnit: .angstrom)
        let preset = IndexingPhase(name: "Ni", spaceGroup: 225, lattice: [3.524, 3.524, 3.524, 90, 90, 90], source: .preset).crystalPhase
        XCTAssertEqual(preset.latticeUnit, .angstrom)
        let bands = try [inNM, inA, preset].map { try XCTUnwrap(KikuchiOverlay.bands(for: $0, minDSpacing: 1)) }
        XCTAssertEqual(try a(inNM), try a(inA), accuracy: 1e-12)
        XCTAssertEqual(try a(preset), try a(inA), accuracy: 1e-12)
        XCTAssertEqual(bands[0].families, bands[1].families)
        XCTAssertEqual(bands[2].families, bands[1].families)
        XCTAssertFalse(bands[0].families.isEmpty)
    }

    func testTheReadersStateTheirUnit() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let ang = try ANGReader.read(url: fixtures.appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")).map
        XCTAssertTrue(ang.phases.entries.filter { $0.id != PhaseList.notIndexedID }.allSatisfy { $0.phase.latticeUnit == .angstrom })
        let ctf = try CTFReader.read(text: try CTFWriter.text(of: ang)).map
        XCTAssertTrue(ctf.phases.entries.filter { $0.id != PhaseList.notIndexedID }.allSatisfy { $0.phase.latticeUnit == .angstrom })
        // A file phase handed to the Indexing room keeps the file's unit.
        let file = IndexingPhase.fromCrystalMap(PhaseList([(1, CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m",
                                                                                lattice: [0.3524, 0.3524, 0.3524, 90, 90, 90],
                                                                                latticeUnit: .nanometre))]))
        XCTAssertEqual(file.phases.first?.crystalPhase.latticeUnit, .nanometre)
    }
}
