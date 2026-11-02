// The EELS room on the EDS chassis (design docs/design/eels-room.md, slice 1): the pure parts. Which tiles the Maps control puts where and why a
// segment is off, the one energy axis with its gap, the thickness line, the cursor readout, the periodic table's answers. No view, no kit call that
// makes a number: every value is a field of the session's tiles, the kit's map or the kit's fit, formatted or ordered here.
import Foundation
import SpectroCore
import SpectroEELS
import ShellEDXModel

// MARK: - The Maps control

/// The five segments of the inspector's Maps control: what the anchor (ZLP, t/λ, t) or the edge tiles (at%, wt%) show.
package nonisolated enum EELSMapsSegment: String, CaseIterable, Sendable, Identifiable {
    case zlp, tOverLambda, thickness, atomicPercent, weightPercent

    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .zlp: "ZLP"
        case .tOverLambda: "t/λ"
        case .thickness: "t"
        case .atomicPercent: "at%"
        case .weightPercent: "wt%"
        }
    }

    /// The Maps section's status line while a stage is making maps, as the EDS room's ("Computing wt% maps…"): the maps the running stage makes, named as
    /// the Maps control names them (the picked segment where the stage makes it). nil when nothing runs, or the stage makes no map (Deconvolve).
    package static func status(computing stage: EELSStage?, selection: EELSMapsSegment) -> String? {
        let maps: String
        switch stage {
        case .none, .deconvolve?, .edges?: return nil
        case .align?: maps = EELSMapsSegment.zlp.title
        case .thickness?: maps = selection == .thickness ? EELSMapsSegment.thickness.title : EELSMapsSegment.tOverLambda.title
        case .fit?: maps = selection == .atomicPercent || selection == .weightPercent ? selection.title : "edge"
        }
        return "Computing \(maps) maps…"
    }
}

/// What the Maps control needs to know about the session, as values.
package nonisolated struct EELSMapsAvailability: Equatable, Sendable {
    package var alignState: EELSStageState
    package var thicknessState: EELSStageState
    package var fitState: EELSStageState
    package var hasMap: Bool
    package var hasLambda: Bool
    package var hasFit: Bool
    package var hasComposition: Bool
    /// The file holds a core loss and no zero-loss peak: no t/λ, no t, nothing to align.
    package var onlyCoreLoss: Bool
    package var fitBlocker: String?

    package init(alignState: EELSStageState, thicknessState: EELSStageState, fitState: EELSStageState, hasMap: Bool, hasLambda: Bool, hasFit: Bool,
                 hasComposition: Bool, onlyCoreLoss: Bool, fitBlocker: String?) {
        self.alignState = alignState; self.thicknessState = thicknessState; self.fitState = fitState; self.hasMap = hasMap; self.hasLambda = hasLambda
        self.hasFit = hasFit; self.hasComposition = hasComposition; self.onlyCoreLoss = onlyCoreLoss; self.fitBlocker = fitBlocker
    }

    /// Why `segment` cannot be picked now, in one sentence; nil when it can.
    package func disabledReason(_ segment: EELSMapsSegment) -> String? {
        switch segment {
        case .zlp:
            if onlyCoreLoss { return "This file holds no zero-loss peak to align." }
            return alignState == .notRun ? "Run Align first: it measures the zero-loss shift." : nil
        case .tOverLambda:
            if onlyCoreLoss { return "This file holds no low loss, so it has no t/λ." }
            return hasMap ? nil : "Run the thickness first: t/λ comes from it."
        case .thickness:
            if onlyCoreLoss { return "This file holds no low loss, so it has no t." }
            if !hasMap { return "Run the thickness first: t comes from t/λ." }
            return hasLambda ? nil : "Give a mean free path λ under Processing to get t in nm."
        case .atomicPercent:
            if !hasFit { return fitBlocker ?? "Run Fit first: pick edges, then Run." }
            return hasComposition ? nil : "at% needs two or more fitted elements."
        case .weightPercent:
            if !hasFit { return fitBlocker ?? "Run Fit first: pick edges, then Run." }
            return hasComposition ? nil : "wt% needs two or more fitted elements."
        }
    }

    /// The picked segment, or t/λ when the pick is off now (a stage was reset, a file changed).
    package func effective(_ picked: EELSMapsSegment) -> EELSMapsSegment { disabledReason(picked) == nil ? picked : .tOverLambda }

    /// The one caption under the control.
    package func caption(_ segment: EELSMapsSegment) -> String {
        if onlyCoreLoss { return "Composition without plural-scattering correction: this file holds only a core loss." }
        let stale = (segment == .atomicPercent || segment == .weightPercent ? fitState : thicknessState) == .stale
        let base: String
        switch segment {
        case .zlp: base = "The energy each spectrum's zero-loss peak was moved by, in eV."
        case .tOverLambda: base = "t/λ = ln(I total / I₀), the log-ratio method (\(EELSLiterature.thickness))."
        case .thickness: base = "t in nm from t/λ and the mean free path, the log-ratio method (\(EELSLiterature.thickness))."
        case .atomicPercent: base = "Atomic percent of each fitted element, from the edge model (\(EELSLiterature.edges))."
        case .weightPercent: base = "Weight percent of each fitted element, from the edge model and the kit's atomic masses (\(EELSLiterature.edges))."
        }
        return stale ? base + " ● Showing the last run; Run updates it." : base
    }
}

