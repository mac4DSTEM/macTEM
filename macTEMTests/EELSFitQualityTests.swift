//
//  EELSFitQualityTests.swift
//  The EELS results' σ on at% and wt%, the fit quality (the kit's RSS, Pearson's χ²/dof) and the Fitting section's Fit to.
//
//  THE TRUTH: the planted low and core loss of `EELSControlsTests` (C K, N K and O K in the amounts 2 : 1 : 1.5 on a power law). The σ is checked against
//  SpectroKit's own first-order propagation (`EDXQuantification.quantifyWithSigma`, Cliff-Lorimer with k = the atomic masses, which is the EELS
//  composition: wt% ∝ A_i I_i, at% ∝ I_i) on the kit's EELS intensities and their σ; the RSS and the MLLS degrees of freedom are the kit's fields; the
//  channels the χ² sums over are checked by summing the squared residuals over them back to the kit's RSS.
//

import XCTest
import AppKit
import SwiftUI
import SpectroCore
import SpectroEDX
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSFitQualityTests: XCTestCase {

    @MainActor private func room() async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "quality.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        XCTAssertNotNil(session.map, session.failure ?? "no map")
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        return session
    }

    private func wholeMap(_ core: CoreLossSpectrumImage) throws -> CoreLossSpectrumImage {
        try core.sum(mask: [Bool](repeating: true, count: core.pixelCount))
    }

    /// The kit's EDX first-order sigma on the same amounts: Cliff-Lorimer with k = the EELS atomic masses gives the EELS composition.
    private func kitSigma(intensities: [Double], sigmas: [Double], symbols: [String]) throws -> EDXQuantificationSigma {
        let k = symbols.map { EELSQuantification.atomicMasses[$0]! }
        let setup = EDXQuantificationSetup(elements: symbols, method: .cliffLorimer(kFactors: k, thicknessNm: nil))
        return try EDXQuantification.quantifyWithSigma(intensities: intensities, intensitySigmas: sigmas, setup: setup)
    }

    // MARK: σ on the composition

    /// The propagation is the kit's own first-order rule: equal to `EDXQuantification.quantifyWithSigma` (central differences) on hand amounts, at% and
    /// wt%, and the percentages it propagates are the kit's EELS composition. Red under: a σ that leaves out the other elements' terms, or weights
    /// wt% like at%.
    func testCompositionSigmaIsTheKitsFirstOrderRule() throws {
        let symbols = ["C", "N", "O"], amounts = [2000.0, 1000, 1500], sigmas = [45.0, 32, 39]
        let kit = try kitSigma(intensities: amounts, sigmas: sigmas, symbols: symbols)
        let at = try XCTUnwrap(EELSCompositionSigma.percentSigmas(amounts: amounts, sigmas: sigmas, weights: [1, 1, 1]))
        let masses = symbols.map { EELSQuantification.atomicMasses[$0]! }
        let wt = try XCTUnwrap(EELSCompositionSigma.percentSigmas(amounts: amounts, sigmas: sigmas, weights: masses))
        for i in 0..<3 {
            XCTAssertEqual(kit.pixel.atomicPercent[i], 100 * amounts[i] / 4500, accuracy: 1e-9, "the CL mapping is the EELS at%")
            XCTAssertEqual(at[i], kit.atomicSigma[i], accuracy: 1e-6 * kit.atomicSigma[i], "\(symbols[i]) at% σ")
            XCTAssertEqual(wt[i], kit.weightSigma[i], accuracy: 1e-6 * kit.weightSigma[i], "\(symbols[i]) wt% σ")
        }
        // A missing σ is no σ, never a σ of 0.
        XCTAssertNil(EELSCompositionSigma.percentSigmas(amounts: amounts, sigmas: [45, nil, 39], weights: [1, 1, 1]))
        XCTAssertNil(EELSCompositionSigma.percentSigmas(amounts: [0, 0], sigmas: [1, 1], weights: [1, 1]))
    }

    /// The region rows carry σ on at% and wt%, from the kit's intensities and σ of the summed spectrum through the kit's propagation; the at% cell and
    /// the results CSV show them. Red under: rows without σ; a σ from another edge's amount.
    @MainActor func testTheRegionRowsCarryTheSigmaOfTheComposition() async throws {
        let session = try await room()
        await session.fit()?.value
        await session.settled()
        let rows = session.regionRows
        XCTAssertEqual(rows.compactMap(\.atomicPercent).count, 3, session.failure ?? session.fitRefusal ?? "")
        let core = try XCTUnwrap(session.workingCoreLoss)
        let fit = try EELSModelFit.fit(coreLoss: try wholeMap(core), edges: session.fittableEdges, microscope: EELSControlsTests.microscope, lowLoss: nil,
                                       edgeWindows: session.fitWindows)
        let intensities = (0..<3).map { fit.pixels[0][$0].intensity! }, sigmas = (0..<3).map { fit.pixels[0][$0].intensityStd! }
        let kit = try kitSigma(intensities: intensities, sigmas: sigmas, symbols: ["C", "N", "O"])
        for (i, row) in rows.enumerated() {
            let at = try XCTUnwrap(row.atomicSigma, row.title), wt = try XCTUnwrap(row.weightSigma, row.title)
            XCTAssertEqual(at, kit.atomicSigma[i], accuracy: 1e-5 * kit.atomicSigma[i], row.title)
            XCTAssertEqual(wt, kit.weightSigma[i], accuracy: 1e-5 * kit.weightSigma[i], row.title)
            XCTAssertTrue(EELSRoomFormat.atomicText(row).contains(" ± "), EELSRoomFormat.atomicText(row))
            XCTAssertTrue(EELSRoomFormat.weightText(row).contains(" ± "), EELSRoomFormat.weightText(row))
        }
        let csv = try XCTUnwrap(session.resultsCSV)
        XCTAssertTrue(csv.contains("atomic_percent,atomic_percent_sigma,weight_percent,weight_percent_sigma"), csv)
        XCTAssertTrue(csv.contains("# fit quality: RSS "), csv)
        // Fit only: one quantified element left, no composition and no σ.
        session.setFitOnly("N", true); session.setFitOnly("O", true)
        XCTAssertTrue(session.regionRows.allSatisfy { $0.atomicSigma == nil && $0.weightSigma == nil })
        let json = try XCTUnwrap(session.methodJSON)
        XCTAssertTrue(json.contains("\"composition_sigma\""), json)
    }

    /// On a Fourier-ratio deconvolved core loss the counts are not Poisson: the exact fit's composition carries no σ and the quality no χ², only the RSS.
    /// Red under: a σ or a χ² shown on deconvolved data.
    @MainActor func testADeconvolvedCoreLossCarriesNoSigmaAndNoChiSquared() async throws {
        let session = try await room()
        session.setDeconvolution(.fourierRatio)
        await session.run().value
        await session.settled()
        session.setFitOn(.deconvolved)
        XCTAssertEqual(session.fitOn, .deconvolved, session.fitOnNotice ?? "")
        await session.fit()?.value
        await session.settled()
        let rows = session.regionRows
        XCTAssertEqual(rows.compactMap(\.atomicPercent).count, 3, session.failure ?? session.fitRefusal ?? "")
        XCTAssertTrue(rows.allSatisfy { $0.atomicSigma == nil && $0.weightSigma == nil })
        let q = try XCTUnwrap(session.regionQuality)
        XCTAssertNil(q.reducedChiSquared)
        XCTAssertEqual(q.chiSquaredUnavailable, EELSFitQuality.notCounts)
    }

    func testPercentCellsCarryTheirSigma() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRoomFormat.percent(44.4444, 0.3123, locale: en), "44.44 ± 0.31")
        XCTAssertEqual(EELSRoomFormat.percent(44.4444, 2.6, locale: en), "44.4 ± 2.6")
        XCTAssertEqual(EELSRoomFormat.percent(44.4444, 13, locale: en), "44 ± 13")
        XCTAssertEqual(EELSRoomFormat.percent(44.4444, nil, locale: en), "44.4")
        let row = EELSEdgeRow(id: "C-K", title: "C K", onsetEV: 284, intensity: 2000, arealDensityPerNM2: nil, atomicPercent: 44.44, weightPercent: 40.1,
                              unavailable: nil, intensityStd: 45, atomicSigma: 0.62, weightSigma: 0.71)
        XCTAssertEqual(EELSRoomFormat.atomicText(row, locale: en), "44.44 ± 0.62")
        XCTAssertEqual(EELSRoomFormat.weightText(row, locale: en), "40.10 ± 0.71")
    }

    // MARK: Fit quality

    /// Pearson's χ²/dof on a hand case, and its refusals.
    func testPearsonReducedChiSquared() {
        XCTAssertEqual(try EELSFitQuality.pearsonReduced(counts: [10, 12, 9], model: [10, 10, 10], channels: [0, 1, 2], parameters: 1).get(), 0.25, accuracy: 1e-15)
        XCTAssertEqual(EELSFitQuality.pearsonReduced(counts: [10, 12, 9], model: [10, -1, 10], channels: [0, 1, 2], parameters: 1),
                       .failure(EELSFitQuality.Refusal(text: EELSFitQuality.modelNotPositive)))
        XCTAssertEqual(EELSFitQuality.pearsonReduced(counts: [10, 12], model: [10, 10], channels: [0, 1], parameters: 2),
                       .failure(EELSFitQuality.Refusal(text: EELSFitQuality.noFreedom)))
        let q = EELSFitQuality(rss: 123_456, channels: 315, parameters: 3, reducedChiSquared: 1.0432)
        XCTAssertEqual(EELSRoomFormat.fitQuality(q, locale: Locale(identifier: "en_US")), "RSS 1.235e5 · χ²ᵣ 1.04 (Pearson, 312 dof)")
    }

    /// The exact fit's quality: the RSS is the kit's, the channels are the edges' signal windows (their squared residuals sum back to the kit's RSS), one
    /// intensity per edge, and the χ² is Pearson's over them. Shown under Fitting and in the footer of the shown region. Red under: no quality; channels
    /// that are not where the kit sums its residual.
    @MainActor func testTheExactFitQualityIsTheKitsResidual() async throws {
        let session = try await room()
        await session.fit()?.value
        await session.settled()
        let q = try XCTUnwrap(session.regionQuality, session.failure ?? session.fitRefusal ?? "no quality")
        XCTAssertEqual(session.resultQuality, q, "the whole map's while no region is selected")
        let core = try wholeMap(try XCTUnwrap(session.workingCoreLoss))
        let kit = try EELSModelFit.fit(coreLoss: core, edges: session.fittableEdges, microscope: EELSControlsTests.microscope, lowLoss: nil,
                                       edgeWindows: session.fitWindows)
        XCTAssertEqual(q.rss, try XCTUnwrap(kit.residualSumOfSquares[0]), "the kit's RSS")
        XCTAssertEqual(q.parameters, 3)
        let channels = EELSFitQuality.fittedChannels(.exactNNLS(kit), core: core)
        XCTAssertEqual(q.channels, channels.count)
        let ranges = try XCTUnwrap(kit.fitRangeEV)
        XCTAssertEqual(channels.count, ranges.map { Int(($0.upperBound - $0.lowerBound).rounded()) + 1 }.reduce(0, +), "1 eV channels, each window inclusive")
        let model = try XCTUnwrap(kit.modelCurve(pixel: 0))
        let resummed = channels.map { pow(core.counts[$0] - model[$0], 2) }.reduce(0, +)
        XCTAssertEqual(resummed, q.rss, accuracy: 1e-9 * max(q.rss, 1), "the channels are where the kit sums its residual")
        let chi = channels.map { pow(core.counts[$0] - model[$0], 2) / model[$0] }.reduce(0, +) / Double(channels.count - 3)
        XCTAssertEqual(try XCTUnwrap(q.reducedChiSquared, q.chiSquaredUnavailable ?? ""), chi, accuracy: 1e-12 * max(chi, 1))
        let json = try XCTUnwrap(session.methodJSON)
        XCTAssertTrue(json.contains("\"fit_quality\""), json)
        XCTAssertTrue(json.contains("\"chi2_reduced_pearson\""), json)
    }

    /// The results panel and the Fitting section drawn offscreen after an MLLS fit (a borderless window that is never shown): the at% and wt% cells with
    /// their σ, the footer with the fit quality, the Fit to row and the Fit quality value row. The picture goes to `MACEM_SHOT_DIR` when the runner sets
    /// it (`TEST_RUNNER_MACEM_SHOT_DIR`), for the pull request; the test itself checks that both views draw. Red under: a panel that does not draw.
    @MainActor func testTheResultsAndFittingDrawWithSigmaAndQuality() async throws {
        let session = try await room()
        session.setFitModel(.mlls)
        session.setFitTo(800)
        await session.fit()?.value
        await session.settled()
        XCTAssertNotNil(session.resultQuality, session.failure ?? session.fitRefusal ?? "")
        func render(_ view: some View, size: NSSize) throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        let panel = try render(EELSResultsPanel(session: session), size: NSSize(width: 560, height: 300))
        let fitting = try render(ScrollView { EELSFittingSection(session: session).padding(.horizontal, 12) }, size: NSSize(width: 320, height: 520))
        XCTAssertGreaterThan(panel.pixelsWide, 0); XCTAssertGreaterThan(fitting.pixelsWide, 0)
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        for (name, rep) in [("macTEM-98-results.png", panel), ("macTEM-98-fitting.png", fitting)] {
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }

    /// MLLS: Fit to ends the window (the kit's `endEnergyEV`), stales the fit, the rows are the kit's MLLS on that window and the quality is its RSS and
    /// degrees of freedom. A Fit to under the last edge or past the axis is refused with its sentence. Red under: Fit to not handed to the kit; the
    /// fit not staled; a refused value kept.
    @MainActor func testFitToEndsTheMLLSWindow() async throws {
        let session = try await room()
        session.setFitModel(.mlls)
        await session.fit()?.value
        await session.settled()
        XCTAssertEqual(session.fitState, .current, session.failure ?? session.fitRefusal ?? "")

        session.setFitTo(800)
        XCTAssertEqual(session.fitToEV, 800); XCTAssertNil(session.fitToNotice)
        XCTAssertEqual(session.fitState, .stale, "a new Fit to stales an MLLS fit")
        await session.fit()?.value
        await session.settled()
        let options = EELSFitCompute.mllsOptions(edgeWindows: session.fitWindows, fitToEV: 800)
        XCTAssertEqual(options.endEnergyEV, 800)
        let core = try wholeMap(try XCTUnwrap(session.workingCoreLoss))
        let kit = try EELSMLLS.fit(coreLoss: core, edges: session.fittableEdges, microscope: EELSControlsTests.microscope, lowLoss: nil, options: options)
        XCTAssertEqual(kit.windowEV.upperBound, 800)
        guard case .mlls(let region) = try XCTUnwrap(session.regionModel) else { return XCTFail("not MLLS") }
        XCTAssertEqual(region.windowEV, kit.windowEV)
        XCTAssertEqual(session.regionRows.map(\.intensity), kit.pixels[0].intensities.map(\.value))
        let q = try XCTUnwrap(session.regionQuality)
        XCTAssertEqual(q.rss, try XCTUnwrap(kit.pixels[0].residualSumOfSquares))
        XCTAssertEqual(q.degreesOfFreedom, kit.pixels[0].degreesOfFreedom)
        XCTAssertEqual(q.channels, kit.windowChannels.count)
        XCTAssertTrue(try XCTUnwrap(session.methodJSON).contains("\"fit_to_eV\" : 800"))

        session.setFitTo(500)
        XCTAssertNil(session.fitToEV)
        XCTAssertEqual(session.fitToNotice, "Fit to must be above the last edge onset (532 eV): the axis end is used.")
        session.setFitTo(5000)
        XCTAssertNil(session.fitToEV)
        XCTAssertEqual(session.fitToNotice, "Fit to is past the end of the core-loss axis (899 eV): the axis end is used.")
        session.setFitTo(nil)
        XCTAssertNil(session.fitToNotice)
        // The exact fit does not take Fit to: changing it leaves an exact fit current.
        session.setFitModel(.exactNNLS)
        await session.fit()?.value
        await session.settled()
        session.setFitTo(850)
        XCTAssertEqual(session.fitState, .current, "the exact fit uses its signal windows")
    }
}
