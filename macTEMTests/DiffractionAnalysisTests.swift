//
//  DiffractionAnalysisTests.swift
//  The Diffraction room's owner on the planted Au pattern (`DemoDocuments.diffractionPattern`: centre (256, 256), Δq 0.0125 Å⁻¹/px,
//  {111} at R 33.98, {200} at 39.24, {220} as six spots at R 55.48): calibration from a ring on a standard, a second ring and a spot indexed
//  with the planted spacings, the precedence of the three scales, re-indexing without a refit, the CSV and the Results rows.
//  The tolerances are the kit's: the room adds none of its own beyond identity with the kit's answer on the same inputs.
//

import XCTest
import DiffractoCore
import DiffractoScattering
import DiffractoGeometry
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
@testable import macTEM

nonisolated final class DiffractionAnalysisTests: XCTestCase {

    @MainActor private func calibrated() async throws -> (DiffractionAnalysis, CalibratedImage) {
        let image = DemoDocuments.diffractionPattern()
        let analysis = DiffractionAnalysis()
        analysis.bind(image)
        let family = try XCTUnwrap(analysis.standardFamilies().first { $0.name == "{111}" }, "Au {111} is the first family")
        await analysis.fitRing(image: image, inner: 29, outer: 37, calibrateOn: family.family)?.value
        return (analysis, image)
    }

    @MainActor func testTheCentreStartsAtTheImageCentreAndKMaxFromTheScale() {
        let image = DemoDocuments.diffractionPattern()
        let analysis = DiffractionAnalysis()
        analysis.bind(image)
        XCTAssertEqual(analysis.centre?.row, 256)
        XCTAssertEqual(analysis.centre?.column, 256)
        XCTAssertEqual(analysis.centre?.source, .fileCentre)
        XCTAssertEqual(analysis.kMax, 3.2, accuracy: 0.11, "the inscribed circle's q")
    }

    @MainActor func testTheFileAxisIsTheScaleUntilARingFitSetsOne() async throws {
        let image = DemoDocuments.diffractionPattern()
        let analysis = DiffractionAnalysis()
        analysis.bind(image)
        let before = try XCTUnwrap(analysis.calibration(for: image))
        XCTAssertEqual(before.source, .fileAxis)
        XCTAssertEqual(before.deltaQ, 0.0125 * 1.01, accuracy: 1e-12)
        let (fitted, same) = try await calibrated()
        let after = try XCTUnwrap(fitted.calibration(for: same))
        guard case .ringFit(let standard, let family) = after.source else { return XCTFail("source \(after.source)") }
        XCTAssertEqual(standard, "Au"); XCTAssertEqual(family, "{111}")
        XCTAssertEqual(after.deltaQ, 0.0125, accuracy: 0.0125 * 0.01, "the planted scale, read back from the ring")
        let versus = try XCTUnwrap(fitted.fitVersusFilePercent(for: same))
        XCTAssertEqual(versus, -1, accuracy: 0.3, "the file's axis was written 1 % large")
    }

    /// Identity with the kit: the room's calibration IS `RingCalibration.fit` on the same inputs.
    @MainActor func testTheCalibrationEqualsTheKitsOnTheSameInputs() async throws {
        let (analysis, image) = try await calibrated()
        let kit = try RingCalibration.fit(pattern: DiffractionCompute.pattern(of: image), centerQX: 256, centerQY: 256, innerRadius: 29, outerRadius: 37,
                                          d: 4.0782 / 3.0.squareRoot(), highTensionVolts: 200_000, pixelPitchMM: nil)
        let ours = try XCTUnwrap(analysis.calibration(for: image)?.ring)
        let theirs = try XCTUnwrap(kit.calibration)
        XCTAssertEqual(ours.deltaQ, theirs.deltaQ, accuracy: 1e-12)
        XCTAssertEqual(ours.radius, theirs.radius, accuracy: 1e-9)
        XCTAssertEqual(ours.lengthPixels, theirs.lengthPixels)
    }

    @MainActor func testASecondRingAndASpotAreIndexedWithThePlantedSpacings() async throws {
        let (analysis, image) = try await calibrated()
        await analysis.fitRing(image: image, inner: 37, outer: 41.5)?.value
        analysis.addSpot(image: image, row: 256 + 55.48 * sin(.pi / 4) + 1.0, column: 256 + 55.48 * cos(.pi / 4) - 1.0)
        let rows = analysis.readout(image: image)
        XCTAssertEqual(rows.count, 3, "the calibrating ring, the {200} ring, the spot")
        XCTAssertEqual(rows[0].family, "{111}"); XCTAssertTrue(rows[0].isCalibrating)
        XCTAssertEqual(rows[1].family, "{200}", "verdict: \(rows[1].verdict)")
        // 0.2 %: the kit's fit of the {111} ring reads 0.1 % low on this pattern, and the {200} spacing inherits it through Δq.
        XCTAssertEqual(try XCTUnwrap(rows[1].d), 2.0391, accuracy: 4e-3)
        XCTAssertEqual(rows[2].kind, .spot)
        XCTAssertEqual(rows[2].family, "{220}", "verdict: \(rows[2].verdict)")
        XCTAssertEqual(try XCTUnwrap(rows[2].d), 1.4419, accuracy: 3e-3)
        XCTAssertEqual(rows[1].verdict, "accepted")
    }

    /// A new crystal re-indexes the rows already measured, with no refit.
    @MainActor func testANewCrystalReindexesWithoutRefitting() async throws {
        let (analysis, image) = try await calibrated()
        let ringsBefore = analysis.rings
        XCTAssertEqual(analysis.readout(image: image)[0].family, "{111}")
        analysis.setCrystal(.preset(try XCTUnwrap(StandardCrystals.named("Si"))))
        let si = analysis.readout(image: image)[0]
        XCTAssertEqual(analysis.rings, ringsBefore, "the ring was not fitted again")
        XCTAssertEqual(analysis.crystal.name, "Si")
        // The row equals the kit's own indexing of the same q.
        let list = try XCTUnwrap(analysis.list())
        let direct = IndexingDisplay.index(q: try XCTUnwrap(si.q), tolerancePercent: analysis.tolerancePercent, in: list)
        XCTAssertEqual(si.verdict, direct.verdict)
        XCTAssertEqual(si.family, direct.family.map { DiffractionCompute.familyName($0) })
    }

    @MainActor func testWithoutAnyScaleARowSaysSo() {
        var bump = [Float](repeating: 1, count: 64 * 64)
        bump[40 * 64 + 40] = 50
        let flat = CalibratedImage(width: 64, height: 64, pixels: bump, x: nil, y: nil, fileName: "none", source: "", voltage: nil)
        let analysis = DiffractionAnalysis()
        analysis.bind(flat)
        analysis.addSpot(image: flat, row: 40, column: 40)
        XCTAssertNil(analysis.calibration(for: flat))
        XCTAssertTrue(analysis.readout(image: flat).first?.verdict.hasPrefix("no scale yet") ?? false)
        analysis.typedDeltaQ = 0.02
        XCTAssertEqual(analysis.calibration(for: flat)?.source, .typed)
    }

    @MainActor func testTheCSVStatesTheScaleTheCrystalAndTheValidation() async throws {
        let (analysis, image) = try await calibrated()
        let text = analysis.exportText(image: image)
        XCTAssertTrue(text.contains("# file: Demo Au pattern"))
        XCTAssertTrue(text.contains("# centre: row 256, column 256 (the image centre)"))
        XCTAssertTrue(text.contains("# calibration: fit Au {111}"))
        XCTAssertTrue(text.contains("# crystal: Au; k_max"))
        XCTAssertTrue(text.contains("# validation: none"))
        XCTAssertTrue(text.contains(DiffractionExport.columns))
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("ring,1,") })
        XCTAssertTrue(line.contains("{111}"))
    }

    @MainActor func testTheResultsLedgerListsTheTwoGroups() async throws {
        let (analysis, image) = try await calibrated()
        let rows = analysis.resultRows(image: image)
        XCTAssertEqual(rows.filter { $0.group == .calibration }.count, 1)
        XCTAssertEqual(rows.filter { $0.group == .rings }.count, 1)
        let calibration = try XCTUnwrap(rows.first { $0.group == .calibration })
        XCTAssertEqual(try XCTUnwrap(calibration.entry("delta_q")?.value), 0.0125, accuracy: 1.3e-4)
        XCTAssertEqual(rows.first { $0.group == .rings }?.entry("family")?.text, "{111}")
    }

    /// The beta'' CIF opened as the room's crystal lists the kit's own families: the room's list IS `kinematicReflections` of the loaded structure.
    @MainActor func testACIFCrystalListsTheKitsFamiliesInTheRoom() throws {
        let loaded = try CrystalLoading.load(bytes: Data(MonoclinicIndexingTests.betaCIF.utf8), fileName: "beta.cif")
        let analysis = DiffractionAnalysis()
        analysis.setCrystal(.cif(loaded))
        analysis.setKMax(1.2)
        let ours = try XCTUnwrap(analysis.list()).families.prefix(10).map { DiffractionCompute.familyName($0.family) }
        let kit = try DiffractionCompute.list(of: loaded.structure, kMax: 1.2).families.prefix(10).map { DiffractionCompute.familyName($0.family) }
        XCTAssertEqual(ours, kit)
        XCTAssertEqual(ours.first, "{200}")
        XCTAssertEqual(analysis.crystal.sha256, loaded.sha256)
        XCTAssertEqual(analysis.crystal.name, loaded.displayName)
    }

    /// The view opens on the pattern's own extent (display only), not on the whole frame: the demo's rings reach 68 px, so ±70..90 px. A frame
    /// that is all signal gives no extent (the whole image). Red under: no extent (the old sixth of the pane).
    func testTheViewOpensOnThePatternsExtent() {
        let image = DemoDocuments.diffractionPattern()
        let centre = DiffractionCentre.imageCentre(width: image.width, height: image.height)
        let extent = DiffractionCompute.contentRadius(pixels: image.pixels, width: image.width, height: image.height, centre: centre)
        XCTAssertNotNil(extent)
        XCTAssertGreaterThan(extent ?? 0, 70)
        XCTAssertLessThan(extent ?? 999, 95)
        let noise = (0..<(128 * 128)).map { Float(($0 * 7919) % 1000) }
        XCTAssertNil(DiffractionCompute.contentRadius(pixels: noise, width: 128, height: 128, centre: .imageCentre(width: 128, height: 128)), "a frame of signal everywhere has no extent")
    }

    @MainActor func testZoomIsClampedToTheImageAndFitReturnsToTheExtent() {
        let image = DemoDocuments.diffractionPattern()
        let view = DiffractionViewState()
        view.setAutoExtent(80)
        XCTAssertEqual(view.viewHalfSide(for: image), 80)
        view.zoom(by: 2, image: image)
        XCTAssertEqual(view.viewHalfSide(for: image), 40)
        view.zoom(by: 1000, image: image)
        XCTAssertEqual(view.viewHalfSide(for: image), 8, "never closer than 8 px")
        view.showWholeImage(image)
        XCTAssertEqual(view.viewHalfSide(for: image), 256)
        view.fitView()
        XCTAssertEqual(view.viewHalfSide(for: image), 80)
    }

    /// The annulus is ordered and at least 1 px from the centre, and a non-finite number changes nothing: view state, not on the results owner.
    @MainActor func testTheAnnulusIsOrderedAndFinite() {
        let view = DiffractionViewState()
        view.setAnnulus(inner: 40, outer: 30)
        XCTAssertEqual(view.annulusInner, 30); XCTAssertEqual(view.annulusOuter, 40)
        view.setAnnulus(inner: -5, outer: 20)
        XCTAssertEqual(view.annulusInner, 1)
        view.setAnnulus(inner: .nan, outer: 99)
        XCTAssertEqual(view.annulusOuter, 20)
    }

    /// The readout is made again only when something it depends on changed, a body never writes observed state, and the families are cached.
    /// Red under: the rows rebuilt on every call (a new array each time is invisible here, so the check is that a crystal change DOES change them
    /// and an unrelated call returns the very same rows); `list()` writing `crystalFailure` from a body.
    @MainActor func testTheReadoutIsCachedAndAReadWritesNothing() async throws {
        let (analysis, image) = try await calibrated()
        let first = analysis.readout(image: image)
        XCTAssertEqual(analysis.readout(image: image), first)
        let failureBefore = analysis.crystalFailure
        _ = analysis.list(); _ = analysis.standardFamilies(); _ = analysis.standardFamilies()
        XCTAssertEqual(analysis.crystalFailure, failureBefore)
        analysis.setTolerance(percent: 50)
        XCTAssertNotEqual(analysis.tolerancePercent, 1)
        analysis.setKMax(0.3)
        let small = analysis.readout(image: image)
        XCTAssertEqual(small[0].family, nil, "at k_max 0.3 Å⁻¹ the {111} ring (0.42) has no family")
    }
}