/// Which tiles are where: the anchor on the left, the rest on the right.
package nonisolated enum EELSMapsComposition {
    /// - Anchor: t/λ (I total in a file with only a core loss); ZLP and t on their segment. Right: the ZLP shift after Align (unless it is the anchor), then one
    ///   tile per fitted edge, or per element in at% or wt% when that segment is picked and exists. The room's other tiles (I₀, I total, ZLP centre before) are not
    ///   drawn: their numbers are in the per-pixel CSV.
    package static func compose(selection: EELSMapsSegment, onlyCoreLoss: Bool, tiles: [EELSMapTile], shiftTile: EELSMapTile?, modelTiles: [EELSMapTile])
        -> (anchor: EELSMapTile?, rest: [EELSMapTile]) {
        func tile(_ id: String) -> EELSMapTile? { tiles.first { $0.id == id } }
        let base = onlyCoreLoss ? tile("iTotal") : tile("tOverLambda")
        let anchor: EELSMapTile?
        switch selection {
        case .zlp: anchor = shiftTile ?? base
        case .thickness: anchor = tile("thickness") ?? base
        default: anchor = base
        }
        var rest: [EELSMapTile] = []
        // A flat shift (the file came aligned: 143's zero-loss peak sits at 0 eV in every pixel) says so in the Processing line; it is a tile only on the ZLP segment.
        if let shiftTile, anchor?.id != shiftTile.id, shiftTile.flatValueText == nil { rest.append(shiftTile) }
        let atTiles = modelTiles.filter { $0.id.hasPrefix("at-") }, wtTiles = modelTiles.filter { $0.id.hasPrefix("wt-") }
        if selection == .atomicPercent, !atTiles.isEmpty { rest += atTiles }
        else if selection == .weightPercent, !wtTiles.isEmpty { rest += wtTiles }
        else { rest += modelTiles.filter { $0.id.hasPrefix("edge-") } }
        return (anchor, rest)
    }

    /// The scan's width over its height, which `AnchoredMapsBlock` fits every tile to (the EDS block passes the same); 1 until a file is open.
    package static func aspect(nx: Int?, ny: Int?) -> Double { Double(max(nx ?? 1, 1)) / Double(max(ny ?? 1, 1)) }

    /// Whether a tile is from a stage that needs a new run (it stays drawn, dimmed).
    package static func isStale(_ id: String, thickness: EELSStageState, fit: EELSStageState, align: EELSStageState) -> Bool {
        if id.hasPrefix("edge-") || id.hasPrefix("at-") || id.hasPrefix("wt-") { return fit == .stale }
        if id == "zlpShift" { return false }
        return thickness == .stale
    }
}

/// The Maps section's display filter (control placement §11, DNA 5): the quantified maps (t/λ, t, at%, wt%), computed per pixel on few counts, are DRAWN
/// through `EELSMapFilter` (ImagoKit's separable filters, the EDS room's kernel); the edge intensities, the ZLP shift and the I tiles never are.
/// Only the picture changes: a tile's `values`, the status-line readout, the popover's histogram, the results and every export (the maps figure too) stay raw.
package nonisolated enum EELSMapDisplay {
    /// Whether `filter` applies to the tile `id`: the tile then carries the `filtered` tag.
    package static func isFiltered(tileID id: String, filter: EELSMapFilter) -> Bool {
        guard filter.isOn else { return false }
        return id == "tOverLambda" || id == "thickness" || id.hasPrefix("at-") || id.hasPrefix("wt-")
    }

    /// The values the tile draws: the kernel's output where it applies, the raw values otherwise. A new array; the tile is not changed.
    package static func shownValues(_ tile: EELSMapTile, filter: EELSMapFilter) -> [Double] {
        isFiltered(tileID: tile.id, filter: filter) ? filter.apply(tile.values, width: tile.width, height: tile.height) : tile.values
    }
}

