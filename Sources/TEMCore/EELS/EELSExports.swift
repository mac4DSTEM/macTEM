// The EELS room's text exports beside the per-pixel CSV and the method JSON (the owner's drive, 2026-10-23: "the options could be like in the EDS room"): the results
// table, the shown spectrum and the regions' rows as CSV. Pure strings from the session's values; every file carries its provenance and the references of
// the methods that made its numbers (`EELSLiterature`).
import Foundation
import FormatoCore
import FormatoMSA
import ShellEDXModel

/// The literature each EELS method follows, as the room's tooltips, the figure subtitle and every export name it. A method is named with its
/// reference, as scientific software does; no trust label is written.
package nonisolated enum EELSLiterature {
    /// The log-ratio t/λ (thickness, t in nm).
    package static let thickness = "Malis, Cheng and Egerton, J. Electron Microsc. Tech. 8 (1988) 193"
    /// The edge model and the composition from it.
    package static let edges = "exSpy 7185a4d1 with the dft GOS tables (Segger, Guzzinati and Kohl, v1.5.0)"
    /// The Fourier-ratio, Fourier-log and Richardson-Lucy deconvolutions.
    package static let deconvolution = "Egerton, EELS in the Electron Microscope, 3rd ed. (2011), ch. 4"
    /// The export header line naming the thickness and edge references.
    package static let headerLine = "references: thickness: " + thickness + "; edges: " + edges
    /// The figure subtitle's short form of the methods and their references.
    package static let figureLine = "log-ratio t/λ (Malis, Cheng and Egerton 1988), edge model (exSpy, dft GOS)"
    /// The results header's References tooltip: each method with its reference.
    package static let tooltip = "t/λ and t: the log-ratio method, " + thickness + ". Edges, at% and wt%: SpectroKit's edge model, " + edges
        + ". Deconvolution: " + deconvolution + "."
}

