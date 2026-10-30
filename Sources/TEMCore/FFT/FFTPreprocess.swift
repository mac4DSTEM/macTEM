// What the FFT room does to the transformed pixels before the transform, on ImagoKit: Gaussian smoothing (`SeparableFilters.gaussianFilter`),
// a band-pass (`BandpassFilters.differenceOfGaussians` or `.butterworth`) and a window (`WindowFunction.window2D`, scikit-image's
// `filters.window`) that tapers the region's edges so they stop streaking the spectrum. The filters and the window values are the kit's;
// the product with the pixels is `WindowFunction.apply`. Smoothing and band-pass are badged unvalidated until compared with Digital Micrograph.
import Foundation
import ImagoCore
import ImagoFilters

package nonisolated struct FFTPreprocess: Equatable, Sendable {
    package enum Window: String, CaseIterable, Sendable, Identifiable {
        case none, hann, hamming, blackman, tukey
        package var id: String { rawValue }
        package var title: String { rawValue.capitalized }
        /// scikit-image's `filters.window` families; Tukey at SciPy's default taper fraction.
        var type: WindowType? {
            switch self {
            case .none: nil
            case .hann: .hann
            case .hamming: .hamming
            case .blackman: .blackman
            case .tukey: .tukey(alpha: 0.5)
            }
        }
    }

    package enum Smoothing: Equatable, Sendable {
        case none
        /// Gaussian σ in pixels, the same along both axes.
        case gaussian(sigma: Double)
    }

    package enum Bandpass: Equatable, Sendable {
        case none
        /// `difference_of_gaussians` with the high σ at 1.6 × the low one (scikit-image's default).
        case differenceOfGaussians(lowSigma: Double)
        /// `butterworth` at this cutoff frequency ratio (0 to 0.5, exclusive of 0), order 2.
        case butterworth(cutoff: Double, highPass: Bool)
    }

    package var window = Window.none
    package var smoothing = Smoothing.none
    package var bandpass = Bandpass.none

    package init(window: Window = .none, smoothing: Smoothing = .none, bandpass: Bandpass = .none) {
        self.window = window; self.smoothing = smoothing; self.bandpass = bandpass
    }

    package var isNone: Bool { window == .none && smoothing == .none && bandpass == .none }

    /// "Hann window, Gaussian σ 2 px, difference of Gaussians (low σ 3 px)": what the Region view and the footer say.
    package var summary: String {
        var parts: [String] = []
        if case .gaussian(let s) = smoothing { parts.append("Gaussian \u{03C3} \(Self.num(s)) px") }
        switch bandpass {
        case .none: break
        case .differenceOfGaussians(let s): parts.append("difference of Gaussians (low \u{03C3} \(Self.num(s)) px)")
        case .butterworth(let c, let high): parts.append("Butterworth \(high ? "high" : "low")-pass at \(Self.num(c))")
        }
        if window != .none { parts.append("\(window.title) window") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    private static func num(_ v: Double) -> String { String(format: "%.3g", v) }

    /// The micrograph the transform sees: smoothed, band-passed, then windowed (the order a person reads the list in the inspector).
    package func apply(_ m: Micrograph) throws -> Micrograph {
        if isNone { return m }
        var px = m.pixels
        let rows = m.height, columns = m.width
        if case .gaussian(let sigma) = smoothing, sigma > 0 {
            px = try SeparableFilters.gaussianFilter(px, rows: rows, columns: columns, sigma: (row: sigma, column: sigma))
        }
        switch bandpass {
        case .none: break
        case .differenceOfGaussians(let low):
            px = try BandpassFilters.differenceOfGaussians(px, rows: rows, columns: columns, lowSigma: (row: low, column: low))
        case .butterworth(let cutoff, let highPass):
            px = try BandpassFilters.butterworth(px, rows: rows, columns: columns, cutoffFrequencyRatio: cutoff, highPass: highPass)
        }
        if let type = window.type {
            px = try WindowFunction.apply(type, to: px, rows: rows, columns: columns)
        }
        return try Micrograph(width: columns, height: rows, pixels: px, x: m.x, y: m.y)
    }
}

/// "Find spots": the strongest local maxima of the spectrum's display, off the centre, for the d-spacing readout. ImagoKit's
/// `PeakLocalMax.find` on the display values (the log of the power); the room then measures each with the existing spot estimator.
package nonisolated enum FFTSpotFinder {
    package struct Settings: Equatable, Sendable {
        /// The least distance between two peaks, in bins.
        package var minDistance = 8
        /// A peak must exceed this fraction of the display's range above its minimum (0 to 1).
        package var thresholdFraction = 0.75
        /// The most spots to put on the spectrum.
        package var count = 6
        /// Peaks within this many bins of the centre are the transform's own bright core, not reflections.
        package var centreExclusion = 6
        package init() {}
    }

    /// One peak the finder kept: its bin and its local contrast.
    package struct Found: Equatable, Sendable {
        package let row: Int
        package let column: Int
        /// The peak's display value minus the median of the ring around it (`ringRadii`, in bins): how far a sharp reflection
        /// stands out of its neighbourhood. A broad hump (a non-periodic feature's low-frequency power) is high but not contrasted.
        package let contrast: Float
    }

    /// The ring a peak's contrast is taken against: bins at a distance from `inner` to `outer` (inclusive) from the peak.
    package static let ringRadii = (inner: 3, outer: 6)

    /// The peaks as bins of the spectrum, highest local contrast first (`Found.contrast`; equal contrasts keep the kit's order,
    /// strongest first). `values` are the display's, row-major `width` x `height`; a spectrum is centrosymmetric, so a peak and its
    /// mirror are both found: only the half-plane with the larger (row, column) is kept. Every peak above the threshold is ranked
    /// before the cut to `count`, so a bright hump cannot crowd out a sharper reflection.
    package static func find(values: [Float], width: Int, height: Int, settings: Settings) throws -> [Found] {
        let finite = values.map { $0.isFinite ? $0 : -Float.infinity }
        guard let lo = finite.filter({ $0.isFinite }).min(), let hi = finite.max(), hi > lo else { return [] }
        let clean = finite.map { $0.isFinite ? $0 : lo }
        // The centre exclusion and one of each mirror pair (the half-plane dy > 0, or dy == 0 with dx > 0) are the kit's `SpectrumSymmetry`.
        let symmetry = SpectrumSymmetry(centreRow: height / 2, centreColumn: width / 2, excludedRadius: settings.centreExclusion)
        let peaks = try PeakLocalMax.find(clean, rows: height, columns: width, minDistance: settings.minDistance,
                                          thresholdAbs: Double(lo) + settings.thresholdFraction * Double(hi - lo),
                                          numPeaks: nil, symmetry: symmetry)
        let found = peaks.map { Found(row: $0.row, column: $0.column,
                                      contrast: contrast(clean, width: width, height: height, row: $0.row, column: $0.column)) }
        let ranked = found.enumerated().sorted { a, b in
            a.element.contrast > b.element.contrast || (a.element.contrast == b.element.contrast && a.offset < b.offset)
        }
        return ranked.prefix(max(settings.count, 0)).map(\.element)
    }

    /// The value at (`row`, `column`) minus the median of the ring around it (the lower middle of an even count); 0 when the ring
    /// holds no bin inside the spectrum.
    package static func contrast(_ values: [Float], width: Int, height: Int, row: Int, column: Int) -> Float {
        let (inner, outer) = ringRadii
        var ring: [Float] = []
        for dr in -outer...outer {
            for dc in -outer...outer {
                let d2 = dr * dr + dc * dc
                guard d2 >= inner * inner, d2 <= outer * outer else { continue }
                let r = row + dr, c = column + dc
                guard r >= 0, r < height, c >= 0, c < width else { continue }
                ring.append(values[r * width + c])
            }
        }
        guard !ring.isEmpty else { return 0 }
        ring.sort()
        return values[row * width + column] - ring[(ring.count - 1) / 2]
    }
}
