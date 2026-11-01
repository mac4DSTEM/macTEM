//
//  EELSRefusalWordsTests.swift
//  The EELS room's refusals as sentences (SpectroKit's EELS errors carry no text), the deconvolution's unanswered pixels named with their reason,
//  and the elements the kit's MLLS composition counts as not detected (amount ≤ 0) shown in the table, the footer, the tiles and the CSV.
//
//  THE TRUTH: a planted core loss (a power law plus the kit's own C K, N K and O K cross sections, N planted at a negative amount) whose MLLS fit gives
//  N an amount below zero, so the kit flags it `notDetected`; the per-pixel reasons are planted arrays of `EELSUnavailable`.
//

import XCTest
import SpectroCore
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSRefusalWordsTests: XCTestCase {

    // MARK: the sentences

    /// noPeakWidth names pixel 0's tail and what to do; every kit error the room can meet gets a sentence, never the bare case name; a LocalizedError
    /// keeps its own text. Red under: the raw `"\(error)"` back.
    func testTheKitErrorsBecomeSentences() {
        let noWidth = EELSErrorWords.sentence(for: EELSDeconvolutionError.noPeakWidth)
        XCTAssertTrue(noWidth.hasPrefix("Pixel 0's low-loss tail is unusable"), noWidth)
        XCTAssertTrue(noWidth.contains("Fourier-log or Richardson-Lucy"), noWidth)
        let errors: [Error] = [
            EELSDeconvolutionError.noPeakWidth, EELSDeconvolutionError.invalidFWHM(.nan), EELSDeconvolutionError.tooFewChannels(1),
            EELSDeconvolutionError.shapeMismatch(expected: 4, got: 6), EELSDeconvolutionError.fftSetup(size: 7),
            EELSAlignmentError.emptyAfterCrop, EELSAlignmentError.signalRangeOutsideAxis(fromEV: -5, toEV: 5), EELSAlignmentError.nonFiniteShift(pixel: 3),
            EELSThicknessError.searchWindowTooShort(channels: 4), EELSThicknessError.invalidMeanFreePath("λ is zero"),
            EELSThicknessError.invalidFixedThreshold(-40),
            EELSModelError.lowLossAxisHasNoZero, EELSModelError.emptyMask, EELSModelError.invalidMicroscope, EELSModelError.fitDidNotConverge(pixel: 2),
            EELSMLLSError.invalidExponent, EELSMLLSError.invalidReference(index: 0),
            EELSUnavailable.nonFiniteResult, EnergyAxisError.notANumber,
        ]
        for error in errors {
            let s = EELSErrorWords.sentence(for: error)
            XCTAssertNotEqual(s, "\(error)", "raw: \(error)")
            XCTAssertFalse(s.contains("\(error)"), "\(s) carries the case name of \(error)")
            XCTAssertTrue(s.first?.isUppercase ?? false, s)
            XCTAssertTrue(s.hasSuffix("."), s)
        }
        XCTAssertEqual(EELSErrorWords.sentence(for: EELSDeconvolveRefusal.needs("Run the Thickness stage first.")), "Run the Thickness stage first.")
        // A window refusal keeps the sentence the Fitting section shows.
        XCTAssertEqual(EELSErrorWords.sentence(for: EELSModelError.backgroundWindowEmpty), EELSWindowPlan.sentence(for: EELSModelError.backgroundWindowEmpty))
    }

    // MARK: unanswered pixels

    /// A pixel the deconvolution left unanswered (`nonFiniteResult`: the low-loss tail's continuation) is named in the Deconvolve readout with the count
    /// per reason, and in the map readout under the pointer. Red under: a bare count with no reason; the readout silent on such a pixel.
    func testAnUnansweredPixelSaysWhy() {
        let unavailable: [EELSUnavailable?] = [nil, .nonFiniteResult, nil, .noThreshold, .nonFiniteResult, nil]
        XCTAssertEqual(EELSDeconvolveCompute.unansweredLine(unavailable),
                       "3 px unanswered (2: the low-loss tail's power-law continuation is not finite; 1: the zero-loss threshold has no value here)")
        XCTAssertNil(EELSDeconvolveCompute.unansweredLine([nil, nil]))
        XCTAssertEqual(EELSDeconvolveCompute.reason(unavailable, pixel: 1), "the low-loss tail's power-law continuation is not finite")
        XCTAssertNil(EELSDeconvolveCompute.reason(unavailable, pixel: 0))
        XCTAssertNil(EELSDeconvolveCompute.reason(unavailable, pixel: 99))
        XCTAssertNil(EELSDeconvolveCompute.reason(nil, pixel: 1))
        let tile = EELSMapTile(id: "tOverLambda", title: "t/λ", unit: "", width: 3, height: 2, values: [0.1, .nan, 0.3, 0.4, .nan, 0.6], version: 1, footer: nil)
        let readout = EELSRoomFormat.readout(x: 1, y: 0, tiles: [tile], refusal: nil,
                                             unanswered: EELSDeconvolveCompute.reason(unavailable, pixel: 1), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(readout, "row 0 · col 1 · deconvolution: no answer, the low-loss tail's power-law continuation is not finite")
    }

    // MARK: not detected

    /// A core loss with N planted below zero.
    private static func plantedCore() throws -> CoreLossSpectrumImage {
        let microscope = EELSControlsTests.microscope
        let nx = 2, ny = 1, channels = 700
        let energies = (0..<channels).map { 200 + Double($0) }
        var shape = energies.map { 1e10 * pow($0, -3) }
        let carbon = try EELSEdgeQuantification.differentialCrossSection(edge: .carbonK, microscope: microscope, energiesEV: [300]).barnPerEV[0]
        let scale = 0.3 * 1e10 * pow(300, -3) / carbon / 2
        for (edge, amount) in [(CoreLossEdge.carbonK, 2.0), (.nitrogenK, -0.4), (.oxygenK, 1.5)] {
            let sigma = try EELSEdgeQuantification.differentialCrossSection(edge: edge, microscope: microscope, energiesEV: energies).barnPerEV
            for c in 0..<channels { shape[c] += amount * scale * sigma[c] }
        }
        var counts = [Double](repeating: 0, count: nx * ny * channels)
        for p in 0..<(nx * ny) { for c in 0..<channels { counts[p * channels + c] = shape[c] * (1 + 0.1 * Double(p)) } }
        return try CoreLossSpectrumImage(nx: nx, ny: ny, channels: channels, counts: counts, energyOffsetEV: 200, energyScaleEV: 1)
    }

    /// The kit's MLLS flags N (amount ≤ 0) as not detected: its at% and wt% cells say "not detected", the footer says "N not detected (MLLS amount ≤ 0)",
    /// its tiles count the pixels, and the CSV says why; C and O keep their numbers. Red under: N shown as a bare 0.0 at%; the footer silent.
    func testANotDetectedElementIsSaidSo() throws {
        let core = try Self.plantedCore()
        let edges: [CoreLossEdge] = [.carbonK, .nitrogenK, .oxygenK]
        let result = try EELSFitCompute.fit(coreLoss: core, edges: edges, microscope: EELSControlsTests.microscope, lowLoss: nil, model: .mlls)
        let composition = try XCTUnwrap(EELSFitCompute.composition(result))
        XCTAssertEqual(composition[0].notDetected, [false, true, false], "the kit's flag on the planted negative N")

        let region = try EELSFitCompute.fit(coreLoss: try core.sum(mask: [true, true]), edges: edges, microscope: EELSControlsTests.microscope,
                                            lowLoss: nil, model: .mlls)
        let rows = EELSFitCompute.rows(region, composition: EELSFitCompute.composition(region))
        XCTAssertEqual(rows.map(\.notDetected), [false, true, false])
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRoomFormat.atomicText(rows[1], locale: en), "not detected")
        XCTAssertEqual(EELSRoomFormat.weightText(rows[1], locale: en), "not detected")
        XCTAssertNotEqual(EELSRoomFormat.atomicText(rows[0], locale: en), "not detected")
        XCTAssertEqual(EELSRoomFormat.notDetectedLine(rows), "N not detected (MLLS amount ≤ 0)")
        XCTAssertNil(EELSRoomFormat.notDetectedLine([rows[0], rows[2]]))

        let tiles = EELSFitCompute.tiles(result, composition: composition, version: 1)
        XCTAssertEqual(tiles.first { $0.id == "at-N" }?.footer, "2 px: not detected (MLLS amount ≤ 0)")
        XCTAssertEqual(tiles.first { $0.id == "wt-N" }?.footer, "2 px: not detected (MLLS amount ≤ 0)")
        XCTAssertNil(tiles.first { $0.id == "at-C" }?.footer)

        let csv = EELSExports.resultsCSV(rows, fileName: "planted.dm4", regionName: "Whole map", thickness: "t", method: "m")
        let nLine = try XCTUnwrap(csv.split(separator: "\n").first { $0.hasPrefix("\"N K\"") })
        XCTAssertTrue(nLine.hasSuffix(",\"not detected (MLLS amount ≤ 0)\""), String(nLine))
    }
}
