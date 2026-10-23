// The display filter of the quantified maps (wt%, at%, thickness), the kernel mac4DSTEM's Filter row offers: a 3 × 3 average (the default) or a
// Gaussian of σ 1 px, from ImagoKit's `SeparableFilters`. It is applied to the values a tile DRAWS, never to the numbers: the status-line readout, the
// exports and the results use the raw values. A pixel the kit could not make (NaN) is skipped by the kernel (the average of its finite neighbours is
// taken, normalised by the finite weights) and stays NaN itself, drawn as the scale's bottom. The colour scale of a filtered map is a display range, the
// 1st to the 99th percentile of the raw map.
import Foundation
import ImagoFilters

package nonisolated enum EDXMapFilter: String, CaseIterable, Identifiable, Sendable {
    case off, mean3x3, gaussian1px

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .off: "Off"
        case .mean3x3: "3 × 3 average"
        case .gaussian1px: "Gaussian σ 1 px"
        }
    }

    /// The kernel as a tile's tag names it.
    package var isOn: Bool { self != .off }

    /// `values` (row-major, `width` × `height`) through the kernel; unchanged when off or when the shape is wrong.
    package func apply(_ values: [Double], width: Int, height: Int) -> [Double] {
        guard isOn, width > 0, height > 0, values.count == width * height else { return values }
        let data = values.map { $0.isFinite ? $0 : 0 }, mask = values.map { $0.isFinite ? 1.0 : 0.0 }
        func smooth(_ a: [Double]) -> [Double]? {
            switch self {
            case .off: a
            case .mean3x3: try? SeparableFilters.uniformFilter(a, rows: height, columns: width, size: (row: 3, column: 3))
            case .gaussian1px: try? SeparableFilters.gaussianFilter(a, rows: height, columns: width, sigma: (row: 1, column: 1))
            }
        }
        guard let num = smooth(data), let den = smooth(mask) else { return values }
        return values.indices.map { values[$0].isFinite && den[$0] > 1e-12 ? num[$0] / den[$0] : .nan }
    }

    /// The `low` to `high` percentiles (fractions, linear between ranks as NumPy does) of the finite values; nil when there are none or no span.
    package static func displayRange(of values: [Double], low: Double = 0.01, high: Double = 0.99) -> ClosedRange<Double>? {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last, last > first else { return nil }
        func percentile(_ q: Double) -> Double {
            let position = q * Double(sorted.count - 1), i = Int(position.rounded(.down)), j = min(i + 1, sorted.count - 1)
            return sorted[i] + (sorted[j] - sorted[i]) * (position - Double(i))
        }
        let lo = percentile(low), hi = percentile(high)
        return hi > lo ? lo...hi : first...last
    }
}
