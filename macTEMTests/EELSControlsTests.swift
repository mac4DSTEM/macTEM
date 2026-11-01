//
//  EELSControlsTests.swift
//  The EELS room's three controls that were shown before they worked: the Deconvolve stage (SpectroKit's Fourier-ratio, Fourier-log and
//  Richardson-Lucy), the MLLS fit model next to the exact NNLS fit, and the periodic table's "Fit only" role.
//
//  THE TRUTH: the planted low loss of `EELSRoomTests` (4 x 3 pixels, a zero-loss core of I_0 = 2000 counts at 0 eV, a fixed threshold of 2.5 eV) and a
//  planted core loss on the same scan: 700 channels of 1 eV from 200 eV, each pixel a power law 1e10 E^-3 (counts per channel) plus the kit's own C K, N K
//  and O K cross sections (barn/eV x channel width) in the amounts 2 : 1 : 1.5, the whole spectrum scaled by (1 + 0.1 k) at pixel k. The amounts are
//  the planted composition (C 44.4, N 22.2, O 33.3 at%). The room has no arithmetic of its own: every number is checked against the kit's call on the
//  same inputs, and the planted composition is the sanity check.
//

import XCTest
import ShellSpectroscopy
import SpectroCore
import SpectroEELS
import TEMCore
import TEMSession
import ShellEDXModel
import SpectroEDX
@testable import macTEM