/// How a tile's values become the 0...1 of its colour scale, and what its colour bar says.
package nonisolated enum EELSMapScale {
    package enum Mode: Equatable, Sendable { case zeroToMax, minToMax, diverging }

    package struct Scaled: Equatable, Sendable {
        package let values: [Double]
        package let low: Double
        package let high: Double
    }

    /// t/λ, t and I total run from their smallest to their largest (viridis), the zero-loss shift is centred on 0 (diverging), edges and at% run from 0 (black to the element's colour).
    package static func mode(forTileID id: String) -> Mode {
        if id == "zlpShift" || id == "zlpCentre" || id == "zlpCentreBefore" { return .diverging }
        if id.hasPrefix("edge-") || id.hasPrefix("at-") || id.hasPrefix("wt-") || id == "i0" { return .zeroToMax }
        return .minToMax
    }

    /// A map whose finite pixels all hold one value has no range: it is drawn flat (`flatLevel` on `flatColormapIsGray`) and its tile says the value.
    package static func isFlat(_ values: [Double]) -> Bool {
        var seen: Double?
        for v in values where v.isFinite {
            if let s = seen { if s != v { return false } } else { seen = v }
        }
        return seen != nil
    }

    /// The level a flat map is drawn at on a neutral grey ramp: the middle of the scale, never the white of a diverging scale's centre.
    package static let flatLevel = 0.5

    /// The values of a flat map for the raster: `flatLevel` where finite, NaN stays NaN.
    package static func flatValues(_ values: [Double]) -> [Double] { values.map { $0.isFinite ? flatLevel : .nan } }

    /// NaN stays NaN (the raster draws it at the bottom of the scale).
    package static func scaled(_ values: [Double], mode: Mode) -> Scaled {
        let finite = values.filter { $0.isFinite }
        switch mode {
        case .zeroToMax:
            let top = finite.max() ?? 0
            guard top > 0 else { return Scaled(values: values.map { $0.isFinite ? 0 : .nan }, low: 0, high: 1) }
            return Scaled(values: values.map { $0.isFinite ? min(max($0 / top, 0), 1) : .nan }, low: 0, high: top)
        case .minToMax:
            guard let lo = finite.min(), let hi = finite.max(), hi > lo else {
                return Scaled(values: values.map { $0.isFinite ? 0 : .nan }, low: finite.min() ?? 0, high: finite.max() ?? 1)
            }
            return Scaled(values: values.map { $0.isFinite ? ($0 - lo) / (hi - lo) : .nan }, low: lo, high: hi)
        case .diverging:
            // Centred on 0, reaching the larger of |1st percentile| and |99th percentile| (the display range the EDS room gives a filtered map): one
            // pixel far out (a zero-loss peak the alignment lost at the scan's edge) no longer squeezes every other pixel into the white of the centre.
            // A map whose percentiles are both 0 takes its largest |value|; beyond the range a pixel takes the end colour.
            let range = robustHalfRange(finite)
            let m = range > 0 ? range : (finite.map { abs($0) }.max() ?? 0)
            guard m > 0 else { return Scaled(values: values.map { $0.isFinite ? 0.5 : .nan }, low: -1, high: 1) }
            return Scaled(values: values.map { $0.isFinite ? min(max(($0 + m) / (2 * m), 0), 1) : .nan }, low: -m, high: m)
        }
    }

    /// The half range of a diverging scale: max(|p1|, |p99|) of the finite values, percentiles linear between ranks as NumPy's default.
    package static func robustHalfRange(_ finite: [Double], low: Double = 0.01, high: Double = 0.99) -> Double {
        let sorted = finite.sorted()
        guard !sorted.isEmpty else { return 0 }
        func percentile(_ q: Double) -> Double {
            let position = q * Double(sorted.count - 1), i = Int(position.rounded(.down)), j = min(i + 1, sorted.count - 1)
            return sorted[i] + (sorted[j] - sorted[i]) * (position - Double(i))
        }
        return max(abs(percentile(low)), abs(percentile(high)))
    }
}

// MARK: - One energy axis with a gap

