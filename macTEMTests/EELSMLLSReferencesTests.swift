//
//  EELSMLLSReferencesTests.swift
//  The References under Edges enter the MLLS fit (SpectroKit `EELSMLLSOptions.references`): one more linear amplitude per reference.
//
//  THE TRUTH: the planted core loss of `EELSControlsTests` (C K, N K and O K in the amounts 2 : 1 : 1.5 on a power law, C 44.4, N 22.2, O 33.3 at%) with a
//  planted extra feature: a Gaussian of 6 eV σ at 415 eV, peak 70 counts at pixel 0, scaled like the rest by (1 + 0.1 k) at pixel k. That shape, imported
//  as an MSA reference, is what MLLS needs to fit the feature instead of folding it into the N K edge. The room's numbers are checked against the kit's
//  `EELSMLLS.fit` with the same references, value for value; the planted composition is the sanity check.
//

import XCTest
import SpectroCore
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSMLLSReferencesTests: XCTestCase {

    static let bumpCentreEV = 415.0, bumpSigmaEV = 6.0, bumpPeak = 70.0

    static func bump(_ e: Double) -> Double { exp(-(e - bumpCentreEV) * (e - bumpCentreEV) / (2 * bumpSigmaEV * bumpSigmaEV)) }

    /// The planted core loss plus the feature.
    static func core() throws -> CoreLossSpectrumImage {
        let plain = try EELSControlsTests.core()
        var counts = plain.counts
        let n = plain.channels
        for p in 0..<plain.pixelCount {
            for c in 0..<n { counts[p * n + c] += bumpPeak * bump(plain.energyOffsetEV + plain.energyScaleEV * Double(c)) * (1 + 0.1 * Double(p)) }
        }
        return try CoreLossSpectrumImage(nx: plain.nx, ny: plain.ny, channels: n, counts: counts, energyOffsetEV: plain.energyOffsetEV,
                                         energyScaleEV: plain.energyScaleEV)
    }

    /// The feature's shape as an MSA file, 1 eV channels from 380 to 450 eV (on the core loss's channels), peak 1.
    static func referenceFile() throws -> URL {
        let values = (0...70).map { String(bump(380 + Double($0))) }.joined(separator: "\n")
        let msa = """
        #FORMAT      : EMSA/MAS Spectral Data File
        #VERSION     : 1.0
        #TITLE       : planted feature
        #NPOINTS     : 71
        #NCOLUMNS    : 1
        #XUNITS      : eV
        #YUNITS      : counts
        #DATATYPE    : Y
        #XPERCHAN    : 1
        #OFFSET      : 380
        #SPECTRUM    : Spectral Data Starts Here
        \(values)
        #ENDOFDATA   :
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eels-feature-\(UUID().uuidString).msa")
        try msa.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor private func room() async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "feature.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try Self.core(), coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        session.setFitModel(.mlls)
        return session
    }

    private static func planted(_ i: Int) -> Double {
        let total = EELSControlsTests.amounts.map(\.amount).reduce(0, +)
        return 100 * EELSControlsTests.amounts[i].amount / total
    }

    // MARK: On the axis

    /// A reference on the core loss's channels: its own channels where they meet, linear between them, 0 outside its energy range. Red under: no `onAxis`.
    func testAReferenceIsPutOnTheCoreLossChannels() {
        let curve = EELSPlotCurve(origin: 101, step: 2, counts: [2, 4, 8])        // 101, 103, 105 eV
        XCTAssertEqual(EELSReferenceCompute.onAxis(curve, offsetEV: 100, scaleEV: 1, channels: 8), [0, 2, 3, 4, 6, 8, 0, 0])
        XCTAssertEqual(EELSReferenceCompute.onAxis(EELSPlotCurve(origin: 0, step: 1, counts: [5]), offsetEV: 0, scaleEV: 1, channels: 2), [5, 0])
    }

    // MARK: The fit

    /// With a reference, the MLLS fit the room lands is the kit's MLLS with that reference, value for value (the region rows, a pixel of the map), and the
    /// planted composition comes back within the existing MLLS test's half an at%. Without it (today's room: the references were left out) the feature
    /// goes into N K and the composition misses. Red under: the reference not passed to the kit (the rows equal the fit without it).
    @MainActor func testTheMLLSFitUsesTheReferences() async throws {
        let session = try await room()
        await session.fit()?.value
        await session.settled()
        let without = session.regionRows
        let qualityWithout = session.resultQuality?.reducedChiSquared
        XCTAssertEqual(without.count, 3, session.failure ?? session.fitRefusal ?? "no fit")

        let url = try Self.referenceFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let reference = try XCTUnwrap(session.importReference(url: url), session.referenceNotice ?? "")
        XCTAssertEqual(session.fitState, .stale, "a new reference stales the MLLS fit")
        await session.fit()?.value
        await session.settled()
        XCTAssertEqual(session.fitState, .current)
        let with = session.regionRows

        // The kit, called directly with the same reference on the core loss's channels.
        let core = try XCTUnwrap(session.workingCoreLoss)
        let shape = EELSReferenceCompute.onAxis(reference.curve, offsetEV: core.energyOffsetEV, scaleEV: core.energyScaleEV, channels: core.channels)
        let options = EELSFitCompute.mllsOptions(edgeWindows: session.fitWindows, references: [shape])
        XCTAssertEqual(options.references, [shape])
        let summed = try core.sum(mask: [Bool](repeating: true, count: core.pixelCount))
        let kit = try EELSMLLS.fit(coreLoss: summed, edges: session.fittableEdges, microscope: EELSControlsTests.microscope, lowLoss: nil, options: options)
        XCTAssertEqual(kit.pixels[0].references.count, 1)
        for (g, row) in with.enumerated() {
            XCTAssertEqual(row.intensity, kit.pixels[0].intensities[g].value, "\(row.title): the kit's MLLS intensity with the reference")
            XCTAssertEqual(row.intensityStd, kit.pixels[0].intensities[g].standardError)
        }
        let perPixel = try EELSMLLS.fit(coreLoss: core, edges: session.fittableEdges, microscope: EELSControlsTests.microscope, lowLoss: nil, options: options)
        let tile = try XCTUnwrap(session.modelTiles.first { $0.id == "edge-N-K1" })
        XCTAssertEqual(tile.values[5], perPixel.pixels[5].intensities[1].value)
        // The fitted amplitude of the feature is its planted size (peak 70 counts per pixel at pixel 0, summed over the 12 pixels: 70 x 18.6 = 1302) to 1 %:
        // the two-area exponent is the method's approximation, as for the composition (measured 1296.3).
        let plantedAmplitude = Self.bumpPeak * (0..<12).map { 1 + 0.1 * Double($0) }.reduce(0, +)
        XCTAssertEqual(kit.pixels[0].references[0].value, plantedAmplitude, accuracy: 0.01 * plantedAmplitude)

        // The before/after table (written first when MACEM_SHOT_DIR is set, so a failing run still leaves its numbers).
        var lines = ["case\tbefore\tafter\ttruth"]
        for i in 0..<min(3, with.count, without.count) {
            lines.append("\(with[i].title) at%\t\(String(describing: without[i].atomicPercent))\t\(String(describing: with[i].atomicPercent))\t\(Self.planted(i))")
            lines.append("\(with[i].title) I\t\(String(describing: without[i].intensity))\t\(String(describing: with[i].intensity))\tkit \(kit.pixels[0].intensities[i].value)")
        }
        lines.append("feature amplitude\t-\t\(kit.pixels[0].references[0].value)\t\(Self.bumpPeak * 18.6)")
        lines.append("fit quality chi2r\t\(String(describing: qualityWithout))\t\(String(describing: session.resultQuality?.reducedChiSquared))\t-")
        lines.append("footer\t\(session.fitFooter)")
        if let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] {
            try lines.joined(separator: "\n").write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-98c2-numbers.tsv"), atomically: true, encoding: .utf8)
        }

        for i in 0..<3 {
            let after = try XCTUnwrap(with[i].atomicPercent)
            XCTAssertEqual(after, Self.planted(i), accuracy: 0.5, "\(with[i].title) with the reference")
        }
        XCTAssertGreaterThan(abs(try XCTUnwrap(without[1].atomicPercent) - Self.planted(1)), 1, "without the reference the feature biases N K")

        // The method records it.
        XCTAssertTrue(try XCTUnwrap(session.resultsCSV).contains("1 reference"), session.fitFooter)
        XCTAssertTrue(try XCTUnwrap(session.methodJSON).contains(reference.name), "the method JSON names the reference")

        // Removing the reference stales MLLS again.
        session.removeReference(reference.id)
        XCTAssertEqual(session.fitState, .stale)
    }

    /// The exact fit takes no reference: a reference added under the exact model leaves its fit current. Red under: references in the exact fit's signature.
    @MainActor func testTheExactFitIgnoresReferences() async throws {
        let session = try await room()
        session.setFitModel(.exactNNLS)
        await session.fit()?.value
        await session.settled()
        XCTAssertEqual(session.fitState, .current, session.failure ?? session.fitRefusal ?? "")
        let url = try Self.referenceFile()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(session.importReference(url: url))
        XCTAssertEqual(session.fitState, .current)
        XCTAssertEqual(EELSReference.note(for: .exactNNLS), "References enter only the MLLS fit: pick MLLS under Fitting to fit with them.")
        XCTAssertTrue(EELSReference.note(for: .mlls).hasPrefix("References enter the MLLS fit"))
        XCTAssertFalse(EELSReference.note(for: .mlls).contains("change no number"))
    }

    /// A reference taken from a region over a picked edge is that edge again (nearly the same column): MLLS is blocked with a sentence naming both, until the
    /// edge is set Off or the reference removed. Red under: the two fitted side by side (the edge's amount split arbitrarily with the reference).
    @MainActor func testARegionReferenceOfAPickedEdgeBlocksTheFit() async throws {
        let session = try await room()
        let reference = try XCTUnwrap(session.addReferenceFromRegion(edge: .nitrogenK), session.referenceNotice ?? "")
        let why = try XCTUnwrap(session.fitBlocker)
        XCTAssertEqual(why, "\(reference.name) is the N K edge taken from a region, and N K is also picked: the fit cannot tell them apart. "
                       + "Remove the reference or set N K Off.")
        session.toggleEdge(.nitrogenK)
        XCTAssertFalse(session.pickedEdges.contains(.nitrogenK))
        XCTAssertNil(session.fitBlocker, "N K Off: the reference stands for it")
        session.toggleEdge(.nitrogenK)
        session.removeReference(reference.id)
        XCTAssertNil(session.fitBlocker)
    }

    /// A reference with no counts inside the MLLS window cannot be fitted (the kit's column would be all zeros): Fit is blocked with a sentence naming it.
    @MainActor func testAReferenceOutsideTheWindowBlocksTheFit() async throws {
        let session = try await room()
        let curve = EELSPlotCurve(origin: 10, step: 1, counts: [1, 2, 3])
        let msa = """
        #FORMAT      : EMSA/MAS Spectral Data File
        #VERSION     : 1.0
        #TITLE       : far
        #NPOINTS     : 3
        #NCOLUMNS    : 1
        #XUNITS      : eV
        #DATATYPE    : Y
        #XPERCHAN    : \(curve.step)
        #OFFSET      : \(curve.origin)
        #SPECTRUM    : Spectral Data Starts Here
        1
        2
        3
        #ENDOFDATA   :
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("far-\(UUID().uuidString).msa")
        try msa.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let far = try XCTUnwrap(session.importReference(url: url))
        let why = try XCTUnwrap(session.fitBlocker)
        XCTAssertTrue(why.hasPrefix("\(far.name) has no counts in the MLLS window"), why)
        session.setFitModel(.exactNNLS)
        XCTAssertNil(session.fitBlocker, "the exact fit takes no reference")
    }
}