nonisolated final class EELSControlsTests: XCTestCase {

    static let microscope = EELSMicroscope(beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10)
    static let amounts: [(edge: CoreLossEdge, amount: Double)] = [(.carbonK, 2), (.nitrogenK, 1), (.oxygenK, 1.5)]

    static func core() throws -> CoreLossSpectrumImage {
        let nx = EELSRoomTests.nx, ny = EELSRoomTests.ny, channels = 700
        let energies = (0..<channels).map { 200 + Double($0) }
        var shape = energies.map { 1e10 * pow($0, -3) }
        // One scale for every edge: the C K edge 30 % of the background 16 eV above its onset.
        let carbon = try EELSEdgeQuantification.differentialCrossSection(edge: .carbonK, microscope: microscope, energiesEV: [300]).barnPerEV[0]
        let scale = 0.3 * 1e10 * pow(300, -3) / carbon / 2
        for (edge, amount) in amounts {
            let sigma = try EELSEdgeQuantification.differentialCrossSection(edge: edge, microscope: microscope, energiesEV: energies).barnPerEV
            for c in 0..<channels { shape[c] += amount * scale * sigma[c] }
        }
        var counts = [Double](repeating: 0, count: nx * ny * channels)
        for p in 0..<(nx * ny) { for c in 0..<channels { counts[p * channels + c] = shape[c] * (1 + 0.1 * Double(p)) } }
        return try CoreLossSpectrumImage(nx: nx, ny: ny, channels: channels, counts: counts, energyOffsetEV: 200, energyScaleEV: 1)
    }

    @MainActor private func room(core withCore: Bool = true) async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "controls.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: withCore ? try Self.core() : nil, coreLossOrigin: withCore ? "planted core" : nil)
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        XCTAssertNotNil(session.map, session.failure ?? "no map")
        return session
    }

    @MainActor private func pickCNO(_ session: EELSSession) {
        session.setConvolveLowLoss(false)
        for (edge, _) in Self.amounts { session.toggleEdge(edge) }
    }

    private func wholeMap(_ core: CoreLossSpectrumImage) throws -> CoreLossSpectrumImage {
        try core.sum(mask: [Bool](repeating: true, count: core.pixelCount))
    }

    // MARK: MLLS

    /// MLLS is a real fit model: picking it stales Fit, the fit that lands is the kit's MLLS (its method, its intensities on the whole map's summed core loss,
    /// exactly), the per-pixel maps are its, the planted composition comes back, and the footer and the method JSON say MLLS. Red under: the Model control
    /// a constant (the fit stays the exact one); the session calling the exact fit whatever is picked.
    @MainActor func testMLLSIsARealFitModel() async throws {
        let session = try await room()
        pickCNO(session)
        await session.fit()?.value
        await session.settled()
        XCTAssertEqual(session.model?.model, .exactNNLS, session.failure ?? session.fitRefusal ?? "")
        XCTAssertEqual(session.fitState, .current)

        session.setFitModel(.mlls)
        XCTAssertEqual(session.fitState, .stale, "a new model stales Fit")
        await session.fit()?.value
        await session.settled()
        let model = try XCTUnwrap(session.model, session.failure ?? session.fitRefusal ?? "no fit")
        XCTAssertEqual(model.model, .mlls)
        XCTAssertEqual(model.methodName, EELSMLLS.methodName)
        XCTAssertEqual(session.fitState, .current)

        // The region rows are the kit's MLLS on the summed core loss, with the options the room states.
        let core = try XCTUnwrap(session.workingCoreLoss)
        let kit = try EELSMLLS.fit(coreLoss: try wholeMap(core), edges: session.fittableEdges, microscope: Self.microscope, lowLoss: nil,
                                   options: EELSFitCompute.mllsOptions(edgeWindows: session.fitWindows))
        XCTAssertEqual(EELSFitCompute.mllsOptions(edgeWindows: session.fitWindows).startEnergyEV, session.fitWindows.map(\.backgroundEV.lowerBound).min())
        let rows = session.regionRows
        XCTAssertEqual(rows.map(\.title), ["C K", "N K", "O K"])
        for (g, row) in rows.enumerated() {
            XCTAssertEqual(row.intensity, kit.pixels[0].intensities[g].value, "\(row.title): the kit's MLLS intensity")
            XCTAssertEqual(row.intensityStd, kit.pixels[0].intensities[g].standardError)
            XCTAssertEqual(row.exponent, kit.pixels[0].exponent)
            XCTAssertNil(row.arealDensityPerNM2, "MLLS gives no areal density")
        }
        // The planted composition, to half an at%: noise-free, but the two-area estimate of r over a window the C K tail does not reach is the
        // method's approximation (measured: C 44.23 for 44.44, N 22.37 for 22.22), not exact.
        let total = Self.amounts.map(\.amount).reduce(0, +)
        for (row, planted) in zip(rows, Self.amounts) {
            XCTAssertEqual(try XCTUnwrap(row.atomicPercent, row.atomicUnavailable ?? ""), 100 * planted.amount / total, accuracy: 0.5, row.title)
        }
        // The maps are the per-pixel MLLS: pixel 5 of the C K tile is the kit's MLLS of pixel 5.
        let perPixel = try EELSMLLS.fit(coreLoss: core, edges: session.fittableEdges, microscope: Self.microscope, lowLoss: nil,
                                        options: EELSFitCompute.mllsOptions(edgeWindows: session.fitWindows))
        let tile = try XCTUnwrap(session.modelTiles.first { $0.id == "edge-C-K1" })
        XCTAssertEqual(tile.values[5], perPixel.pixels[5].intensities[0].value)
        XCTAssertEqual(tile.unit, "intensity")
        XCTAssertTrue(EELSRoomFormat.fitFooter(hasFit: true, convolved: false, model: .mlls).hasPrefix("MLLS · "))
        let json = try XCTUnwrap(session.methodJSON)
        XCTAssertTrue(json.contains("\"model\" : \"MLLS\""), json)
        XCTAssertTrue(try XCTUnwrap(session.resultsCSV).contains("# MLLS · power-law background, exponent by two areas · not convolved · no deconvolution"))
    }

    // MARK: Fit only

    /// Fit only keeps an element's edge in the model and out of the composition: the at% is over the quantified elements only, the fit is not run again
    /// (the intensities stay the same), the fit-only row says why it has no at%, its at% tile goes, and the periodic table shows the role. Red under: the role
    /// picking the edge like Quantify (O keeps an at%); a refit (Fit stale, intensities change); the role not shown.
    @MainActor func testFitOnlyKeepsTheEdgeInTheFitAndOutOfTheComposition() async throws {
        let session = try await room()
        pickCNO(session)
        await session.fit()?.value
        await session.settled()
        let before = session.regionRows
        XCTAssertEqual(before.compactMap(\.atomicPercent).count, 3, session.failure ?? session.fitRefusal ?? "")

        // Through the periodic table's right-click role (Z 8 is O).
        let actions = EELSPeriodicActions.make(session)
        actions.setRole(8, .fitOnly)
        XCTAssertEqual(session.fitOnlyElements, ["O"])
        XCTAssertEqual(EELSPeriodicActions.make(session).state(8), .fitOnly)
        XCTAssertEqual(EELSPeriodicActions.make(session).role(8), .fitOnly)
        XCTAssertEqual(session.pickedEdges.count, 3, "O K is still picked: it stays in the model")
        XCTAssertEqual(session.fitState, .current, "the composition changes, not the fit")

        let after = session.regionRows
        XCTAssertEqual(after.map(\.intensity), before.map(\.intensity), "the same fit")
        let o = try XCTUnwrap(after.first { $0.title == "O K" })
        XCTAssertTrue(o.fitOnly); XCTAssertNil(o.atomicPercent); XCTAssertEqual(o.atomicUnavailable, EELSEdgeRow.fitOnlyWords)
        XCTAssertEqual(EELSRoomFormat.atomicText(o), "fit only")
        let c = try XCTUnwrap(after.first { $0.title == "C K" }), n = try XCTUnwrap(after.first { $0.title == "N K" })
        let cI = try XCTUnwrap(c.intensity), nI = try XCTUnwrap(n.intensity)
        XCTAssertEqual(try XCTUnwrap(c.atomicPercent), 100 * cI / (cI + nI), accuracy: 1e-9, "at% of C over C and N only (the kit's composition of the two)")
        XCTAssertEqual(try XCTUnwrap(c.atomicPercent) + (n.atomicPercent ?? 0), 100, accuracy: 1e-9)
        XCTAssertNil(session.modelTiles.first { $0.id == "at-O" }, "no at% tile for a fit-only element")
        XCTAssertNotNil(session.modelTiles.first { $0.id == "at-C" })
        XCTAssertNotNil(session.modelTiles.first { $0.id == "edge-O-K1" }, "its intensity tile stays")
        XCTAssertEqual(EELSRoomFormat.pickedLine(session.pickedEdges, fitOnly: session.fitOnlyElements), "Quantify: C K 284 eV, N K 401 eV · Fit only: O K 532 eV")
        let fitJSON = try XCTUnwrap(session.methodJSON)
        XCTAssertTrue(fitJSON.contains("\"fit_only\" : [\n      \"O\"\n    ]"), fitJSON)

        // Two fit-only elements leave one quantified: no at%, and the words say why.
        actions.setRole(7, .fitOnly)
        let one = session.regionRows.first { $0.title == "C K" }
        XCTAssertNil(one?.atomicPercent); XCTAssertEqual(one?.atomicUnavailable, EELSEdgeRow.atomicNeedsTwoQuantified)
        // Quantify again brings the composition back; Off takes the role away with the edge.
        actions.setRole(7, .quantify); actions.setRole(8, .quantify)
        XCTAssertEqual(session.regionRows.compactMap(\.atomicPercent).count, 3)
        actions.setRole(8, .fitOnly); actions.setRole(8, .off)
        XCTAssertTrue(session.fitOnlyElements.isEmpty, "an element with no edge has no role")
    }

    // MARK: Deconvolution

    /// Fourier-ratio is a stage: listed once chosen, run by Run after Thickness, its core loss the kit's `fourierRatio` of the working cubes with the room's
    /// threshold, and the fit then takes that core loss, not convolved with the low loss. The method and its parameters are in the method JSON and the
    /// results CSV. Red under: the control a constant Off; the fit taking the stored core loss; the export not naming it.
    @MainActor func testFourierRatioIsAStageAndTheFitTakesItsCoreLoss() async throws {
        let session = try await room()
        pickCNO(session)
        session.setConvolveLowLoss(true)
        session.setDeconvolution(.fourierRatio)
        XCTAssertEqual(session.deconvolutionChoice, .fourierRatio)
        XCTAssertEqual(session.stages.map(\.stage), [.align, .thickness, .deconvolve, .edges, .fit])
        XCTAssertEqual(session.deconvolveState, .notRun)
        XCTAssertNotNil(session.fitBlocker, "the fit waits for the deconvolved core loss")
        XCTAssertTrue(session.canRun)
        await session.run().value
        await session.settled()
        let d = try XCTUnwrap(session.deconvolution, session.failure ?? "no deconvolution")
        XCTAssertEqual(session.deconvolveState, .current)
        let kit = try EELSDeconvolution.fourierRatio(coreLoss: try XCTUnwrap(session.workingCoreLoss), lowLoss: try XCTUnwrap(session.workingLowLoss),
                                                     options: FourierRatioOptions(threshold: .fixed(2.5)))
        XCTAssertEqual(d.coreLoss?.counts, kit.image.counts, "the kit's Fourier-ratio of the working cubes with the room's threshold")
        XCTAssertEqual(d.fwhmEV, kit.fwhmEV)
        let model = try XCTUnwrap(session.model, session.failure ?? session.fitRefusal ?? "no fit")
        XCTAssertFalse(model.convolved, "Fourier-ratio divides the low loss out: no convolution")
        XCTAssertEqual(session.modelDeconvolution?.choice, .fourierRatio)
        XCTAssertEqual(d.answered, kit.unavailable.map { $0 == nil })
        let fitted = try EELSFitCompute.fit(coreLoss: try kit.image.sum(mask: d.answered), edges: session.fittableEdges, microscope: Self.microscope, lowLoss: nil,
                                            edgeWindows: session.fitWindows)
        XCTAssertEqual(session.regionRows.map(\.intensity), (0..<3).map { fitted.intensity(pixel: 0, edge: $0) }, "the fit is of the deconvolved core loss")
        let json = try XCTUnwrap(session.methodJSON)
        XCTAssertTrue(json.contains("\"deconvolution\" : {"), json)
        XCTAssertTrue(json.contains("\"method\" : \"Fourier-ratio\""), json)
        XCTAssertTrue(json.contains("\"fwhm_eV\""), json)
        XCTAssertTrue(json.contains("\"low_loss_threshold\" : \"fixed threshold 2.5 eV\""), json)
        let csv = try XCTUnwrap(session.resultsCSV)
        XCTAssertTrue(csv.contains("# deconvolution: Fourier-ratio deconvolution (FWHM"), csv)
        XCTAssertTrue(csv.contains("· not convolved · Fourier-ratio deconvolution"), csv)
        // A new threshold stales the stage (its I₀ is cut there) and the fit with it.
        session.setThreshold(.fixed(3))
        XCTAssertEqual(session.deconvolveState, .stale)
        XCTAssertEqual(session.fitState, .stale)
    }

    /// Fourier-log and Richardson-Lucy deconvolve the low loss by each pixel's zero-loss peak, cut at the thickness map's threshold: the result is the
    /// kit's call on that peak, drawn on the spectrum and exported with the spectrum; the fit does not use it. Red under: the stage not calling the kit; a
    /// zero-loss peak cut elsewhere; the deconvolved spectrum missing from the plot.
    @MainActor func testFourierLogAndRichardsonLucyDeconvolveTheLowLossByItsZeroLossPeak() async throws {
        let session = try await room()
        let low = try XCTUnwrap(session.workingLowLoss), map = try XCTUnwrap(session.map)
        let zlp = try EELSDeconvolveCompute.zeroLoss(low, map: map)
        XCTAssertEqual(zlp.image.channels, 15, "a fixed 2.5 eV threshold on -5 eV + 0.5 eV steps stops the sum at channel 15")
        XCTAssertEqual(Array(zlp.image.counts[9...11]), [300, 1400, 300], "the zero-loss core")
        XCTAssertEqual(zlp.image.counts.reduce(0, +), 2000 * Double(low.pixelCount), "I₀ of every pixel and nothing above the threshold")

        session.setDeconvolution(.fourierLog)
        await session.deconvolve()?.value
        await session.settled()
        let log = try XCTUnwrap(session.deconvolution, session.failure ?? "")
        let kitLog = try EELSDeconvolution.fourierLog(low, zeroLoss: zlp.image)
        XCTAssertEqual(log.lowLoss?.counts, kitLog.image.counts)
        XCTAssertNil(log.coreLoss)
        XCTAssertNotNil(session.plot?.lowDeconvolved, "drawn on the spectrum")
        XCTAssertTrue(try XCTUnwrap(session.spectrumCSV).contains("low_loss_deconvolved,"))
        XCTAssertTrue(try XCTUnwrap(session.methodJSON).contains("\"method\" : \"Fourier-log\""))

        session.setDeconvolution(.richardsonLucy(iterations: 5))
        XCTAssertEqual(session.deconvolveState, .stale, "a new method stales the stage")
        XCTAssertNil(session.shownDeconvolvedLow, "the old method's spectrum is not drawn for the new one")
        await session.deconvolve()?.value
        await session.settled()
        let rl = try XCTUnwrap(session.deconvolution, session.failure ?? "")
        let psf = try EELSDeconvolveCompute.zeroLoss(low, map: map, channels: low.channels)
        let kitRL = try EELSDeconvolution.richardsonLucy(low, psf: psf.image, options: RichardsonLucyOptions(iterations: 5))
        XCTAssertEqual(rl.lowLoss?.counts, kitRL.image.counts)
        XCTAssertEqual(rl.methodName, "Richardson-Lucy deconvolution, 5 iterations")
        let json = try XCTUnwrap(session.methodJSON)
        XCTAssertTrue(json.contains("\"iterations\" : 5"), json)
        XCTAssertFalse(EELSDeconvolutionChoice.richardsonLucy(iterations: 5).feedsTheFit)
        XCTAssertEqual(session.fitCoreLoss?.counts, session.workingCoreLoss?.counts, "the fit takes the stored core loss")
    }

    /// A deconvolved pixel the kit could not answer is a row of zeros in its image: a region sums only the answered pixels. Red under: the zeros summed in.
    func testARegionSumsOnlyThePixelsTheDeconvolutionAnswered() {
        let region = EDXRegion.rectangle(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1))
        XCTAssertEqual(EELSRegionCompute.mask(region, nx: 2, ny: 2, answered: nil), [true, true, false, false])
        XCTAssertEqual(EELSRegionCompute.mask(region, nx: 2, ny: 2, answered: [true, false, true, true]), [true, false, false, false])
        XCTAssertEqual(EELSRegionCompute.mask(.wholeMap, nx: 2, ny: 2, answered: [false, true, true, true]), [false, true, true, true])
    }

    /// A method the file cannot take is refused with its sentence and the control stays Off.
    @MainActor func testAMethodTheFileCannotTakeIsRefused() async throws {
        let session = try await room(core: false)
        session.setDeconvolution(.fourierRatio)
        XCTAssertEqual(session.deconvolutionChoice, .off)
        XCTAssertEqual(session.deconvolutionNotice, "Fourier-ratio needs a core loss to deconvolve.")
        XCTAssertEqual(session.stages.map(\.stage), [.align, .thickness, .edges, .fit], "Off is not a stage")
        session.setDeconvolution(.fourierLog)
        XCTAssertEqual(session.deconvolutionChoice, .fourierLog); XCTAssertNil(session.deconvolutionNotice)
    }

    // MARK: The words

    /// No control promises "the next slice" any more, and each of the three is bound to the session.
    func testNoControlPromisesTheNextSlice() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let inspector = try String(contentsOf: root.appendingPathComponent("macTEM/UI/EELSRoomInspector.swift"), encoding: .utf8)
        XCTAssertFalse(inspector.contains("next slice"))
        XCTAssertFalse(inspector.contains("selection: .constant("), "no control bound to a constant")
        XCTAssertTrue(inspector.contains("session.setDeconvolution("))
        XCTAssertTrue(inspector.contains("session.setFitModel("))
        XCTAssertTrue(inspector.contains("session.setFitOnly("))
    }
}
