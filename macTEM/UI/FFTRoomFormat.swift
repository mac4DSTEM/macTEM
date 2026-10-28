//
//  FFTRoomFormat.swift
//  Role: what the FFT room's inspector READS as: what is transformed, a typed region, Δq and the Nyquist frequency, a spot's d and |q| in the shown units
//        with its refusals and notes, the radial chart's bins and readout, the mask count, the HRTEM filters' seven
//        parameters with the core's own ranges, the last run's status. Pure and nonisolated, so a test pins every string
//        (macTEMTests/FFTRoomFormatTests.swift) and nothing here draws.
//
//        The numbers are TEMCore's and reach the screen through `UnitDisplay.number` in the reader's
//        locale (no grouping), four significant digits for a d, a |q| and a frequency; the units are R8's, which are
//        `FFTUnits`: nm and nm⁻¹ whenever the image's unit is a length, the file's own unit otherwise, px and px⁻¹
//        uncalibrated. This file adds no arithmetic to a core's number except unit factors (the Nyquist frequency is
//        n · Δq / 2, a closed form of the sampling) and the bin interval of the chart's readout.
//

import Foundation
#if canImport(TEMCore)
import TEMCore
import TEMSession
import ImagoCore
import ImagoFFT
import ImagoFilters
#endif

nonisolated enum FFTRoomFormat {

    // MARK: What is transformed (R1)

    /// "region 256 × 256 px at (812, 404)" (the position is Left and Top, a column and a row) or "the whole image, 2048 × 1024
    /// px"; `withPosition: false` leaves the position off a region, for a sentence that names only what the numbers are of.
    static func transformed(_ crop: PixelCrop?, imageWidth: Int, imageHeight: Int, withPosition: Bool = true) -> String {
        guard let crop else { return "the whole image, \(imageWidth) × \(imageHeight) px" }
        let size = "region \(crop.width) × \(crop.height) px"
        return withPosition ? "\(size) at (\(crop.col), \(crop.row))" : size
    }

    /// The Info tab's two rows: "Region at (812, 404)" / "The whole image", and the size "256 × 256 px".
    static func transformedKind(_ crop: PixelCrop?) -> String {
        crop.map { "Region at (\($0.col), \($0.row))" } ?? "The whole image"
    }

    static func pixelSize(_ crop: PixelCrop?, imageWidth: Int, imageHeight: Int) -> String {
        "\(crop?.width ?? imageWidth) × \(crop?.height ?? imageHeight) px"
    }

    // MARK: The typed region (R1)

    /// The three numbers the Region section takes in pixels.
    nonisolated enum RegionField: CaseIterable, Sendable {
        case left, top, size

        var title: String {
            switch self {
            case .left: "Left"
            case .top: "Top"
            case .size: "Size"
            }
        }

        /// What VoiceOver calls the field: the unit spelled out, so "px" is not read letter by letter (the kit's
        /// `NumericFieldSpeech` speaks a title that names "pixel" once and adds nothing). The row shows `title`.
        var spokenTitle: String {
            switch self {
            case .left: "Left in pixels"
            case .top: "Top in pixels"
            case .size: "Size in pixels"
            }
        }

        var identifier: String {
            switch self {
            case .left: "fft.region.left"
            case .top: "fft.region.top"
            case .size: "fft.region.size"
            }
        }

        /// The field's number in `crop`: the column, the row, the side.
        func value(of crop: PixelCrop) -> Int {
            switch self {
            case .left: crop.col
            case .top: crop.row
            case .size: crop.width
            }
        }
    }

    /// `current` with `value` typed into `field`, through the registered clamps (`FFTRegion.typed`); nil when no region is
    /// possible on this image.
    static func region(typing value: Int, into field: RegionField, current: PixelCrop, width: Int, height: Int) -> PixelCrop? {
        var left = current.col, top = current.row, size = current.width
        switch field {
        case .left: left = value
        case .top: top = value
        case .size: size = value
        }
        return FFTRegion.typed(left: left, top: top, size: size, width: width, height: height)
    }

    static let regionHint = "Drag on the image to draw a region; drag it to move it, a corner to resize it, outside it to pan. Clear Region to draw another."
    static let noRegionPossible = "The image is under 32 px on a side: no region can be drawn."

    // MARK: Δq and the Nyquist frequency

    /// The frequency step between neighbouring bins on each axis, "0.0625 nm⁻¹", in the unit the spectrum was made in
    /// (`PowerSpectrum.unitsX`) brought to the shown one.
    static func frequencySteps(spacingX: Double, unitsX: String, spacingY: Double, unitsY: String,
                               locale: Locale = .autoupdatingCurrent) -> (x: String, y: String) {
        (frequency(spacingX, units: unitsX, locale: locale), frequency(spacingY, units: unitsY, locale: locale))
    }

    /// The Nyquist frequency of `count` samples with step `spacing`, n · Δq / 2 (n / 2 in Double: an odd side has the same
    /// Nyquist frequency as 1 / (2 · scale)), and the spacing it is, d = 1 / q in the real unit: "10 nm⁻¹ · d 0.1 nm".
    static func nyquist(spacing: Double, count: Int, units: String, locale: Locale = .autoupdatingCurrent) -> String {
        let q = spacing * Double(count) / 2
        let d = FFTUnits.length(1 / q, unit: realUnit(ofSpectrumUnit: units))
        return "\(frequency(q, units: units, locale: locale)) · d \(number(d.value, locale: locale)) \(d.label)"
    }

    /// The unit of the image a spectrum unit came from: "1/nm" → "nm", "1/px" → "px"; a diffraction image's spectrum, in "nm",
    /// came from "1/nm".
    static func realUnit(ofSpectrumUnit units: String) -> String {
        units.hasPrefix("1/") && units.count > 2 ? String(units.dropFirst(2)) : "1/" + units
    }

    static let infoUnwindowed = "Unwindowed: the bright cross is the region's edges."
    static let infoSpotsWindowed = "Spots are measured on a Hann-windowed, mean-removed copy."
    static let infoDCNotDrawn = "The DC is not drawn."

    private static func frequency(_ q: Double, units: String, locale: Locale) -> String {
        let shown = FFTUnits.spectrumUnit(units)
        return "\(number(q * shown.factor, locale: locale)) \(shown.label)"
    }

    // MARK: Spots (R3; R4)

    static let noSpots = "Click a spot on the transform to measure its spacing."
    static let neighbourNote = "Another peak within 3 bins: d may be off by up to 0.3 %."

    /// A length in the image's unit as shown, "0.4 nm" (R8).
    static func length(_ d: Double, unit: String, locale: Locale = .autoupdatingCurrent) -> String {
        let shown = FFTUnits.length(d, unit: unit)
        return "\(number(shown.value, locale: locale)) \(shown.label)"
    }

    /// A spatial frequency, in the reciprocal of the image's unit, as shown, "2.5 nm⁻¹" (R8).
    static func reciprocal(_ q: Double, realUnit unit: String, locale: Locale = .autoupdatingCurrent) -> String {
        let shown = FFTUnits.reciprocal(q, realUnit: unit)
        return "\(number(shown.value, locale: locale)) \(shown.label)"
    }

    /// A spot's two numbers, "d 0.4 nm" and "|q| 2.5 nm⁻¹", for a row that stacks them when it is narrow.
    static func spotParts(d: Double, q: Double, unit: String, locale: Locale = .autoupdatingCurrent) -> (d: String, q: String) {
        ("d \(length(d, unit: unit, locale: locale))", "|q| \(reciprocal(q, realUnit: unit, locale: locale))")
    }

    /// "d 0.4 nm · |q| 2.5 nm⁻¹".
    static func spotValue(d: Double, q: Double, unit: String, locale: Locale = .autoupdatingCurrent) -> String {
        let parts = spotParts(d: d, q: q, unit: unit, locale: locale)
        return "\(parts.d) · \(parts.q)"
    }

    /// "35.2° to 1": a spot's angle to the reference spot (the first measured one), one decimal.
    static func angleText(_ angle: FFTSpotAngles.Angle, locale: Locale = .autoupdatingCurrent) -> String {
        "\(Num.fixed(angle.degrees, 1, locale: locale))° to \(angle.reference)"
    }

    /// The numbers of a measured spot; nil while it is measuring and for a refused one.
    static func measuredParts(_ spot: FFTSpot, locale: Locale = .autoupdatingCurrent) -> (d: String, q: String)? {
        spot.measured.map { spotParts(d: $0.d, q: $0.q, unit: $0.units, locale: locale) }
    }

    /// What a spot's row reads, and what ⌘C copies.
    static func spotValue(_ spot: FFTSpot, locale: Locale = .autoupdatingCurrent) -> String {
        switch spot.outcome {
        case .measuring: "Measuring…"
        case .measured(let m): spotValue(d: m.d, q: m.q, unit: m.units, locale: locale)
        case .refused(let failure): refusal(failure)
        }
    }

    /// Why a spot was not measured, in the words the row, the footer and ⌘C share; nil while it is measuring and for a measured one.
    static func notMeasured(_ outcome: FFTSpot.Outcome) -> String? {
        switch outcome {
        case .measuring, .measured: nil
        case .refused(let failure): refusal(failure)
        }
    }

    /// What VoiceOver says for the row: the number first, "px" as pixels. The neighbour flag is the glyph's own element, with its
    /// own label.
    static func spotSpoken(_ spot: FFTSpot, locale: Locale = .autoupdatingCurrent) -> String {
        var words = ["Spot \(spot.number)"]
        switch spot.outcome {
        case .measuring:
            words.append("measuring")
        case .measured(let m):
            // The neighbour flag is the glyph's own label (its sentence), not repeated in the row's.
            let parts = spotParts(d: m.d, q: m.q, unit: m.units, locale: locale)
            words += [parts.d, parts.q]
        case .refused(let failure):
            words.append(refusal(failure))
        }
        return spoken(words.joined(separator: ", "))
    }

    /// `text` as VoiceOver should say it: "px⁻¹" as "per pixel" and "px" as "pixels" (read letter by letter otherwise).
    static func spoken(_ text: String) -> String {
        text.replacing(FFTUnits.reciprocalPixelLabel, with: "per pixel").replacing(" px", with: " pixels")
    }

    /// Why a click measured nothing. The first two are the design's words (3 bins is `SpotMeasurement`'s DC refusal radius, 2 its
    /// centroid window's half-width).
    static func refusal(_ failure: SpotMeasurementError) -> String {
        switch failure {
        case .nearDC: "Not measured: the peak nearest the click is within 3 bins of the centre."
        case .nearEdge: "Not measured: the peak nearest the click is within 2 bins of the edge."
        case .mixedUnits: "Not measured: the axes are in different units."
        case .crop: "Not measured: the region does not lie inside the image."
        case .fftSetup(let width, let height): "Not measured: the Fourier transform of \(width) × \(height) px could not be set up."
        case .outside: "Not measured: the click is outside the spectrum."
        case .zeroFrequency: "Not measured: one of the spots is at the zero frequency."      // the kit's angle between two spots; the room measures one
        case .nonFinite: "Not measured: the image holds a NaN or an infinity, so its spectrum is not defined."   // ImagoKit 0.6.0
        case .noPower: "Not measured: there is no power in the window once its mean is removed (a constant image or region)."   // ImagoKit 0.6.0
        }
    }

    /// "Measured on a Hann-windowed copy of region 256 × 256 px." — what the spots' spectrum is of, no position.
    static func measuredOn(_ crop: PixelCrop?, imageWidth: Int, imageHeight: Int) -> String {
        "Measured on a Hann-windowed copy of \(transformed(crop, imageWidth: imageWidth, imageHeight: imageHeight, withPosition: false))."
    }

    /// The accuracy `SpotMeasurement` measured under 256 px (1–5 % at 64 px, 0.5–3 % at 128 px); nil from 256 px up, where the
    /// noise-free band holds. The smaller side decides: a whole image may be any shape.
    static func accuracyNote(width: Int, height: Int) -> String? {
        min(width, height) < 256 ? "With noise, d is good to 1–5 % at 64 px and 0.5–3 % at 128 px." : nil
    }

    /// The bins Measure at… takes, whole bins from the centre: the bin (h/2 + ky, w/2 + kx), so kx runs from −w/2 to
    /// w − 1 − w/2.
    static func binRange(width: Int, height: Int) -> String {
        "Whole bins from the centre: kx \(-(width / 2)) to \(width - 1 - width / 2), ky \(-(height / 2)) to \(height - 1 - height / 2)."
    }

    /// "2 of 3 spots in the mask": a spot the mask can take is a measured one (a refused or a measuring spot has no centroid).
    static func maskSummary(_ spots: [FFTSpot]) -> String {
        let usable = spots.filter { $0.measured != nil }
        let on = usable.filter(\.inMask).count
        return "\(on) of \(usable.count) \(usable.count == 1 ? "spot" : "spots") in the mask"
    }

    // MARK: The radial chart (R6)

    /// One bin as charted: its index, its centre in the shown unit, its mean |F|² and its pixel count.
    nonisolated struct ChartSample: Equatable, Sendable {
        let bin: Int
        let q: Double
        let mean: Double
        let count: Int
    }

    static let profileUnavailable = "Not available: the axes are in different units."
    static let profileEmpty = "No bin outside the DC holds any power."

    /// The profile's bins as drawn (`RadialProfile.points`: from bin 1, each at its centre), |q| times `factor` (the spectrum
    /// unit's, `FFTUnits.spectrumUnit`); the mean is a power and keeps its value.
    static func chartSamples(_ profile: RadialProfile, factor: Double) -> [ChartSample] {
        drawable(profile.points.map { ChartSample(bin: $0.bin, q: $0.q * factor, mean: $0.mean, count: $0.count) })
    }

    /// The bins a log axis can draw: a positive, finite mean (a bin of zero power, as a noise-free plant has, has no place on
    /// it).
    static func drawable(_ samples: [ChartSample]) -> [ChartSample] {
        samples.filter { $0.mean > 0 && $0.mean.isFinite }
    }

    /// The chart's height, in points: fixed at 120 (the design note's cost); the width is the inspector's.
    static let chartHeight: Double = 120
    /// The least height the 120-pt chart gives its plot area, in points, once the x axis's labels and title and the padding
    /// are taken out: 58 pt as `ChartProxy.plotSize` reads it in an `ImageRenderer` render (2026-10-14, the review-fix
    /// session's scratch probe), so 48 leaves 10 pt for a different font size or a title that wraps.
    static let chartPlotFloor: Double = 48
    /// The closest two labels on the log axis may be, in points: a caption-size line with its superscript.
    static let minimumLabelSpacing: Double = 16

    /// The powers of ten the log y axis is labelled at: every n-th decade (`RadialChartScale.decadeMarks`) so that none is closer
    /// than `minimumLabelSpacing` to the next on a plot `chartPlotFloor` tall. Empty without a bin.
    static func powerAxisMarks(_ samples: [ChartSample]) -> [Double] {
        guard let low = samples.map(\.mean).min(), let high = samples.map(\.mean).max() else { return [] }
        return RadialChartScale.decadeMarks(lowest: low, highest: high, plotHeight: chartPlotFloor, minimumSpacing: minimumLabelSpacing)
    }

    /// The bin whose centre is nearest the pointer's |q|; the ends hold beyond the chart.
    static func nearest(_ samples: [ChartSample], toX x: Double) -> ChartSample? {
        samples.min { abs($0.q - x) < abs($1.q - x) }
    }

    /// "|q| 0.75 – 1 nm⁻¹ · mean |F|² 3.21 × 10⁵ · 128 px": bin k spans [k·w, (k + 1)·w) in the profile's unit. A profile bin
    /// is not a ring, so there is no d here. `binWidth` is in the shown unit.
    static func readout(_ sample: ChartSample, binWidth: Double, label: String, locale: Locale = .autoupdatingCurrent) -> String {
        let low = number(Double(sample.bin) * binWidth, locale: locale)
        let high = number(Double(sample.bin + 1) * binWidth, locale: locale)
        return "|q| \(low) – \(high) \(label) · mean |F|² \(power(sample.mean, locale: locale)) · \(sample.count) px"
    }

    /// "Bin width 0.3125 nm⁻¹ · region 256 × 256 px · bin 0 (the DC) is not drawn".
    static func caption(binWidth: Double, label: String, what: String, locale: Locale = .autoupdatingCurrent) -> String {
        "Bin width \(number(binWidth, locale: locale)) \(label) · \(what) · bin 0 (the DC) is not drawn"
    }

    /// The chart's spoken overview.
    static func profileSummary(_ samples: [ChartSample], label: String, locale: Locale = .autoupdatingCurrent) -> String {
        guard let first = samples.first, let last = samples.last,
              let low = samples.map(\.mean).min(), let high = samples.map(\.mean).max() else { return "No bins" }
        return "\(samples.count) \(samples.count == 1 ? "bin" : "bins") from \(number(first.q, locale: locale)) to "
            + "\(number(last.q, locale: locale)) \(label); mean |F|² from \(power(low, locale: locale)) to \(power(high, locale: locale))"
    }

    /// A power as three digits and a decade: "3.21 × 10⁵", a whole decade "10⁵", decade 0 the digits alone. The power spans
    /// ten decades, so no fixed-point spelling reads.
    static func power(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return "—" }
        guard value != 0 else { return "0" }
        var exponent = Int(floor(log10(abs(value))))
        var mantissa = value / pow(10, Double(exponent))
        // log10 and pow are not exact at a decade: bring the mantissa into [1, 10) first.
        while abs(mantissa) >= 10 { mantissa /= 10; exponent += 1 }
        while abs(mantissa) < 1 { mantissa *= 10; exponent -= 1 }
        // Three digits can round up into the next decade (9.996 → 10.0).
        mantissa = (mantissa * 100).rounded() / 100
        if abs(mantissa) >= 10 { mantissa /= 10; exponent += 1 }
        let digits = number(mantissa, 3, locale: locale)
        guard exponent != 0 else { return digits }
        let decade = "10" + superscript(exponent)
        return abs(mantissa) == 1 ? (mantissa < 0 ? "-" : "") + decade : "\(digits) × \(decade)"
    }

    private static func superscript(_ n: Int) -> String {
        let digit = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        return (n < 0 ? "⁻" : "") + String(abs(n)).map { digit[Int(String($0)) ?? 0] }.joined()
    }

    // MARK: The HRTEM filters

    /// The six numbers of `HRTEMFilter.Parameters` the section types (Smoothing is a switch), with the ranges the filter
    /// accepts — it refuses a value outside them and never clamps, so the field does.
    nonisolated enum FilterParameter: CaseIterable, Sendable {
        case delta, step, cycles, order, ro, lowFrequency

        var title: String {
            switch self {
            case .delta: "Delta"
            case .step: "Step"
            case .cycles: "Cycles"
            case .order: "Order"
            case .ro: "Ro"
            case .lowFrequency: "Low frequency"
            }
        }

        var unit: String? {
            switch self {
            case .delta, .lowFrequency: "%"
            case .step, .cycles, .order, .ro: nil
            }
        }

        /// `HRTEMFilter.Parameters.outOfRange`'s ranges.
        var range: ClosedRange<Double> {
            switch self {
            case .delta: 0...50
            case .step: 1...10
            case .cycles: 1...99
            case .order: 1...20
            case .ro: 0.01...3
            case .lowFrequency: 0...20
            }
        }

        var isInteger: Bool { self == .cycles || self == .order }

        var identifier: String {
            switch self {
            case .delta: "fft.filter.delta"
            case .step: "fft.filter.step"
            case .cycles: "fft.filter.cycles"
            case .order: "fft.filter.order"
            case .ro: "fft.filter.ro"
            case .lowFrequency: "fft.filter.lowFrequency"
            }
        }

        /// "0–50 %".
        func rangeText(locale: Locale = .autoupdatingCurrent) -> String {
            let low = FFTRoomFormat.number(range.lowerBound, locale: locale), high = FFTRoomFormat.number(range.upperBound, locale: locale)
            return "\(low)–\(high)" + (unit.map { " \($0)" } ?? "")
        }

        /// What the parameter does, with its range, for the tooltip.
        func help(locale: Locale = .autoupdatingCurrent) -> String {
            let what: String
            switch self {
            case .delta: what = "Stop once this percentage of the bins is flagged as background"
            case .step: what = "How far the flagging threshold rises each pass, in percentage points"
            case .cycles: what = "The most passes"
            case .order: what = "The order of the Butterworth low-pass on both masks"
            case .ro: what = "The low-pass's half-point radius, as a fraction of half the size"
            case .lowFrequency: what = "The radius of the low-frequency taper, in percent of half the size"
            }
            return "\(what) (\(rangeText(locale: locale)))"
        }

        func value(in parameters: HRTEMFilter.Parameters) -> Double {
            switch self {
            case .delta: parameters.delta
            case .step: parameters.step
            case .cycles: Double(parameters.cycles)
            case .order: Double(parameters.order)
            case .ro: parameters.ro
            case .lowFrequency: parameters.lowFrequencyPercent
            }
        }

        /// `parameters` with `value` typed into this parameter: clamped into the range, rounded for the whole numbers; a value
        /// that is not finite changes nothing.
        func applying(_ value: Double, to parameters: HRTEMFilter.Parameters) -> HRTEMFilter.Parameters {
            guard value.isFinite else { return parameters }
            let held = min(max(value, range.lowerBound), range.upperBound)
            var out = parameters
            switch self {
            case .delta: out.delta = held
            case .step: out.step = held
            case .cycles: out.cycles = Int(held.rounded())
            case .order: out.order = Int(held.rounded())
            case .ro: out.ro = held
            case .lowFrequency: out.lowFrequencyPercent = held
            }
            return out
        }
    }

    static let smoothingHelp = "A Butterworth low-pass on both masks. Order and Ro act only when it is on."

    /// What the closed Parameters row reads: Mitchell's script defaults or "Changed" (all seven count).
    static func parametersSummary(_ parameters: HRTEMFilter.Parameters) -> String {
        parameters == .defaults ? "Mitchell's defaults" : "Changed"
    }

    /// "512 × 512 px · 37 passes · 5.1 % flagged": the run's size, its passes and the share of bins flagged when the loop
    /// stopped.
    static func filterStatus(n: Int, passes: Int, finalDelta: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let share = finalDelta.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(1)))
        return "\(n) × \(n) px · \(passes) \(passes == 1 ? "pass" : "passes") · \(share) % flagged"
    }

    static let unvalidatedWarning = "Unvalidated: not compared with Digital Micrograph. A re-implementation of D. R. G. Mitchell's HRTEM filter script, never checked against its output."
    static let offBinNote = "On synthetic lattices, a lattice half a bin off a Fourier bin keeps 5–57 % of its amplitude in a 128 px region and 77–97 % at 256 px; other sizes are not measured. The Nyquist wave is cut to 1.6 × 10⁻⁴. Intensities are not preserved: the output's mean is below the input's."

    // MARK: The spectrum's display

    static let displayValueNote = "Values are log₁₀(|F|² ÷ (W·H)²), as drawn. The window changes the picture, never a number."

    // MARK: Numbers

    /// `digits` significant digits (four for a d, a |q| and a frequency), the reader's decimal mark, no grouping.
    fileprivate static func number(_ value: Double, _ digits: Int = 4, locale: Locale) -> String {
        UnitDisplay.number(value, digits: digits, locale: locale)
    }
}

// MARK: - The Settings tab's sections, in order

/// The FFT room's Settings sections, top to bottom, as data: `FFTRoomInspectorSettings` draws exactly this list (pinned by
/// FFTRoomWiringTests). Export is the last section, plain buttons (control placement standard, 2026-10-22; it was a pull-down row
/// right after Calibration since the 2026-10-15 drive found the old last section below the window: the buttons are tall enough
/// to need the column's end, and the standard puts every room's Export there). Display is second and open: an image room's
/// order is Calibration · Display · the job · Export (control placement §2).
nonisolated enum FFTRoomSections {
    enum Section: CaseIterable, Sendable {
        case calibration, display, region, spots, radialProfile, maskedInverse, filters, export
    }

    /// Every section once; Masked Inverse only once a spot is measured (a refused spot has no centroid).
    static func order(hasMeasuredSpot: Bool) -> [Section] {
        [.calibration, .display, .region, .spots, .radialProfile] + (hasMeasuredSpot ? [.maskedInverse] : [])
            + [.filters, .export]
    }
}