package nonisolated enum EELSExports {
    private static func g(_ v: Double?) -> String { v.flatMap { $0.isFinite ? String(format: "%.9g", $0) : nil } ?? "" }
    private static func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// The results table: one row per edge (onset, I and its 1σ, areal density, at% and wt% each with its 1σ, the power-law exponent, below detection,
    /// why there is none) and, when one was used, a line naming the deconvolution and its parameters, and the fit quality. A fit-only edge says so in the
    /// `unavailable` cell, and so does a row with no at% (the table's tooltip and the Results room give the same words).
    package static func resultsCSV(_ rows: [EELSEdgeRow], fileName: String, regionName: String, thickness: String, method: String,
                                   deconvolution: String? = nil, quality: String? = nil) -> String {
        var out = ["# macTEM EELS results, file: \(fileName), region: \(regionName), \(EELSLiterature.headerLine)",
                   "# \(thickness)",
                   "# \(method)"]
        if let deconvolution { out.append("# deconvolution: \(deconvolution)") }
        if let quality { out.append("# fit quality: \(quality)") }
        out.append("edge,onset_eV,intensity,intensity_sigma,areal_density_per_nm2,atomic_percent,atomic_percent_sigma,weight_percent,weight_percent_sigma,"
                   + "exponent_r,below_detection,unavailable")
        for r in rows {
            let why = r.unavailable ?? (r.fitOnly ? EELSEdgeRow.fitOnlyWords : nil) ?? (r.notDetected ? EELSEdgeRow.notDetectedWords : nil)
                ?? (r.atomicPercent == nil ? r.atomicUnavailable : nil)
            out.append([quoted(r.title), g(r.onsetEV), g(r.intensity), g(r.intensityStd), g(r.arealDensityPerNM2), g(r.atomicPercent), g(r.atomicSigma),
                        g(r.weightPercent), g(r.weightSigma), g(r.exponent), r.belowDetection ? "true" : "false", why.map(quoted) ?? ""].joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The shown spectrum: the low loss then the core loss, each channel's energy and counts, and the model where the fit holds one.
    package static func spectrumCSV(_ plot: EELSPlotData, fileName: String) -> String {
        var out = ["# macTEM EELS spectrum, file: \(fileName), region: \(plot.regionName), \(plot.pixels) px, counts summed over the region",
                   "segment,energy_eV,counts,model"]
        for (i, c) in plot.low.counts.enumerated() { out.append("low_loss,\(g(plot.low.energy(i))),\(g(c)),") }
        if let d = plot.lowDeconvolved {
            for (i, c) in d.counts.enumerated() { out.append("low_loss_deconvolved,\(g(d.energy(i))),\(g(c)),") }
        }
        if let core = plot.core {
            for (i, c) in core.counts.enumerated() {
                let m = plot.model.flatMap { i < $0.count ? $0[i] : nil }
                out.append((plot.coreDeconvolved ? "core_loss_deconvolved," : "core_loss,") + "\(g(core.energy(i))),\(g(c)),\(g(m))")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// What the room's spectrum MSA file states about the microscope: the beam energy and the two angles the room uses (the file's or typed) and the
    /// stage tilt the file states; nil where there is none.
    package struct MSAMicroscope: Equatable, Sendable {
        package var beamEnergyKeV: Double?
        package var convergenceMrad: Double?
        package var collectionMrad: Double?
        package var alphaTiltDegrees: Double?
        package init(beamEnergyKeV: Double? = nil, convergenceMrad: Double? = nil, collectionMrad: Double? = nil, alphaTiltDegrees: Double? = nil) {
            self.beamEnergyKeV = beamEnergyKeV; self.convergenceMrad = convergenceMrad; self.collectionMrad = collectionMrad; self.alphaTiltDegrees = alphaTiltDegrees
        }
    }

    /// The shown spectrum as an EMSA/MAS file, as the EDS room writes its own (FormatoKit's `MSAWriter`, RosettaSciIO's `file_writer`: latin-1, CR LF,
    /// `Y` data printed with `%f`). An MSA file holds one spectrum on one axis, so it is the core loss when the file has one (the Fourier-ratio
    /// deconvolved one when the plot shows it), else the low loss; the Spectrum CSV keeps both and the model. The axis is in eV, the signal EELS
    /// (`SIGNALTYPE ELS`), the microscope as `BEAMKV`, `CONVANGLE`, `COLLANGLE` and `XTILTSTGE` where known. The counts are the region's sums as plotted.
    package static func spectrumMSA(_ plot: EELSPlotData, fileName: String, microscope: MSAMicroscope, creator: String = "macTEM") throws -> Data {
        let segment: (curve: EELSPlotCurve, words: String)
        if let core = plot.core {
            segment = (core, plot.coreDeconvolved ? "core loss, Fourier-ratio deconvolved" : "core loss")
        } else {
            segment = (plot.low, "low loss")
        }
        let counts = segment.curve.counts
        var bytes = Data(capacity: counts.count * 8)
        for c in counts { withUnsafeBytes(of: c.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        let array = try FormatoArray(dataType: .float64, shape: [counts.count], bytes: bytes)
        let title = "\(fileName) \(plot.regionName) \(segment.words)"
        func entry(_ key: String, _ value: FormatoValue, _ units: String?, _ rule: String) -> FormatoMetadataEntry {
            FormatoMetadataEntry(key: key, value: value, units: units, provenance: FormatoProvenance(file: "", source: "\(creator) EELS room", rule: rule))
        }
        var entries = [entry("General.title", .text(title), nil, "the file, the region and the spectrum written")]
        if let kv = microscope.beamEnergyKeV { entries.append(entry("Acquisition_instrument.TEM.beam_energy", .number(kv), "kV", "the beam energy the room uses")) }
        if let a = microscope.convergenceMrad {
            entries.append(entry("Acquisition_instrument.TEM.convergence_angle", .number(a), "mrad", "the convergence semi-angle the room uses"))
        }
        if let b = microscope.collectionMrad {
            entries.append(entry("Acquisition_instrument.TEM.Detector.EELS.collection_angle", .number(b), "mrad", "the collection semi-angle the room uses"))
        }
        if let t = microscope.alphaTiltDegrees { entries.append(entry("Acquisition_instrument.TEM.Stage.tilt_alpha", .number(t), "°", "the stage tilt the file states")) }
        let signal = FormatoSignal(title: title, signalType: "EELS",
                                   axes: [FormatoAxis(name: "Energy loss", size: counts.count, scale: segment.curve.step, offset: segment.curve.origin, units: "eV",
                                                      navigate: false)],
                                   metadata: FormatoMetadata(entries), data: array)
        return try MSAWriter.encode(signal, creator: creator)
    }

    /// The regions' rows: name, shape's pixels, I total, t/λ, then each edge's I, 1σ, at% and its 1σ.
    package static func regionsCSV(_ rows: [EELSRegionRow], fileName: String) -> String {
        let edges = rows.flatMap(\.edges).reduce(into: [String]()) { out, e in if !out.contains(e.title) { out.append(e.title) } }
        var header = ["region", "pixels", "i_total", "t_over_lambda"]
        for e in edges { header += ["\(e) intensity", "\(e) intensity_sigma", "\(e) atomic_percent", "\(e) atomic_percent_sigma"].map(quoted) }
        var out = ["# macTEM EELS regions, file: \(fileName), \(EELSLiterature.headerLine)", header.joined(separator: ",")]
        for r in rows {
            var cells = [quoted(r.pin.name), "\(r.pixels)", g(r.totalCounts), g(r.tOverLambda)]
            for e in edges {
                let row = r.edges.first { $0.title == e }
                cells += [g(row?.intensity), g(row?.intensityStd), g(row?.atomicPercent), g(row?.atomicSigma)]
            }
            out.append(cells.joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