/// The spectrum's x axis: the low loss and the core loss side by side on one energy scale, each segment as wide as its share of the energy it spans, a fixed
/// gap between them for the energies the file does not hold. Widths in the plot's points (any unit; the arithmetic is the same).
package nonisolated struct EELSOneAxis: Equatable, Sendable {
    package struct Segment: Equatable, Sendable {
        package let energy: ClosedRange<Double>
        package let x: ClosedRange<Double>
    }

    package let segments: [Segment]
    package let width: Double
    /// The marked gap in x, and the energies it skips; nil when the two windows touch or there is no core loss.
    package let gap: ClosedRange<Double>?
    package let gapEnergy: ClosedRange<Double>?

    /// The energies of the low loss and of the core loss that are drawn. They differ from the two windows only when these overlap (a Dual-EELS pair: low loss
    /// -150 to 1364 eV, core loss from 150 eV): the low loss is drawn up to where the core loss starts, the core loss from there, so the detector's dead tail
    /// of the low loss is never drawn over the core loss. Nil when one segment holds everything.
    package let lowShown: ClosedRange<Double>?
    package let coreShown: ClosedRange<Double>?

    /// A segment keeps at least `minimumShare` of the width left once the gap is taken, so a 300 eV low loss beside a 3000 eV core loss stays readable.
    package init(low: ClosedRange<Double>, core: ClosedRange<Double>?, width: Double, gapWidth: Double = 16, minimumShare: Double = 0.2) {
        self.width = width
        guard let core else {
            segments = [Segment(energy: low, x: 0...width)]
            gap = nil; gapEnergy = nil; lowShown = nil; coreShown = nil
            return
        }
        if core.lowerBound <= low.lowerBound || core.upperBound <= low.upperBound {
            // The core loss starts before the low loss or ends inside it: one axis over both, nothing to cut.
            segments = [Segment(energy: low.lowerBound...max(low.upperBound, core.upperBound), x: 0...width)]
            gap = nil; gapEnergy = nil; lowShown = nil; coreShown = nil
            return
        }
        let overlap = core.lowerBound <= low.upperBound
        let gapW = overlap ? 0 : gapWidth
        let lowEnd = overlap ? core.lowerBound : low.upperBound
        let usable = max(width - gapW, 0)
        let lowSpan = max(lowEnd - low.lowerBound, 1e-9), coreSpan = max(core.upperBound - core.lowerBound, 1e-9)
        let share = min(max(lowSpan / (lowSpan + coreSpan), minimumShare), 1 - minimumShare)
        let lowWidth = usable * share
        segments = [Segment(energy: low.lowerBound...lowEnd, x: 0...lowWidth), Segment(energy: core, x: (lowWidth + gapW)...(usable + gapW))]
        gap = overlap ? nil : lowWidth...(lowWidth + gapW)
        gapEnergy = overlap ? nil : low.upperBound...core.lowerBound
        lowShown = low.lowerBound...lowEnd
        coreShown = core
    }

    /// The low loss and the core loss cut to a zoomed energy window (nil: the whole axis), for `init`: the core loss alone when the window misses the low loss, nil when it
    /// misses both. The spectrum's zoom and pan move the window (as the EDS spectrum's, Paul 2026-10-23); the two segments and the gap follow from what is left.
    package static func windowed(low: ClosedRange<Double>, core: ClosedRange<Double>?, window: ClosedRange<Double>?) -> (low: ClosedRange<Double>, core: ClosedRange<Double>?)? {
        guard let window else { return (low, core) }
        func cut(_ r: ClosedRange<Double>) -> ClosedRange<Double>? {
            let lo = max(r.lowerBound, window.lowerBound), hi = min(r.upperBound, window.upperBound)
            return lo < hi ? lo...hi : nil
        }
        let l = cut(low), c = core.flatMap(cut)
        if let l { return (l, c) }
        return c.map { ($0, nil) }
    }

    /// Every energy the spectrum can show: the low loss's start to the later of the two ends.
    package static func domain(low: ClosedRange<Double>, core: ClosedRange<Double>?) -> ClosedRange<Double> {
        low.lowerBound...max(low.upperBound, core?.upperBound ?? low.upperBound)
    }

    /// The gap's one label, "skips 300–800 eV"; nil without a gap.
    package var gapLabel: String? {
        gapEnergy.map { "skips \(EELSRoomFormat.sig($0.lowerBound, 4))–\(EELSRoomFormat.sig($0.upperBound, 4)) eV" }
    }

    /// The x of an energy; an energy beyond either end is clamped to it, one inside the gap has none.
    package func x(forEnergy e: Double) -> Double? {
        if let gapEnergy, e > gapEnergy.lowerBound, e < gapEnergy.upperBound { return nil }
        guard let first = segments.first, let last = segments.last else { return nil }
        if e <= first.energy.lowerBound { return first.x.lowerBound }
        if e >= last.energy.upperBound { return last.x.upperBound }
        guard let s = segments.first(where: { $0.energy.contains(e) }) else { return nil }
        let span = s.energy.upperBound - s.energy.lowerBound
        return span > 0 ? s.x.lowerBound + (e - s.energy.lowerBound) / span * (s.x.upperBound - s.x.lowerBound) : s.x.lowerBound
    }

    /// The energy at an x; nil in the gap or off the axis.
    package func energy(atX x: Double) -> Double? {
        guard let s = segments.first(where: { $0.x.contains(x) }) else { return nil }
        let w = s.x.upperBound - s.x.lowerBound
        return w > 0 ? s.energy.lowerBound + (x - s.x.lowerBound) / w * (s.energy.upperBound - s.energy.lowerBound) : s.energy.lowerBound
    }

    /// Tick energies inside `range`: a step of 1, 2 or 5 times a power of ten giving about `target` ticks.
    package static func ticks(in range: ClosedRange<Double>, target: Double = 5) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0, target > 0 else { return [] }
        let raw = span / target
        let mag = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? 10 * mag
        var out: [Double] = []
        var t = (range.lowerBound / step).rounded(.up) * step
        while t <= range.upperBound + step * 1e-9 { out.append(t); t += step }
        return out
    }

    /// The edge onset within `window` eV of `energy` (the hover readout snaps to it), the nearest one; nil when none is.
    package static func snappedOnset(_ energy: Double, among onsets: [Double], within window: Double = 5) -> Double? {
        onsets.filter { abs($0 - energy) <= window }.min { abs($0 - energy) < abs($1 - energy) }
    }
}

