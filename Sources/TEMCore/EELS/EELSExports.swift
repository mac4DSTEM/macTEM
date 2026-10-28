// The EELS room's text exports beside the per-pixel CSV and the method JSON (the owner's drive, 2026-10-23: "the options could be like in the EDS room"): the results
// table, the shown spectrum and the regions' rows as CSV. Pure strings from the session's values; every file carries its provenance and the unvalidated badge.
import Foundation

package nonisolated enum EELSExports {
    private static func g(_ v: Double?) -> String { v.flatMap { $0.isFinite ? String(format: "%.9g", $0) : nil } ?? "" }
    private static func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// The results table: one row per edge (onset, I and its 1σ, areal density, at%, wt%, the power-law exponent, below detection, why there is none).
    package static func resultsCSV(_ rows: [EELSEdgeRow], fileName: String, regionName: String, thickness: String, method: String) -> String {
        var out = ["# macTEM EELS results, file: \(fileName), region: \(regionName), validation: none",
                   "# \(thickness)",
                   "# \(method)",
                   "edge,onset_eV,intensity,intensity_sigma,areal_density_per_nm2,atomic_percent,weight_percent,exponent_r,below_detection,unavailable"]
        for r in rows {
            out.append([quoted(r.title), g(r.onsetEV), g(r.intensity), g(r.intensityStd), g(r.arealDensityPerNM2), g(r.atomicPercent), g(r.weightPercent),
                        g(r.exponent), r.belowDetection ? "true" : "false", r.unavailable.map(quoted) ?? ""].joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The shown spectrum: the low loss then the core loss, each channel's energy and counts, and the model where the fit holds one.
    package static func spectrumCSV(_ plot: EELSPlotData, fileName: String) -> String {
        var out = ["# macTEM EELS spectrum, file: \(fileName), region: \(plot.regionName), \(plot.pixels) px, counts summed over the region",
                   "segment,energy_eV,counts,model"]
        for (i, c) in plot.low.counts.enumerated() { out.append("low_loss,\(g(plot.low.energy(i))),\(g(c)),") }
        if let core = plot.core {
            for (i, c) in core.counts.enumerated() {
                let m = plot.model.flatMap { i < $0.count ? $0[i] : nil }
                out.append("core_loss,\(g(core.energy(i))),\(g(c)),\(g(m))")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The regions' rows: name, shape's pixels, I total, t/λ, then each edge's I, 1σ and at%.
    package static func regionsCSV(_ rows: [EELSRegionRow], fileName: String) -> String {
        let edges = rows.flatMap(\.edges).reduce(into: [String]()) { out, e in if !out.contains(e.title) { out.append(e.title) } }
        var header = ["region", "pixels", "i_total", "t_over_lambda"]
        for e in edges { header += ["\(e) intensity", "\(e) intensity_sigma", "\(e) atomic_percent"].map(quoted) }
        var out = ["# macTEM EELS regions, file: \(fileName), validation: none", header.joined(separator: ",")]
        for r in rows {
            var cells = [quoted(r.pin.name), "\(r.pixels)", g(r.totalCounts), g(r.tOverLambda)]
            for e in edges {
                let row = r.edges.first { $0.title == e }
                cells += [g(row?.intensity), g(row?.intensityStd), g(row?.atomicPercent)]
            }
            out.append(cells.joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
