//
//  FFTRoomFormatTests.swift
//  Pins what the FFT room's inspector READS as (`FFTRoomFormat`, macTEM/UI/FFTRoomFormat.swift V1-6 "The room" and
//  ): what is transformed, the typed Left/Top/Size, Δq and the Nyquist frequency,
//  a spot's d and |q| in the shown units with the design's refusals, notes and accuracy rule, the radial chart's bins and
//  its readout (an interval of |q|, never a d), the mask count, the filters' seven parameters against the core's own ranges,
//  the status line and the words of the badge. The numbers are TEMCore's (gated); this is only their spelling and the few
//  rules the inspector adds, so every expected string is a literal worked out in the test's comment, never read back from
//  the formatter. The units follow R8 (nm and nm⁻¹ for a length, the file's own unit otherwise, px and px⁻¹).
//
//  App-hosted (`@testable import macTEM`), and ALSO compiled bare by a scratch SwiftPM package that symlinks this file and
//  FFTRoomFormat.swift into one test target (no app host), which is how the mutations were run: the file imports only XCTest,
//  TEMCore and TEMSession besides the app module, and the app module only where it exists.
//
//  Registered mutations, each named by the tests meant to turn it red (applied one at a time to a copy of the formatter,
//  2026-10-13; the lane's log is in the report, not the repo):
//   - the region's column and row swapped in "at (x, y)": testTheTransformedPixelsAreNamed
//   - the image's size named for a region: testTheTransformedPixelsAreNamed
//   - Left and Top swapped, or Size taken for the height-less field, in a typed field: testATypedFieldReplacesOneOfLeftTopSize
//   - a typed size not sent through FFTRegion.typed (odd sizes survive): testATypedFieldReplacesOneOfLeftTopSize
//   - Δq in the file's unit, unconverted: testTheFrequencyStepIsInTheSpectrumsUnit
//   - the Nyquist bin by integer n/2 (an odd side is off): testTheNyquistFrequencyAndItsSpacing
//   - the Nyquist spacing 1/q in the wrong unit, or d shown as q: testTheNyquistFrequencyAndItsSpacing
//   - d and |q| swapped; |q| multiplied instead of divided; a length left in the file's unit; the wrong digit count:
//     testASpotsDAndQAreShownInTheImagesUnit
//   - a refused or measuring spot shown as a measurement; the measured route reading q for d: testASpotRowReadsByItsOutcome
//   - a refusal's sentence changed or two refusals swapped: testEveryRefusalHasItsSentence
//   - the spot's number off, "px" or "px⁻¹" left as letters, the neighbour flag put in the row's label:
//     testAMeasuredSpotIsSpokenWithItsNumber
//   - the accuracy note at 255 or 257 px, or for the larger side: testTheAccuracyNoteIsShownUnder256PxOnly
//   - the keys of Measure at… off by one: testMeasureAtNamesTheBinsItCanTake
//   - the mask count including a refused or a measuring spot, or no singular: testTheMaskSummaryCountsMeasuredSpotsOnly
//   - the DC drawn; a bin at k·w; the unit factor on the mean or not on |q|; a zero bin kept for the log axis:
//     testTheChartDrawsBinsFromOneInTheShownUnit, testOnlyPositiveFiniteBinsAreDrawn,
//     testAProfileWithoutPowerHasNoBinsToDraw
//   - the readout's interval centred on the bin or one bin out; a d in the readout: testTheReadoutIsAnIntervalOfQNeverAD
//   - the power's decade off by one, a rounded-up mantissa not carried: testPowersReadInDecades
//   - a UI range wider or narrower than the core's: testEveryFilterRangeIsTheCoresRange
//   - a typed parameter not clamped, clamped on one side, rounded wrong, or written to another field:
//     testATypedParameterIsClampedAndLandsInItsOwnField
//   - "Changed" for one parameter missed: testTheParametersLabelReadsDefaultsOrChanged
//   - a plural passes for one; the flagged share at the wrong decimals: testTheLastRunsStatus
//   - a word of the badge or the notes changed: testTheDesignsWordsAreExact
//  Added with the review fixes (2026-10-14), each red on its own mutation (the table is in that session's report):
//   - the no-peak sentence changed, or a peakless spot read as a measurement or as a refusal: testASpotWithNoPeakIsNotMeasuredInOneSentence
//   - "1/1/nm" for an axis already reciprocal; its Å not converted: testAnAxisAlreadyReciprocalIsShownInTheUnitAfterTheSlash
//   - "px⁻¹" read as it is written (no "per pixel"); " px" left as letters: testSpokenTextSaysPerPixelAndPixels
//   - a label on every decade; the first mark off the data: testTheRadialChartLabelsEveryNthDecade
//   - the region hint without the pan clause: testTheDesignsWordsAreExact; the fields' spoken titles without "in pixels":
//     testATypedFieldReplacesOneOfLeftTopSize
//

import XCTest
import TEMCore
import TEMSession
import ImagoCore
import ImagoFFT
import ImagoFilters
#if canImport(macTEM)
@testable import macTEM
#endif