// MARK: - Thickness statistics

/// The thickness line's numbers over a region (or the whole map): the kit's per-pixel t/λ and t, ordered. The median and the quartiles are numpy's (linear).
package nonisolated struct EELSThicknessStats: Equatable, Sendable {
    package let pixels: Int
    package let total: Int
    package let median: Double
    package let q1: Double
    package let q3: Double
    package let medianThicknessNM: Double?

    package init(pixels: Int, total: Int, median: Double, q1: Double, q3: Double, medianThicknessNM: Double?) {
        self.pixels = pixels; self.total = total; self.median = median; self.q1 = q1; self.q3 = q3; self.medianThicknessNM = medianThicknessNM
    }

    package static func quantile(sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let position = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lo = Int(position.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (position - Double(lo))
    }

    /// nil when no pixel of the region has a t/λ.
    package static func of(_ map: ThicknessMap, region: EDXRegion?) -> EELSThicknessStats? {
        let mask = region.flatMap { $0.mask(nx: map.nx, ny: map.ny) }
        var t: [Double] = [], nm: [Double] = []
        var total = 0
        for (i, p) in map.pixels.enumerated() where mask?[i] ?? true {
            total += 1
            if let v = p.tOverLambda, v.isFinite { t.append(v) }
            if let v = p.thicknessNM, v.isFinite { nm.append(v) }
        }
        guard !t.isEmpty else { return nil }
        t.sort(); nm.sort()
        return EELSThicknessStats(pixels: t.count, total: total, median: quantile(sorted: t, 0.5), q1: quantile(sorted: t, 0.25), q3: quantile(sorted: t, 0.75),
                                  medianThicknessNM: nm.isEmpty ? nil : quantile(sorted: nm, 0.5))
    }
}

// MARK: - Words

extension EELSRoomFormat {
    package static func fixed(_ v: Double, _ places: Int, locale: Locale = .autoupdatingCurrent) -> String {
        v.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(places)))
    }

    package static func sig(_ v: Double, _ digits: Int, locale: Locale = .autoupdatingCurrent) -> String {
        v.formatted(.number.locale(locale).grouping(.never).precision(.significantDigits(1...max(digits, 1))))
    }

    /// An energy in eV as the rest of the app writes a number (`Num.sig`): three significant digits, no trailing zeros, a value that rounds to nothing is 0.
    package static func eV(_ v: Double, locale: Locale = .autoupdatingCurrent) -> String {
        sig(abs(v) < 0.0005 ? 0 : v, 3, locale: locale)
    }

    /// A log axis label for the decade `10^n`: "1", "10", "100", "1000", then "1e4" (plain text the left margin holds and the eye reads at caption size).
    package static func logTickLabel(decade n: Int) -> String {
        n <= 3 ? String(Int(pow(10, Double(max(n, 0))))) : "1e\(n)"
    }

    /// The left margin the counts labels need: the widest label at `pointsPerCharacter` (a 10 pt digit is about 6.3 pt wide: at 5.8 "69 528 956" lost its first
    /// digit, Paul's drive 2026-10-23), a tick's room and the padding, never below `minimum`.
    package static func leftMargin(labels: [String], pointsPerCharacter: Double = 6.6, minimum: Double = 36) -> Double {
        max(minimum, ceil(Double(labels.map(\.count).max() ?? 0) * pointsPerCharacter) + 16)
    }

    /// The results header: "Results · Region 1 · λ Iakoubovskii" (which λ the t comes from), or "λ not set".
    package static func resultsHeader(region: String, lambdaNM: Double?, lambdaSource: String?) -> String {
        let lambda: String
        if lambdaNM != nil { lambda = "λ " + (lambdaSource ?? "given") } else { lambda = "λ not set" }
        return "Results · \(region) · \(lambda)"
    }

    /// "t/λ 0.523 (IQR 0.481–0.571) · λ 120 nm, given · t 62.8 nm": the results panel's thickness line. A missing part says what it needs.
    package static func thicknessLine(_ stats: EELSThicknessStats?, lambdaNM: Double?, lambdaSource: String?, locale: Locale = .autoupdatingCurrent) -> String {
        var parts: [String] = []
        if let s = stats {
            parts.append("t/λ \(fixed(s.median, 3, locale: locale)) (IQR \(fixed(s.q1, 3, locale: locale))–\(fixed(s.q3, 3, locale: locale)))")
        } else {
            parts.append("t/λ not available")
        }
        if let lambdaNM {
            parts.append("λ \(sig(lambdaNM, 4, locale: locale)) nm" + (lambdaSource.map { ", \($0)" } ?? ""))
        } else {
            parts.append("λ not set")
        }
        if let nm = stats?.medianThicknessNM { parts.append("t \(sig(nm, 3, locale: locale)) nm") } else { parts.append("t needs λ") }
        return parts.joined(separator: " · ")
    }

    /// Where λ comes from, in a few words; nil for none.
    package static func lambdaSource(_ choice: EELSMeanFreePathChoice) -> String? {
        switch choice {
        case .none: nil
        case .given: "given"
        case .iakoubovskii(let rho, _, _): "Iakoubovskii, \(sig(rho, 4)) g/cm³"
        }
    }

    /// Where a value comes from: the file, typed, or nowhere.
    package static func valueSource(typed: Double?, file: Double?) -> String {
        if typed != nil { return "typed" }
        return file != nil ? "from the file" : "not set"
    }

    /// The Edges section's line: "Quantify: C K 284 eV, O K 532 eV · Fit only: Cu L3 931 eV" (a part with no edge is left out).
    package static func pickedLine(_ picked: [CoreLossEdge], fitOnly: Set<String>) -> String {
        func list(_ edges: [CoreLossEdge]) -> String { edges.map { "\(EELSFitCompute.title($0)) \(sig($0.onsetEV, 5)) eV" }.joined(separator: ", ") }
        let quantify = picked.filter { !fitOnly.contains($0.element) }, only = picked.filter { fitOnly.contains($0.element) }
        return [quantify.isEmpty ? nil : "Quantify: " + list(quantify), only.isEmpty ? nil : "Fit only: " + list(only)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The results footer: model · background · convolution · deconvolution (what the fit on screen was made with).
    package static func fitFooter(hasFit: Bool, convolved: Bool, model: EELSFitModel = .exactNNLS, deconvolution: String = "no deconvolution") -> String {
        guard hasFit else { return "No fit yet" }
        let background = model == .mlls ? "power-law background, exponent by two areas" : "power-law background"
        return "\(model.title) · \(background) · " + (convolved ? "convolved with the low loss" : "not convolved") + " · \(deconvolution)"
    }

    /// What the fit says about its own numbers, for the results footer's popover (as the EDS room's notes). Each note is a sentence the room already
    /// writes elsewhere, only grouped, in this order: the picked edges refused before the fit (`refusals`), the edges the kit left with no answer, the
    /// composition's refusal, the exponent on a bound (once: the kit flags the fit, not an edge), each edge at or under 3σ, the MLLS not-detected
    /// elements, and the deconvolution's unanswered pixels (`unanswered`, left out of the fit). A fit-only edge's missing at% is a choice, not a note.
    package static func fitNotes(rows: [EELSEdgeRow], refusals: [String], unanswered: [EELSUnavailable?]?) -> [String] {
        var out = refusals
        for r in rows { if let why = r.unavailable { out.append("\(r.title): \(why)") } }
        for r in rows where !r.fitOnly {
            guard let why = r.atomicUnavailable, why != EELSEdgeRow.fitOnlyWords else { continue }
            let note = "at% not computed: \(why)"
            if !out.contains(note) { out.append(note) }
        }
        if rows.contains(where: \.exponentAtBound) { out.append(ResultRow.eelsExponentAtBound) }
        for r in rows where r.belowDetection && !r.fitOnly && !r.notDetected { out.append("\(r.title) " + ResultRow.eelsBelowDetection) }
        if let line = notDetectedLine(rows) { out.append(line) }
        if let unanswered, let line = EELSDeconvolveCompute.unansweredLine(unanswered) { out.append("deconvolution: " + line) }
        return out
    }

    /// The results footer, as the EDS room's: "2 notes · " and the fit quality; the quality alone when the fit has no note.
    package static func fitNotesSummary(notes: Int, quality: String) -> String {
        notes == 0 ? quality : "\(notes) \(notes == 1 ? "note" : "notes") · " + quality
    }

    /// The I cell: "43180000 ± 210000", sigma to two significant digits; I alone where the kit gives no sigma.
    package static func intensityText(_ row: EELSEdgeRow, locale: Locale = .autoupdatingCurrent) -> String {
        guard let i = row.intensity else { return "–" }
        guard let s = row.intensityStd else { return scientific(i, 4, locale: locale) }
        return scientific(i, 4, locale: locale) + " ± " + scientific(s, 2, locale: locale)
    }

    /// `sig` from 0.01 to 100 000; outside, "1.871e-4" (the mantissa to `digits` significant digits), so a tiny or a huge number stays a few characters wide.
    package static func scientific(_ v: Double, _ digits: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard v.isFinite, v != 0, abs(v) < 0.01 || abs(v) >= 1e5 else { return sig(v, digits, locale: locale) }
        var exponent = Int(floor(log10(abs(v))))
        var mantissa = v / pow(10, Double(exponent))
        // A mantissa that rounds up to 10 moves to the next power.
        let scale = pow(10, Double(max(digits, 1) - 1))
        if abs((mantissa * scale).rounded() / scale) >= 10 { exponent += 1; mantissa = v / pow(10, Double(exponent)) }
        return sig(mantissa, digits, locale: locale) + "e\(exponent)"
    }

    /// The at% cell: "44.4 ± 0.3" with its 1σ (`percent`), "below detection" for an edge at or under 3 sigma, never a bare 0.
    package static func atomicText(_ row: EELSEdgeRow, locale: Locale = .autoupdatingCurrent) -> String {
        if row.fitOnly { return "fit only" }
        if row.notDetected { return "not detected" }
        if row.belowDetection { return "below detection" }
        return row.atomicPercent.map { percent($0, row.atomicSigma, locale: locale) } ?? "–"
    }

    /// The results footer's part for the elements the kit counts as not detected: "N, O not detected (MLLS amount ≤ 0)"; nil when there is none.
    package static func notDetectedLine(_ rows: [EELSEdgeRow]) -> String? {
        var symbols: [String] = []
        for r in rows where r.notDetected {
            let symbol = String(r.title.split(separator: " ").first ?? Substring(r.title))
            if !symbols.contains(symbol) { symbols.append(symbol) }
        }
        return symbols.isEmpty ? nil : symbols.joined(separator: ", ") + " " + EELSEdgeRow.notDetectedWords
    }

    /// The wt% cell, as the at% cell.
    package static func weightText(_ row: EELSEdgeRow, locale: Locale = .autoupdatingCurrent) -> String {
        if row.fitOnly { return "fit only" }
        if row.notDetected { return "not detected" }
        if row.belowDetection { return "below detection" }
        return row.weightPercent.map { percent($0, row.weightSigma, locale: locale) } ?? "–"
    }

    /// "44.4 ± 0.31": the σ to two significant digits and the value to the same decimal place (the EDS room's rule), one decimal when there is no σ,
    /// at most three.
    package static func percent(_ value: Double, _ sigma: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return "–" }
        guard let sigma, sigma.isFinite, sigma > 0 else { return fixed(value, 1, locale: locale) }
        let places = max(0, min(3, 1 - Int(floor(log10(sigma)))))
        return fixed(value, places, locale: locale) + " ± " + fixed(sigma, places, locale: locale)
    }

    /// The fit quality value row and the footer's part: "RSS 1.234e5 · χ²ᵣ 1.04 (Pearson, 312 dof)"; the kit's RSS, and Pearson's χ² over the degrees
    /// of freedom (or why there is none).
    package static func fitQuality(_ q: EELSFitQuality, locale: Locale = .autoupdatingCurrent) -> String {
        let rss = "RSS " + scientific(q.rss, 4, locale: locale)
        guard let chi = q.reducedChiSquared else { return rss + " · " + (q.chiSquaredUnavailable ?? EELSFitQuality.noFreedom) }
        return rss + " · \u{03C7}\u{00B2}\u{1D63} " + sig(chi, 3, locale: locale) + " (Pearson, \(q.degreesOfFreedom) dof)"
    }

    /// "r · C K 3.42 · N K 3.31": the power-law exponent the kit fitted under each edge; nil when no row has one.
    package static func exponentsLine(_ rows: [EELSEdgeRow]) -> String? {
        let parts = rows.compactMap { r in r.exponent.map { "\(r.title) \(sig($0, 3))" } }
        return parts.isEmpty ? nil : "r · " + parts.joined(separator: " · ")
    }

    /// The status line over a map: "row 4 · col 3 · t/λ 0.52 · ZLP shift 0.01 eV · Mg 12.3 at%". `refusal` names why the pixel has no t/λ.
    /// `unanswered` names why the deconvolution left the pixel unanswered (it is then out of the fit and its edge tiles).
    package static func readout(x: Int, y: Int, tiles: [EELSMapTile], refusal: String?, unanswered: String? = nil,
                                locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["row \(y)", "col \(x)"]
        if let refusal { parts.append("t/λ: \(refusal)") }
        if let unanswered { parts.append("deconvolution: no answer, \(unanswered)") }
        for tile in tiles where tile.id == "tOverLambda" || tile.id == "iTotal" || tile.id == "zlpShift" || tile.id.hasPrefix("at-") || tile.id.hasPrefix("wt-") {
            guard x >= 0, y >= 0, x < tile.width, y < tile.height else { continue }
            let v = tile.values[y * tile.width + x]
            guard v.isFinite else { continue }
            parts.append("\(tile.title) \(sig(v, 4, locale: locale))" + (tile.unit.isEmpty ? "" : " \(tile.unit)"))
        }
        return parts.joined(separator: " · ")
    }

    /// The Processing section's one note: the line, and that the core loss follows the alignment when the file has one.
    package static func processingNote(align: EELSStageState, thickness: EELSStageState, alignmentReadout: String?, coreAligned: Bool) -> String {
        processingLine(align: align, thickness: thickness, alignmentReadout: alignmentReadout) + (coreAligned ? " The core loss is aligned with it." : "")
    }

    /// What Align moved: "shifts up to 1.25 eV", or, when no pixel moved by half a channel, "already aligned in the file, max |shift| 0 eV" (GMS aligns the
    /// zero-loss peak while it acquires: Paul's 143 has every centre at 0 eV before Align).
    package static func shiftSummary(_ shifts: [Double?], channelEV: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let largest = shifts.compactMap { $0 }.filter(\.isFinite).map(abs).max() ?? 0
        let text = eV(largest, locale: locale) + " eV"
        return largest < channelEV / 2 ? "already aligned in the file, max |shift| " + text : "shifts up to " + text
    }

    /// The Processing section's one line under its rows.
    package static func processingLine(align: EELSStageState, thickness: EELSStageState, alignmentReadout: String?) -> String {
        if let alignmentReadout { return "Aligned: " + alignmentReadout }
        if align == .notRun { return "Align —: Run aligns the zero-loss peak." }
        return "Align " + align.word + "."
    }
}

