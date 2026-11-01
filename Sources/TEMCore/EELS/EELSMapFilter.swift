//
//  EELSMapFilter.swift
//  Role: the EELS room's display filter for the quantified maps (t/λ, t, at%, wt%): a 3 × 3 average (the default) or a Gaussian of σ 1 px,
//        from ImagoKit's `SeparableFilters`, the same kernel the EDS room offers. It is applied to the values a tile DRAWS, never to the numbers:
//        the status-line readout, the exports and the results use the raw values. A pixel the kit could not make (NaN) is skipped by the kernel (the
//        average of its finite neighbours, normalised by the finite weights) and stays NaN itself.
//
//  MacEMUI 0.5.0 narrowed its EDS room API and `EDXMapFilter` is no longer visible outside MacEMUI, so the room keeps this copy of it
//  (same cases, titles and arithmetic). Delete when MacEMUI exposes the filter again.
//

import Foundation
import ImagoFilters

package nonisolated enum EELSMapFilter: String, CaseIterable, Identifiable, Sendable {
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
}