nonisolated final class FFTRoomFormatTests: XCTestCase {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let german = Locale(identifier: "de_DE")
    private static let micro = "\u{00B5}"   // U+00B5, the micro sign DisplaySampling writes in "µm"

    // MARK: Fixtures

    /// A 128 × 128 image of cosines along x at the given whole bins (a bin b is a period of 128 / b pixels) on a DC of
    /// 100, on 0.05 nm pixels or uncalibrated. Bin 16 is d = 128 · 0.05 / 16 = 0.4 nm, |q| = 2.5 nm⁻¹ (8 px, 0.125 px⁻¹);
    /// its peak sits at column 64 + 16 = 80 of row 64.
    private static func lattice(_ cosines: [(bin: Int, amplitude: Double)], calibrated: Bool) -> CalibratedImage {
        let n = 128
        let pixels = (0..<(n * n)).map { i -> Float in
            let x = Double(i % n)
            return Float(100 + cosines.reduce(0.0) { $0 + $1.amplitude * cos(2 * .pi * Double($1.bin) * x / Double(n)) })
        }
        let axis = calibrated ? AxisCalibration(scale: 0.05, unit: "nm", origin: 0) : nil
        return CalibratedImage(width: n, height: n, pixels: pixels, x: axis, y: axis, fileName: "lattice", source: "", voltage: nil)
    }

    private static let key = FFTSpectrumKey(contentVersion: 1, crop: nil)

    private static func measuredSpot(number: Int = 1, calibrated: Bool = true, inMask: Bool = true,
                                     cosines: [(bin: Int, amplitude: Double)] = [(16, 10)]) throws -> (FFTSpot, SpotMeasurement) {
        let m = try SpotMeasurement.measure(lattice(cosines, calibrated: calibrated).micrograph, clickRow: 64, clickColumn: 80)
        return (FFTSpot(number: number, row: 64, col: 80, spectrumKey: key, outcome: .measured(m), inMask: inMask), m)
    }

    // MARK: What is transformed

    /// The pane's own words: "region 256 × 256 px at (812, 404)" with (Left, Top) = (column, row) of the crop, or "the whole
    /// image, 2048 × 1024 px"; without the position (the notes) just the size. Red under: column and row swapped; the image's
    /// size named for a region; the position kept in the position-free form.
    func testTheTransformedPixelsAreNamed() {
        let crop = PixelCrop(row: 404, col: 812, height: 256, width: 256)
        XCTAssertEqual(FFTRoomFormat.transformed(crop, imageWidth: 2048, imageHeight: 1024),
                       "region 256 × 256 px at (812, 404)")
        XCTAssertEqual(FFTRoomFormat.transformed(crop, imageWidth: 2048, imageHeight: 1024, withPosition: false),
                       "region 256 × 256 px")
        XCTAssertEqual(FFTRoomFormat.transformed(nil, imageWidth: 2048, imageHeight: 1024),
                       "the whole image, 2048 × 1024 px")
        XCTAssertEqual(FFTRoomFormat.transformed(nil, imageWidth: 2048, imageHeight: 1024, withPosition: false),
                       "the whole image, 2048 × 1024 px")
        // The Info tab splits it into a kind and a size.
        XCTAssertEqual(FFTRoomFormat.transformedKind(crop), "Region at (812, 404)")
        XCTAssertEqual(FFTRoomFormat.transformedKind(nil), "The whole image")
        XCTAssertEqual(FFTRoomFormat.pixelSize(crop, imageWidth: 2048, imageHeight: 1024), "256 × 256 px")
        XCTAssertEqual(FFTRoomFormat.pixelSize(nil, imageWidth: 2048, imageHeight: 1024), "2048 × 1024 px")
    }

    // MARK: The typed region

    /// Left, Top and Size each replace their own number of the region and nothing else, and the request goes through the
    /// registered clamps (`FFTRegion.typed`: the even size at or below, 32…S, then left and top inside). On a 300 × 200 image
    /// with the region 64 × 64 at (col 40, row 20): Left 100 → col 100; Top 60 → row 60; Size 100 → 100 × 100 with the corner
    /// kept; 101 → 100; 20 → 32; Left 500 → 300 − 64 = 236; Size 300 → S = 200, its corner shifted to row 0. Red under: Left
    /// and Top swapped; Size written as the position; the typed numbers not sent through `typed`.
    func testATypedFieldReplacesOneOfLeftTopSize() {
        let current = PixelCrop(row: 20, col: 40, height: 64, width: 64)
        func typed(_ value: Int, _ field: FFTRoomFormat.RegionField) -> PixelCrop? {
            FFTRoomFormat.region(typing: value, into: field, current: current, width: 300, height: 200)
        }
        XCTAssertEqual(typed(100, .left), PixelCrop(row: 20, col: 100, height: 64, width: 64))
        XCTAssertEqual(typed(60, .top), PixelCrop(row: 60, col: 40, height: 64, width: 64))
        XCTAssertEqual(typed(100, .size), PixelCrop(row: 20, col: 40, height: 100, width: 100))
        XCTAssertEqual(typed(101, .size), PixelCrop(row: 20, col: 40, height: 100, width: 100), "the even size at or below")
        XCTAssertEqual(typed(20, .size), PixelCrop(row: 20, col: 40, height: 32, width: 32), "at least 32")
        XCTAssertEqual(typed(500, .left), PixelCrop(row: 20, col: 236, height: 64, width: 64), "held inside the image")
        XCTAssertEqual(typed(300, .size), PixelCrop(row: 0, col: 40, height: 200, width: 200), "S = 200, shifted in")
        // The fields read back what they edit.
        XCTAssertEqual(FFTRoomFormat.RegionField.allCases.map { $0.value(of: current) }, [40, 20, 64])
        XCTAssertEqual(FFTRoomFormat.RegionField.allCases.map(\.title), ["Left", "Top", "Size"])
        XCTAssertEqual(FFTRoomFormat.RegionField.allCases.map(\.spokenTitle), ["Left in pixels", "Top in pixels", "Size in pixels"],
                       "VoiceOver reads \"px\" letter by letter: the unit is spelled in the field's spoken title")
        XCTAssertEqual(FFTRoomFormat.RegionField.allCases.map(\.identifier),
                       ["fft.region.left", "fft.region.top", "fft.region.size"])
    }

    // MARK: Δq and the Nyquist frequency

    /// Δq in the spectrum's own unit brought to the shown one (R8): 0.0625 1/nm is 0.0625 nm⁻¹; 6.25e7 1/m is 0.0625 nm⁻¹
    /// (1 m⁻¹ = 1e-9 nm⁻¹); the two axes of an anisotropic pair read apart; cycles per pixel are px⁻¹; a diffraction image's
    /// spectrum is in nm, as written. Red under: the metre value unconverted (6.25e7 nm⁻¹ shown); x and y read from one axis.
    func testTheFrequencyStepIsInTheSpectrumsUnit() {
        let posix = Self.posix
        func steps(_ x: Double, _ ux: String, _ y: Double, _ uy: String, _ locale: Locale = posix) -> [String] {
            let s = FFTRoomFormat.frequencySteps(spacingX: x, unitsX: ux, spacingY: y, unitsY: uy, locale: locale)
            return [s.x, s.y]
        }
        XCTAssertEqual(steps(0.0625, "1/nm", 0.0625, "1/nm"), ["0.0625 nm⁻¹", "0.0625 nm⁻¹"])
        XCTAssertEqual(steps(6.25e7, "1/m", 6.25e7, "1/m"), ["0.0625 nm⁻¹", "0.0625 nm⁻¹"])
        XCTAssertEqual(steps(0.0625, "1/nm", 0.05, "1/nm"), ["0.0625 nm⁻¹", "0.05 nm⁻¹"])
        XCTAssertEqual(steps(0.00625, "1/px", 0.00625, "1/px"), ["0.00625 px⁻¹", "0.00625 px⁻¹"])
        XCTAssertEqual(steps(20, "nm", 20, "nm"), ["20 nm", "20 nm"])
        XCTAssertEqual(steps(0.0625, "1/nm", 0.05, "1/nm", Self.german), ["0,0625 nm⁻¹", "0,05 nm⁻¹"])
    }

    /// The Nyquist frequency of n samples is n · Δq / 2 and its spacing d = 1/q in the real unit: 256 samples of 0.05 nm give
    /// Δq = 0.078125 nm⁻¹, q = 10 nm⁻¹, d = 0.1 nm (= 2 · 0.05); the same in metres reads the same; cycles per pixel give
    /// 0.5 px⁻¹ and 2 px; an ODD side (255) still has Nyquist 10 nm⁻¹ (n/2 is 127.5, not 127). Red under: integer n/2 (9.961
    /// for 255); d left in the file's unit (1e-11 shown); q shown for d.
    func testTheNyquistFrequencyAndItsSpacing() {
        let posix = Self.posix
        XCTAssertEqual(FFTRoomFormat.nyquist(spacing: 0.078125, count: 256, units: "1/nm", locale: posix),
                       "10 nm⁻¹ · d 0.1 nm")
        XCTAssertEqual(FFTRoomFormat.nyquist(spacing: 7.8125e8, count: 256, units: "1/m", locale: posix),
                       "100 nm⁻¹ · d 0.01 nm")
        XCTAssertEqual(FFTRoomFormat.nyquist(spacing: 1.0 / 256, count: 256, units: "1/px", locale: posix),
                       "0.5 px⁻¹ · d 2 px")
        XCTAssertEqual(FFTRoomFormat.nyquist(spacing: 1 / (255 * 0.05), count: 255, units: "1/nm", locale: posix),
                       "10 nm⁻¹ · d 0.1 nm")
        XCTAssertEqual(FFTRoomFormat.nyquist(spacing: 0.078125, count: 256, units: "1/nm", locale: Self.german),
                       "10 nm⁻¹ · d 0,1 nm")
        // The real unit of a spectrum's unit: the reciprocal's reciprocal, and a diffraction image's nm is a 1/nm.
        XCTAssertEqual(["1/nm", "1/m", "1/px", "nm"].map(FFTRoomFormat.realUnit(ofSpectrumUnit:)), ["nm", "m", "px", "1/nm"])
    }

    // MARK: Spots

    /// A spot's d and |q| in the shown units (R8), four significant digits: 0.4 nm and 2.5 nm⁻¹ however the file writes them
    /// (nm; m: 4e-10, 2.5e9; Å: 4, 0.25; µm: 0.0004, 2500; pm: 400, 0.0025); pixels stay px and px⁻¹; an unknown unit stays as
    /// written; the reader's decimal mark. Red under: d and |q| swapped; |q| multiplied by the factor instead of divided;
    /// a length left in the file's unit; three or five digits.
    func testASpotsDAndQAreShownInTheImagesUnit() {
        let posix = Self.posix
        func value(_ d: Double, _ q: Double, _ unit: String, _ locale: Locale = posix) -> String {
            FFTRoomFormat.spotValue(d: d, q: q, unit: unit, locale: locale)
        }
        let nm = "d 0.4 nm · |q| 2.5 nm⁻¹"
        XCTAssertEqual(value(0.4, 2.5, "nm"), nm)
        XCTAssertEqual(value(4e-10, 2.5e9, "m"), nm)
        XCTAssertEqual(value(4, 0.25, "Å"), nm)
        XCTAssertEqual(value(0.0004, 2500, "\(Self.micro)m"), nm)
        XCTAssertEqual(value(400, 0.0025, "pm"), nm)
        XCTAssertEqual(value(8, 0.125, "px"), "d 8 px · |q| 0.125 px⁻¹")
        XCTAssertEqual(value(3, 0.5, "foo"), "d 3 foo · |q| 0.5 1/foo")
        XCTAssertEqual(value(0.123456, 8.123456, "nm"), "d 0.1235 nm · |q| 8.123 nm⁻¹", "four significant digits")
        XCTAssertEqual(value(0.4, 2.5, "nm", Self.german), "d 0,4 nm · |q| 2,5 nm⁻¹")
        let parts = FFTRoomFormat.spotParts(d: 0.4, q: 2.5, unit: "nm", locale: posix)
        XCTAssertEqual(parts.d, "d 0.4 nm")
        XCTAssertEqual(parts.q, "|q| 2.5 nm⁻¹")
        XCTAssertEqual(FFTRoomFormat.length(0.4, unit: "nm", locale: posix), "0.4 nm")
        XCTAssertEqual(FFTRoomFormat.reciprocal(2.5, realUnit: "nm", locale: posix), "2.5 nm⁻¹")
    }

    /// A row reads by its outcome: a measured spot is the spot's own d, |q| and unit through the numbers' formatter; a
    /// measuring one says so; a refused one is its sentence (also what ⌘C copies). Red under: the measured route reading q
    /// for d; a refused or measuring spot shown as numbers.
    func testASpotRowReadsByItsOutcome() throws {
        let posix = Self.posix
        let (calibrated, m) = try Self.measuredSpot()
        XCTAssertEqual(m.units, "nm", "the setup: a calibrated lattice")
        XCTAssertEqual(FFTRoomFormat.spotValue(calibrated, locale: posix),
                       FFTRoomFormat.spotValue(d: m.d, q: m.q, unit: "nm", locale: posix))
        XCTAssertEqual(FFTRoomFormat.spotValue(calibrated, locale: posix), "d 0.4 nm · |q| 2.5 nm⁻¹", "bin 16 of 128 at 0.05 nm")
        let parts = try XCTUnwrap(FFTRoomFormat.measuredParts(calibrated, locale: posix))
        XCTAssertEqual(parts.d, "d 0.4 nm")
        XCTAssertEqual(parts.q, "|q| 2.5 nm⁻¹")

        let (pixels, p) = try Self.measuredSpot(number: 2, calibrated: false)
        XCTAssertEqual(p.units, "px", "the setup: an uncalibrated lattice")
        XCTAssertEqual(FFTRoomFormat.spotValue(pixels, locale: posix), "d 8 px · |q| 0.125 px⁻¹", "bin 16 of 128 px = 8 px")

        let measuring = FFTSpot(number: 3, row: 10, col: 20, spectrumKey: Self.key, outcome: .measuring)
        XCTAssertEqual(FFTRoomFormat.spotValue(measuring, locale: posix), "Measuring…")
        XCTAssertNil(FFTRoomFormat.measuredParts(measuring, locale: posix))
        let refused = FFTSpot(number: 4, row: 64, col: 65, spectrumKey: Self.key, outcome: .refused(.nearDC))
        XCTAssertEqual(FFTRoomFormat.spotValue(refused, locale: posix),
                       "Not measured: the peak nearest the click is within 3 bins of the centre.")
        XCTAssertNil(FFTRoomFormat.measuredParts(refused, locale: posix))
    }

    /// Each refusal is its own sentence, the first two the design's words. Red under: the two swapped, one reworded, a case
    /// falling into another's.
    func testEveryRefusalHasItsSentence() {
        let crop = PixelCrop(row: 0, col: 0, height: 8, width: 8)
        let failures: [SpotMeasurementError] = [.nearDC, .nearEdge, .mixedUnits("nm", "1/nm"), .crop(crop), .fftSetup(width: 7, height: 9),
                                               .outside(row: 5, col: 6), .zeroFrequency]
        XCTAssertEqual(failures.map(FFTRoomFormat.refusal), [
            "Not measured: the peak nearest the click is within 3 bins of the centre.",
            "Not measured: the peak nearest the click is within 2 bins of the edge.",
            "Not measured: the axes are in different units.",
            "Not measured: the region does not lie inside the image.",
            "Not measured: the Fourier transform of 7 × 9 px could not be set up.",
            "Not measured: the click is outside the spectrum.",
            "Not measured: one of the spots is at the zero frequency.",      // the kit's angle between two spots; the room never asks
        ])
    }

    /// VoiceOver hears the number first, "px" as pixels, "px⁻¹" as per pixel, and a refusal and a measuring spot by their words.
    /// The neighbour flag is not in the row's label: the glyph is an element of its own, with the sentence for its label (so a
    /// flagged spot is not announced twice). Red under: the spot's number off; "px" or "px⁻¹" left as letters; the flag put in
    /// the label.
    func testAMeasuredSpotIsSpokenWithItsNumber() throws {
        let posix = Self.posix
        let (calibrated, m) = try Self.measuredSpot()
        XCTAssertFalse(m.neighbour, "the setup: one lattice, no neighbour")
        XCTAssertEqual(FFTRoomFormat.spotSpoken(calibrated, locale: posix), "Spot 1, d 0.4 nm, |q| 2.5 nm⁻¹")
        let (pixels, _) = try Self.measuredSpot(number: 2, calibrated: false)
        XCTAssertEqual(FFTRoomFormat.spotSpoken(pixels, locale: posix), "Spot 2, d 8 pixels, |q| 0.125 per pixel")
        let (crowded, c) = try Self.measuredSpot(number: 5, cosines: [(16, 10), (19, 6)])
        XCTAssertTrue(c.neighbour, "the setup: a peak of 36 % of the spot's power three bins away")
        // The neighbour's skirt moves the centroid a little, so the numbers are the spot's own, not 0.4 and 2.5.
        let parts = FFTRoomFormat.spotParts(d: c.d, q: c.q, unit: c.units, locale: posix)
        XCTAssertEqual(FFTRoomFormat.spotSpoken(crowded, locale: posix), "Spot 5, \(parts.d), \(parts.q)")
        let measuring = FFTSpot(number: 6, row: 1, col: 2, spectrumKey: Self.key, outcome: .measuring)
        XCTAssertEqual(FFTRoomFormat.spotSpoken(measuring, locale: posix), "Spot 6, measuring")
        let refused = FFTSpot(number: 7, row: 1, col: 2, spectrumKey: Self.key, outcome: .refused(.nearEdge))
        XCTAssertEqual(FFTRoomFormat.spotSpoken(refused, locale: posix),
                       "Spot 7, Not measured: the peak nearest the click is within 2 bins of the edge.")
    }

    /// "Measured on a Hann-windowed copy of …" names what the spots' spectrum is of, without the position. Red under: the
    /// position kept; the image's size named for a region.
    func testTheMeasurementNoteNamesWhatWasTransformed() {
        let crop = PixelCrop(row: 404, col: 812, height: 256, width: 256)
        XCTAssertEqual(FFTRoomFormat.measuredOn(crop, imageWidth: 2048, imageHeight: 1024),
                       "Measured on a Hann-windowed copy of region 256 × 256 px.")
        XCTAssertEqual(FFTRoomFormat.measuredOn(nil, imageWidth: 2048, imageHeight: 1024),
                       "Measured on a Hann-windowed copy of the whole image, 2048 × 1024 px.")
    }

    /// The accuracy note by size is shown under 256 px only: the smaller side decides (a whole image can be any shape), 256 is
    /// not under. Red under: the bound at 255 or 257; the larger side deciding; always shown; never shown.
    func testTheAccuracyNoteIsShownUnder256PxOnly() {
        let sentence = "With noise, d is good to 1–5 % at 64 px and 0.5–3 % at 128 px."
        XCTAssertEqual(FFTRoomFormat.accuracyNote(width: 255, height: 255), sentence)
        XCTAssertEqual(FFTRoomFormat.accuracyNote(width: 64, height: 64), sentence)
        XCTAssertEqual(FFTRoomFormat.accuracyNote(width: 2048, height: 255), sentence, "the smaller side")
        XCTAssertEqual(FFTRoomFormat.accuracyNote(width: 255, height: 2048), sentence, "the smaller side")
        XCTAssertNil(FFTRoomFormat.accuracyNote(width: 256, height: 256))
        XCTAssertNil(FFTRoomFormat.accuracyNote(width: 257, height: 257))
        XCTAssertNil(FFTRoomFormat.accuracyNote(width: 4096, height: 256))
    }

    /// Measure at… takes whole bins from the centre, the bin (h/2 + ky, w/2 + kx): kx from −w/2 to w − 1 − w/2. On 128 × 96
    /// that is −64…63 and −48…47; on 127 × 95 −63…63 and −47…47. The text agrees with `SpectrumBin.at(kx:ky:)` at both ends
    /// and one beyond (nil). Red under: an end off by one (−65…64, or w/2 used for both ends); width and height swapped.
    func testMeasureAtNamesTheBinsItCanTake() {
        XCTAssertEqual(FFTRoomFormat.binRange(width: 128, height: 96), "Whole bins from the centre: kx -64 to 63, ky -48 to 47.")
        XCTAssertEqual(FFTRoomFormat.binRange(width: 127, height: 95), "Whole bins from the centre: kx -63 to 63, ky -47 to 47.")
        for (w, h) in [(128, 96), (127, 95)] {
            let kx0 = -(w / 2), kx1 = w - 1 - w / 2, ky0 = -(h / 2), ky1 = h - 1 - h / 2
            XCTAssertNotNil(SpectrumBin.at(kx: kx0, ky: ky0, width: w, height: h))
            XCTAssertNotNil(SpectrumBin.at(kx: kx1, ky: ky1, width: w, height: h))
            XCTAssertNil(SpectrumBin.at(kx: kx0 - 1, ky: 0, width: w, height: h))
            XCTAssertNil(SpectrumBin.at(kx: kx1 + 1, ky: 0, width: w, height: h))
            XCTAssertNil(SpectrumBin.at(kx: 0, ky: ky0 - 1, width: w, height: h))
            XCTAssertNil(SpectrumBin.at(kx: 0, ky: ky1 + 1, width: w, height: h))
        }
    }

    // MARK: The mask

    /// "n of m spots in the mask" counts the spots the mask can take (a measured one: a refused or a measuring spot has no
    /// centroid) and the ones of them switched on; one spot is "spot". Red under: m counting every spot; n counting a refused
    /// spot that is switched on; no singular.
    func testTheMaskSummaryCountsMeasuredSpotsOnly() throws {
        let (a, _) = try Self.measuredSpot(number: 1, inMask: true)
        let (b, _) = try Self.measuredSpot(number: 2, inMask: false)
        let (c, _) = try Self.measuredSpot(number: 3, inMask: true)
        let refused = FFTSpot(number: 4, row: 1, col: 2, spectrumKey: Self.key, outcome: .refused(.nearDC), inMask: true)
        let measuring = FFTSpot(number: 5, row: 1, col: 2, spectrumKey: Self.key, outcome: .measuring, inMask: true)
        XCTAssertEqual(FFTRoomFormat.maskSummary([a, b, c, refused, measuring]), "2 of 3 spots in the mask")
        XCTAssertEqual(FFTRoomFormat.maskSummary([a]), "1 of 1 spot in the mask")
        XCTAssertEqual(FFTRoomFormat.maskSummary([b, refused]), "0 of 1 spot in the mask")
    }

    // MARK: The radial chart

    /// The chart's bins are the profile's from bin 1 (bin 0 holds the DC), each at its centre (k + ½)·w, |q| in the shown unit
    /// (the factor applied to |q| only: the mean is a power), with the profile's own mean and pixel count. A 64 × 64 lattice
    /// image at 0.05 nm: w = 1/(64 · 0.05) = 0.3125 nm⁻¹. Red under: the DC drawn; a bin at k·w; the factor on the mean or
    /// missing from |q|; a count or mean of another bin.
    func testTheChartDrawsBinsFromOneInTheShownUnit() throws {
        let n = 64
        let pixels = (0..<(n * n)).map { i -> Float in
            let x = Double(i % n), y = Double(i / n)
            // A little deterministic noise keeps every bin's power above zero, so bin 1 is drawn.
            return Float(100 + 10 * cos(2 * .pi * (5 * x + 3 * y) / Double(n)) + 3 * sin(2 * .pi * 12 * y / Double(n))
                         + 0.5 * sin(Double(i) * 12.9898))
        }
        let axis = AxisCalibration(scale: 0.05, unit: "nm", origin: 0)
        let image = CalibratedImage(width: n, height: n, pixels: pixels, x: axis, y: axis, fileName: "t", source: "", voltage: nil)
        let profile = try RadialProfile.compute(try PowerSpectrum.compute(image.micrograph))
        XCTAssertEqual(profile.width, 0.3125, accuracy: 1e-15, "the setup")

        let samples = FFTRoomFormat.chartSamples(profile, factor: 1)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(samples.first?.bin, 1, "bin 0 is the DC")
        XCTAssertEqual(samples.map(\.bin), samples.map(\.bin).sorted(), "in order")
        for s in samples {
            XCTAssertGreaterThanOrEqual(s.bin, 1)
            XCTAssertEqual(s.q, (Double(s.bin) + 0.5) * 0.3125, accuracy: 1e-12, "bin \(s.bin) at its centre")
            XCTAssertEqual(s.mean, profile.mean[s.bin])
            XCTAssertEqual(s.count, profile.count[s.bin])
        }
        // A factor takes |q| to another unit; the mean is untouched.
        let scaled = FFTRoomFormat.chartSamples(profile, factor: 10)
        XCTAssertEqual(scaled.map(\.bin), samples.map(\.bin))
        for (a, b) in zip(samples, scaled) {
            XCTAssertEqual(b.q, a.q * 10, accuracy: 1e-12)
            XCTAssertEqual(b.mean, a.mean)
            XCTAssertEqual(b.count, a.count)
        }
    }

    /// A profile whose bins hold no power — a constant image: all of its power is the DC — has nothing to draw, and the chart
    /// never hands the log axis a zero. Red under: `chartSamples` not dropping the bins the log axis cannot draw.
    func testAProfileWithoutPowerHasNoBinsToDraw() throws {
        let n = 64
        let axis = AxisCalibration(scale: 0.05, unit: "nm", origin: 0)
        let constant = CalibratedImage(width: n, height: n, pixels: [Float](repeating: 5, count: n * n), x: axis, y: axis,
                                       fileName: "c", source: "", voltage: nil)
        let spectrum = try PowerSpectrum.compute(constant.micrograph)
        XCTAssertTrue(spectrum.power.float32Values.enumerated().allSatisfy { $0.offset == n / 2 * n + n / 2 || $0.element == 0 },
                      "the setup: a constant image has power at the DC only")
        let profile = try RadialProfile.compute(spectrum)
        XCTAssertEqual(FFTRoomFormat.chartSamples(profile, factor: 1), [])
    }

    /// The log axis draws a positive, finite mean only: a bin of zero power (a noise-free plant), a negative or a non-finite
    /// one is not drawn, the rest keep their order. Red under: the filter dropped (zero reaches the log axis); the filter at
    /// ≥ 0.
    func testOnlyPositiveFiniteBinsAreDrawn() {
        typealias S = FFTRoomFormat.ChartSample
        let all = [S(bin: 1, q: 0.5, mean: 1e-9, count: 8), S(bin: 2, q: 1, mean: 0, count: 12), S(bin: 3, q: 1.5, mean: -1, count: 4),
                   S(bin: 4, q: 2, mean: .nan, count: 4), S(bin: 5, q: 2.5, mean: .infinity, count: 4),
                   S(bin: 6, q: 3, mean: 7, count: 20)]
        XCTAssertEqual(FFTRoomFormat.drawable(all).map(\.bin), [1, 6])
        XCTAssertEqual(FFTRoomFormat.drawable([]), [])
    }

    /// The pointer's |q| selects the bin whose centre is nearest, the ends holding beyond the chart; nothing when nothing is
    /// drawn. Red under: the farthest, the first or the last bin always.
    func testThePointerSelectsTheNearestBin() {
        typealias S = FFTRoomFormat.ChartSample
        let bins = [S(bin: 1, q: 0.1, mean: 5, count: 1), S(bin: 2, q: 0.3, mean: 4, count: 2), S(bin: 3, q: 0.5, mean: 3, count: 3)]
        XCTAssertEqual(FFTRoomFormat.nearest(bins, toX: 0.29)?.bin, 2)
        XCTAssertEqual(FFTRoomFormat.nearest(bins, toX: 0.41)?.bin, 3)
        XCTAssertEqual(FFTRoomFormat.nearest(bins, toX: 0.19)?.bin, 1)
        XCTAssertEqual(FFTRoomFormat.nearest(bins, toX: -5)?.bin, 1)
        XCTAssertEqual(FFTRoomFormat.nearest(bins, toX: 9)?.bin, 3)
        XCTAssertNil(FFTRoomFormat.nearest([], toX: 0.3))
    }

    /// The readout is the bin's INTERVAL of |q| — bin k spans [k·w, (k+1)·w) — the mean power and the pixel count, and never
    /// a d: a profile bin is not a ring's d spacing. Bin 3 of width 0.25 nm⁻¹: 0.75 – 1. Red under: the interval centred on the
    /// bin's centre (0.625 – 0.875), one bin out, or a "d" in the text.
    func testTheReadoutIsAnIntervalOfQNeverAD() {
        let sample = FFTRoomFormat.ChartSample(bin: 3, q: 0.875, mean: 321000, count: 128)
        let text = FFTRoomFormat.readout(sample, binWidth: 0.25, label: "nm⁻¹", locale: Self.posix)
        XCTAssertEqual(text, "|q| 0.75 – 1 nm⁻¹ · mean |F|² 3.21 × 10⁵ · 128 px")
        XCTAssertFalse(text.contains("d"), "no d-spacing")
        XCTAssertEqual(FFTRoomFormat.caption(binWidth: 0.3125, label: "nm⁻¹", what: "region 256 × 256 px", locale: Self.posix),
                       "Bin width 0.3125 nm⁻¹ · region 256 × 256 px · bin 0 (the DC) is not drawn")
        XCTAssertEqual(FFTRoomFormat.profileUnavailable, "Not available: the axes are in different units.")
    }

    /// A power reads as a mantissa of three digits and a decade: 321000 → 3.21 × 10⁵; a whole decade just 10ⁿ; a mantissa
    /// that rounds up to 10 carries (99960 → 10⁵, not 10.0 × 10⁴); negative decades take ⁻; decade 0 is the mantissa alone;
    /// 0 is 0; a non-finite value a dash; the reader's decimal mark. Red under: the decade off by one; the carry missing;
    /// a decade of 1 written "1 × 10⁵".
    func testPowersReadInDecades() {
        let p = { (v: Double) in FFTRoomFormat.power(v, locale: Self.posix) }
        XCTAssertEqual(p(321000), "3.21 × 10⁵")
        XCTAssertEqual(p(1e5), "10⁵")
        XCTAssertEqual(p(1000), "10³")
        XCTAssertEqual(p(99960), "10⁵")
        XCTAssertEqual(p(0.0015), "1.5 × 10⁻³")
        XCTAssertEqual(p(1.234e-12), "1.23 × 10⁻¹²")
        XCTAssertEqual(p(12.5), "1.25 × 10¹")
        XCTAssertEqual(p(5), "5")
        XCTAssertEqual(p(0), "0")
        XCTAssertEqual(p(.nan), "—")
        XCTAssertEqual(FFTRoomFormat.power(321000, locale: Self.german), "3,21 × 10⁵")
    }

    /// The chart's spoken overview: how many bins, the |q| of the first and the last, and the powers' range.
    func testTheChartIsSummarisedForVoiceOver() {
        typealias S = FFTRoomFormat.ChartSample
        let bins = [S(bin: 1, q: 0.5, mean: 1e4, count: 8), S(bin: 2, q: 0.75, mean: 1e2, count: 12), S(bin: 3, q: 1.25, mean: 5e3, count: 4)]
        XCTAssertEqual(FFTRoomFormat.profileSummary(bins, label: "nm⁻¹", locale: Self.posix),
                       "3 bins from 0.5 to 1.25 nm⁻¹; mean |F|² from 10² to 10⁴")
        XCTAssertEqual(FFTRoomFormat.profileSummary([bins[1]], label: "nm⁻¹", locale: Self.posix),
                       "1 bin from 0.75 to 0.75 nm⁻¹; mean |F|² from 10² to 10²")
        XCTAssertEqual(FFTRoomFormat.profileSummary([], label: "nm⁻¹", locale: Self.posix), "No bins")
    }

    // MARK: The filters

    /// The parameters the section offers are the ones the filter accepts and exactly those: at each range's ends the core
    /// accepts the value, one step beyond it refuses it by the parameter's name. Red under: a range wider than the core's
    /// (its upper bound refused) or narrower (the value beyond it accepted).
    func testEveryFilterRangeIsTheCoresRange() {
        let names: [FFTRoomFormat.FilterParameter: String] = [
            .delta: "delta", .step: "step", .cycles: "cycles", .order: "order", .ro: "ro", .lowFrequency: "lowFrequencyPercent"]
        for parameter in FFTRoomFormat.FilterParameter.allCases {
            let name = names[parameter]
            let beyond = parameter.isInteger ? 1.0 : 1e-6
            for (value, accepted) in [(parameter.range.lowerBound, true), (parameter.range.upperBound, true),
                                      (parameter.range.lowerBound - beyond, false), (parameter.range.upperBound + beyond, false)] {
                let p = Self.setting(parameter, value, in: .defaults)
                XCTAssertEqual(p.outOfRange, accepted ? nil : name, "\(parameter) at \(value)")
            }
        }
        XCTAssertEqual(FFTRoomFormat.FilterParameter.allCases.map { $0.rangeText(locale: Self.posix) },
                       ["0–50 %", "1–10", "1–99", "1–20", "0.01–3", "0–20 %"])
        XCTAssertEqual(FFTRoomFormat.FilterParameter.ro.rangeText(locale: Self.german), "0,01–3")
        XCTAssertEqual(FFTRoomFormat.FilterParameter.allCases.map(\.title),
                       ["Delta", "Step", "Cycles", "Order", "Ro", "Low frequency"])
        XCTAssertEqual(FFTRoomFormat.FilterParameter.allCases.map(\.unit), ["%", nil, nil, nil, nil, "%"])
        XCTAssertEqual(FFTRoomFormat.FilterParameter.allCases.map(\.isInteger), [false, false, true, true, false, false])
        XCTAssertEqual(FFTRoomFormat.FilterParameter.allCases.map(\.identifier),
                       ["fft.filter.delta", "fft.filter.step", "fft.filter.cycles", "fft.filter.order", "fft.filter.ro",
                        "fft.filter.lowFrequency"])
        for parameter in FFTRoomFormat.FilterParameter.allCases {
            XCTAssertTrue(parameter.help(locale: Self.posix).hasSuffix("(\(parameter.rangeText(locale: Self.posix)))"),
                          "\(parameter): the range is in its help")
        }
    }

    /// The parameter set straight from the core's own fields (no `applying`), the ground truth of the test above.
    private static func setting(_ parameter: FFTRoomFormat.FilterParameter, _ value: Double,
                                in start: HRTEMFilter.Parameters) -> HRTEMFilter.Parameters {
        var p = start
        switch parameter {
        case .delta: p.delta = value
        case .step: p.step = value
        case .cycles: p.cycles = Int(value)
        case .order: p.order = Int(value)
        case .ro: p.ro = value
        case .lowFrequency: p.lowFrequencyPercent = value
        }
        return p
    }

    /// A typed parameter lands in its own field, clamped into the range (the core refuses, never clamps; the field must not
    /// hand it a value it will refuse) and rounded for the integer ones; every other field keeps its value; a value that is not
    /// a number changes nothing. Red under: no clamp, one side clamped, an integer truncated instead of rounded (12.6 → 12),
    /// a value written to the neighbouring field.
    func testATypedParameterIsClampedAndLandsInItsOwnField() {
        typealias P = FFTRoomFormat.FilterParameter
        let start = HRTEMFilter.Parameters.defaults
        func apply(_ parameter: P, _ value: Double) -> HRTEMFilter.Parameters { parameter.applying(value, to: start) }
        func expected(_ parameter: P, _ value: Double) -> HRTEMFilter.Parameters { Self.setting(parameter, value, in: start) }

        XCTAssertEqual(apply(.delta, 7.5), expected(.delta, 7.5))
        XCTAssertEqual(apply(.delta, 120), expected(.delta, 50))
        XCTAssertEqual(apply(.delta, -3), expected(.delta, 0))
        XCTAssertEqual(apply(.step, 0.2), expected(.step, 1))
        XCTAssertEqual(apply(.step, 11), expected(.step, 10))
        XCTAssertEqual(apply(.cycles, 0), expected(.cycles, 1))
        XCTAssertEqual(apply(.cycles, 100), expected(.cycles, 99))
        XCTAssertEqual(apply(.cycles, 12.6), expected(.cycles, 13))
        XCTAssertEqual(apply(.cycles, 12.4), expected(.cycles, 12))
        XCTAssertEqual(apply(.order, 21), expected(.order, 20))
        XCTAssertEqual(apply(.order, 0), expected(.order, 1))
        XCTAssertEqual(apply(.ro, 0), expected(.ro, 0.01))
        XCTAssertEqual(apply(.ro, 4), expected(.ro, 3))
        XCTAssertEqual(apply(.lowFrequency, 25), expected(.lowFrequency, 20))
        XCTAssertEqual(apply(.lowFrequency, -1), expected(.lowFrequency, 0))
        for parameter in P.allCases {
            XCTAssertEqual(apply(parameter, .nan), start, "\(parameter): not a number")
            XCTAssertEqual(apply(parameter, .infinity), start, "\(parameter): not finite")
            for value in [-1e9, 1e9] { XCTAssertNil(apply(parameter, value).outOfRange, "\(parameter) at \(value)") }
        }
        // Applied on top of other changes, a parameter keeps them.
        var changed = start
        changed.smoothing = false
        changed.step = 4
        XCTAssertEqual(P.cycles.applying(30, to: changed).step, 4)
        XCTAssertEqual(P.cycles.applying(30, to: changed).smoothing, false)
        XCTAssertEqual(P.cycles.applying(30, to: changed).cycles, 30)
        // Each reads back its own field.
        var distinct = start
        distinct.delta = 11; distinct.step = 3; distinct.cycles = 5; distinct.order = 6; distinct.ro = 0.5
        distinct.lowFrequencyPercent = 9
        XCTAssertEqual(P.allCases.map { $0.value(in: distinct) }, [11, 3, 5, 6, 0.5, 9])
    }

    /// Closed, the Parameters row reads "Mitchell's defaults" or "Changed": all seven parameters count, and a parameter put
    /// back reads as defaults again. Red under: any one of the seven not compared.
    func testTheParametersLabelReadsDefaultsOrChanged() {
        let defaults = HRTEMFilter.Parameters.defaults
        XCTAssertEqual(FFTRoomFormat.parametersSummary(defaults), "Mitchell's defaults")
        let edits: [(String, (inout HRTEMFilter.Parameters) -> Void)] = [
            ("delta", { $0.delta += 1 }), ("step", { $0.step += 1 }), ("cycles", { $0.cycles -= 1 }),
            ("smoothing", { $0.smoothing.toggle() }), ("order", { $0.order += 1 }), ("ro", { $0.ro += 0.1 }),
            ("lowFrequencyPercent", { $0.lowFrequencyPercent += 1 })]
        for (name, edit) in edits {
            var p = defaults
            edit(&p)
            XCTAssertEqual(FFTRoomFormat.parametersSummary(p), "Changed", name)
            p = defaults
            XCTAssertEqual(FFTRoomFormat.parametersSummary(p), "Mitchell's defaults", "\(name) put back")
        }
    }

    /// The last run's status: the n × n size, the passes ("1 pass"), and the share flagged at one decimal, the reader's mark.
    /// Red under: "1 passes"; the share at two decimals or none; the size from another number.
    func testTheLastRunsStatus() {
        XCTAssertEqual(FFTRoomFormat.filterStatus(n: 512, passes: 37, finalDelta: 5.1, locale: Self.posix),
                       "512 × 512 px · 37 passes · 5.1 % flagged")
        XCTAssertEqual(FFTRoomFormat.filterStatus(n: 256, passes: 1, finalDelta: 0.04, locale: Self.posix),
                       "256 × 256 px · 1 pass · 0.0 % flagged")
        XCTAssertEqual(FFTRoomFormat.filterStatus(n: 64, passes: 99, finalDelta: 12.34, locale: Self.posix),
                       "64 × 64 px · 99 passes · 12.3 % flagged")
        XCTAssertEqual(FFTRoomFormat.filterStatus(n: 512, passes: 37, finalDelta: 5.1, locale: Self.german),
                       "512 × 512 px · 37 passes · 5,1 % flagged")
    }

    /// A click the kit refuses for no power (a constant region) or a NaN (ImagoKit 0.6.0 refuses by name) shows the KIT's reason, one
    /// sentence everywhere a spot is read — the row, the footer, ⌘C and VoiceOver — and is not a measurement (no parts, not counted
    /// for the mask). Red under: an app sentence in its place; the reason missing from the spoken row.
    func testASpotTheKitRefusesForNoPowerShowsTheKitsReasonEverywhere() throws {
        let posix = Self.posix
        for (failure, sentence) in [(SpotMeasurementError.noPower, "Not measured: there is no power in the window once its mean is removed (a constant image or region)."),
                                    (.nonFinite, "Not measured: the image holds a NaN or an infinity, so its spectrum is not defined.")] {
            XCTAssertEqual(FFTRoomFormat.refusal(failure), sentence)
            let none = FFTSpot(number: 8, row: 1, col: 2, spectrumKey: Self.key, outcome: .refused(failure))
            XCTAssertNil(none.measured)
            XCTAssertEqual(FFTRoomFormat.spotValue(none, locale: posix), sentence)
            XCTAssertEqual(FFTRoomFormat.notMeasured(none.outcome), sentence)
            XCTAssertNil(FFTRoomFormat.measuredParts(none, locale: posix))
            XCTAssertEqual(FFTRoomFormat.spotSpoken(none, locale: posix), "Spot 8, \(sentence)")
        }
        // The refusals keep their own words through the same door; a spot still measuring or measured is not "not measured".
        XCTAssertEqual(FFTRoomFormat.notMeasured(.refused(.nearDC)), FFTRoomFormat.refusal(.nearDC))
    }

    /// An axis that is already reciprocal ("1/nm", "1/Å": a diffraction pattern) has |q| in the unit after the slash,
    /// worded as the Δq row words the same image: "nm", never "1/1/nm"; d stays in the axis's own unit. The finding's image
    /// (0.05 per nm, 256 px, d 1.6 1/nm): the Δq row reads 0.07812 nm and so does |q|'s unit. Red under: the fall-through
    /// label "1/1/nm"; the Å value not converted (0.625 Å beside the row's nm).
    func testAnAxisAlreadyReciprocalIsShownInTheUnitAfterTheSlash() {
        let posix = Self.posix
        XCTAssertEqual(FFTRoomFormat.spotValue(d: 1.6, q: 0.625, unit: "1/nm", locale: posix), "d 1.6 1/nm · |q| 0.625 nm")
        XCTAssertEqual(FFTRoomFormat.spotValue(d: 1.6, q: 0.625, unit: "1/Å", locale: posix), "d 1.6 1/Å · |q| 0.0625 nm")
        XCTAssertEqual(FFTRoomFormat.reciprocal(0.625, realUnit: "1/nm", locale: posix), "0.625 nm")
        XCTAssertEqual(FFTRoomFormat.frequencySteps(spacingX: 0.078125, unitsX: "nm", spacingY: 0.078125, unitsY: "nm",
                                                    locale: posix).x, "0.07812 nm", "the Δq row of the same image")
        XCTAssertFalse(FFTRoomFormat.spotValue(d: 1.6, q: 0.625, unit: "1/nm", locale: posix).contains("1/1/"))
        XCTAssertFalse(FFTRoomFormat.spotValue(d: 1.6, q: 0.625, unit: "1/Å", locale: posix).contains("1/1/"))
    }

    /// What VoiceOver gets of a printed string: "px⁻¹" is "per pixel" and " px" is " pixels"; everything else — nm⁻¹ included —
    /// is as printed. Red under: "px⁻¹" left as it is; " px" left as letters; the unit replaced before the count's "px".
    func testSpokenTextSaysPerPixelAndPixels() {
        XCTAssertEqual(FFTRoomFormat.spoken("0.5 px⁻¹ · d 2 px"), "0.5 per pixel · d 2 pixels")
        XCTAssertEqual(FFTRoomFormat.spoken("Bin width 0.003906 px⁻¹ · region 256 × 256 px · bin 0 (the DC) is not drawn"),
                       "Bin width 0.003906 per pixel · region 256 × 256 pixels · bin 0 (the DC) is not drawn")
        XCTAssertEqual(FFTRoomFormat.spoken("0.07812 nm⁻¹"), "0.07812 nm⁻¹")
        XCTAssertEqual(FFTRoomFormat.spoken("3 bins from 0 to 0.5 px⁻¹; mean |F|² from 10² to 10⁴"),
                       "3 bins from 0 to 0.5 per pixel; mean |F|² from 10² to 10⁴")
        XCTAssertEqual(FFTRoomFormat.spoken("0.4 nm"), "0.4 nm")
    }

    // MARK: The radial chart's axis

    /// The log axis is labelled on every n-th decade (`RadialChartScale.decadeMarks`, fed the chart's bins at the plot the 120-pt
    /// chart leaves, 48 pt at the least, and 16 pt between labels): bins spanning 10⁴ … 10¹¹ — the finding's eight labels —
    /// get 10⁴, 10⁷, 10¹⁰; 10³ … 10⁶ get one per decade; no bin, none. Red under: a label on every decade; the first mark at
    /// the smallest mean (3.2 × 10⁴ is not a decade).
    func testTheRadialChartLabelsEveryNthDecade() {
        typealias S = FFTRoomFormat.ChartSample
        func samples(_ means: [Double]) -> [S] { means.enumerated().map { S(bin: $0.offset + 1, q: Double($0.offset + 1), mean: $0.element, count: 4) } }
        XCTAssertEqual(FFTRoomFormat.powerAxisMarks(samples([3.2e4, 7e6, 1.1e9, 8.7e10])), [1e4, 1e7, 1e10], "10⁴ … 10¹¹: seven decades")
        XCTAssertEqual(FFTRoomFormat.powerAxisMarks(samples([2e3, 3e4, 4e5])), [1e3, 1e4, 1e5, 1e6], "three decades: each")
        XCTAssertEqual(FFTRoomFormat.powerAxisMarks(samples([6e3, 9e3])), [1e3, 1e4], "inside one decade")
        XCTAssertEqual(FFTRoomFormat.powerAxisMarks([]), [])
        XCTAssertEqual(FFTRoomFormat.chartHeight, 120, "the design note's cost")
        XCTAssertEqual(FFTRoomFormat.minimumLabelSpacing, 16)
        // The plot the labels are spaced on is what the 120-pt chart really leaves: 58 pt measured (`ChartProxy.plotSize` in an
        // `ImageRenderer`, 2026-10-14), so a floor above that would space them for a plot the chart does not have.
        XCTAssertEqual(FFTRoomFormat.chartPlotFloor, 48)
        XCTAssertLessThanOrEqual(FFTRoomFormat.chartPlotFloor, 58)
        // At the floor of the plot, no two labels of any span are closer than the minimum.
        for decades in 1...10 {
            let marks = FFTRoomFormat.powerAxisMarks(samples([1.5e2, 0.5 * pow(10, Double(2 + decades))]))
            for pair in zip(marks, marks.dropFirst()) {
                XCTAssertGreaterThanOrEqual((log10(pair.1) - log10(pair.0)) * FFTRoomFormat.chartPlotFloor / Double(decades),
                                            FFTRoomFormat.minimumLabelSpacing - 1e-9, "\(decades) decades")
            }
        }
    }

    // MARK: The design's words

    /// The sentences the design note fixes, word for word ("The badge and the
    /// notes, in these words", and the inspector and Info tables), and the few the inspector adds. Red under: any word
    /// changed.
    func testTheDesignsWordsAreExact() {
        XCTAssertEqual(FFTRoomFormat.unvalidatedWarning,
                       "Unvalidated: not compared with Digital Micrograph. A re-implementation of D. R. G. Mitchell's HRTEM filter script, never checked against its output.")
        XCTAssertEqual(FFTRoomFormat.offBinNote,
                       "On synthetic lattices, a lattice half a bin off a Fourier bin keeps 5–57 % of its amplitude in a 128 px region and 77–97 % at 256 px; other sizes are not measured. The Nyquist wave is cut to 1.6 × 10⁻⁴. Intensities are not preserved: the output's mean is below the input's.")
        XCTAssertEqual(FFTRoomFormat.neighbourNote, "Another peak within 3 bins: d may be off by up to 0.3 %.")
        XCTAssertEqual(FFTRoomFormat.regionHint,
                       "Drag on the image to draw a region; drag it to move it, a corner to resize it, outside it to pan. Clear Region to draw another.")
        XCTAssertEqual(FFTRoomFormat.infoUnwindowed, "Unwindowed: the bright cross is the region's edges.")
        XCTAssertEqual(FFTRoomFormat.infoSpotsWindowed, "Spots are measured on a Hann-windowed, mean-removed copy.")
        XCTAssertEqual(FFTRoomFormat.infoDCNotDrawn, "The DC is not drawn.")
        // The inspector's own.
        XCTAssertEqual(FFTRoomFormat.noRegionPossible, "The image is under 32 px on a side: no region can be drawn.")
        XCTAssertEqual(FFTRoomFormat.noSpots, "Click a spot on the transform to measure its spacing.")
        XCTAssertEqual(FFTRoomFormat.profileEmpty, "No bin outside the DC holds any power.")
        XCTAssertEqual(FFTRoomFormat.displayValueNote,
                       "Values are log₁₀(|F|² ÷ (W·H)²), as drawn. The window changes the picture, never a number.")
        XCTAssertEqual(FFTRoomFormat.smoothingHelp, "A Butterworth low-pass on both masks. Order and Ro act only when it is on.")
    }

    /// The angle reads with one decimal and names its reference spot.
    func testAnAngleNamesItsReferenceSpot() {
        XCTAssertEqual(FFTRoomFormat.angleText(FFTSpotAngles.Angle(degrees: 35.24, reference: 2), locale: Locale(identifier: "en_US")), "35.2° to 2")
        XCTAssertEqual(FFTRoomFormat.angleText(FFTSpotAngles.Angle(degrees: 90, reference: 1), locale: Locale(identifier: "de_DE")), "90,0° to 1")
    }
}