// MARK: - The periodic table's answers

/// Which edges the table can pick and how a click, a family and a line map to the session's picks.
package nonisolated enum EELSEdgeChoices {
    /// The elements with a bundled edge: every element with a K, L or M edge exSpy builds with the dft GOS (SpectroKit 0.12.0).
    package static let live: Set<String> = Set(CoreLossEdge.bundled.map(\.element))

    /// Why `symbol` cannot be picked, in the reason the cell's tooltip shows ("Au: no edge in 150–1665 eV"); nil when it can.
    /// `windowEV` is the core loss's energy range, named when known so a dimmed cell explains itself (Paul, 2026-10-23).
    package static func unavailableReason(symbol: String, offered: [CoreLossEdge], hasCoreLoss: Bool,
                                          windowEV: ClosedRange<Double>? = nil) -> String? {
        guard live.contains(symbol) else { return "no bundled edge" }
        guard hasCoreLoss else { return "this file holds no core loss" }
        guard !offered.contains(where: { $0.element == symbol }) else { return nil }
        guard let windowEV else { return "no edge of it in this core loss's energy window" }
        return "no edge in \(Int(windowEV.lowerBound.rounded()))\u{2013}\(Int(windowEV.upperBound.rounded())) eV"
    }

    /// The core loss's energy range, first channel to last.
    package static func window(of core: CoreLossSpectrumImage) -> ClosedRange<Double> {
        let a = core.energyOffsetEV, b = core.energyOffsetEV + core.energyScaleEV * Double(max(core.channels - 1, 0))
        return min(a, b)...max(a, b)
    }

    /// The edge a click picks, the strong one a microscopist reads first: K where it is offered, else L₂,₃ (L3, or the combined edge), else M₄,₅ (M5, or the
    /// combined edge), else the first offered.
    package static func defaultEdge(symbol: String, offered: [CoreLossEdge]) -> CoreLossEdge? {
        let own = offered.filter { $0.element == symbol }
        return own.first { $0.subshell == "K1" } ?? own.first { $0.subshell == "L3" || $0.subshell == "L2,3" }
            ?? own.first { $0.subshell == "M5" || $0.subshell == "M4,5" } ?? own.first
    }

    /// The families the right-click menu lists, K, L₁, L₂,₃, M₂,₃, M₄,₅, each with its edge.
    package static func families(symbol: String, offered: [CoreLossEdge]) -> [(name: String, edge: CoreLossEdge)] {
        let own = offered.filter { $0.element == symbol }
        var out: [(name: String, edge: CoreLossEdge)] = []
        if let k = own.first(where: { $0.subshell == "K1" }) { out.append((name: "K", edge: k)) }
        if let l1 = own.first(where: { $0.subshell == "L1" }) { out.append((name: "L₁", edge: l1)) }
        if let l = own.first(where: { $0.subshell == "L3" || $0.subshell == "L2,3" }) { out.append((name: "L₂,₃", edge: l)) }
        if let m = own.first(where: { $0.subshell == "M3" || $0.subshell == "M2,3" }) { out.append((name: "M₂,₃", edge: m)) }
        if let m = own.first(where: { $0.subshell == "M5" || $0.subshell == "M4,5" }) { out.append((name: "M₄,₅", edge: m)) }
        return out
    }
}
