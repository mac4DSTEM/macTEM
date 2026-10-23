// The EDX room's composition maps and typed k-factors, on SpectroKit 0.8.1's public quantification API. Nothing here is a number
// of macTEM's own: `EDXQuantification.quantifyMaps` makes every pixel; this file chooses its inputs (the picked elements' net-count
// maps, the typed k, the region as the navigation mask) and words its refusals and its tile footers.
//
// Cliff-Lorimer with typed k, or with the computed k the room's pooled fit used (`PooledQuantification.kFactors`, public since
// SpectroKit 0.8.2; the maps then wait for the fit). Absorption, when the Quantification section asks for it and the file gives the
// geometry (`EDXQuantification.takeOffDegrees(metadata:)`) and, for Cliff-Lorimer, a thickness: the kit's per-pixel absorption takes ONE
// take-off angle where the pooled fit averages four segments, so a map with absorption differs slightly from the pooled number. The
// tile footer says whether it was applied, or why not.
import Foundation
import SpectroCore
import SpectroEDX

/// What the maps grid draws: the net counts of the line window, or a composition from `EDXQuantification.quantifyMaps`.
package nonisolated enum EDXMapMode: String, Sendable, Equatable, CaseIterable, Identifiable {
    case net
    case weight
    case atomic
    /// Mass thickness, kg/m²: only the zeta and cross-section methods give one.
    case massThickness

    package var id: String { rawValue }

    /// The unit the tile's values are in, as its colorbar names it.
    package var unit: String {
        switch self {
        case .net: "net counts"
        case .weight: "wt%"
        case .atomic: "at%"
        case .massThickness: "kg/m²"
        }
    }

    package var title: String {
        switch self {
        case .net: "Net"
        case .weight: "wt%"
        case .atomic: "at%"
        case .massThickness: "Thickness"
        }
    }
}

/// How the maps are quantified: Cliff-Lorimer with typed k, or the zeta-factor or ionisation cross-section method (both need the dose).
package nonisolated enum EDXMapMethod: String, Sendable, Equatable, CaseIterable, Identifiable {
    case cliffLorimer
    case zeta
    case crossSection

    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .cliffLorimer: "Cliff-Lorimer"
        case .zeta: "Zeta factor"
        case .crossSection: "Cross section"
        }
    }
    /// The factor's name in a sentence.
    package var factorName: String {
        switch self {
        case .cliffLorimer: "k-factor"
        case .zeta: "zeta factor"
        case .crossSection: "cross section"
        }
    }
}

/// What the zeta and cross-section methods need beyond the factors: the dose (beam current, live time, probe area), typed, until
/// FormatoKit reads them from the file, with the source of the factors. One live time for every pixel.
package nonisolated struct EDXDoseInputs: Equatable, Sendable {
    /// kg/m² per count unit, by element (the kit's convention, eXSpy `quantification_zeta_factor`).
    package var zeta: [String: Double] = [:]
    /// Ionisation cross sections, barn, by element.
    package var sectionsBarn: [String: Double] = [:]
    package var beamCurrentNA: Double?
    package var liveTimeSeconds: Double?
    package var probeAreaNm2: Double?
    /// Where the factors come from, in words; required.
    package var source = ""
    package var date = ""
    package init() {}
}

package nonisolated enum EDXQuantMaps {

    /// Why the room cannot draw a composition map yet, in words the status strip shows.
    package enum Refusal: Error, Equatable, LocalizedError {
        /// Computed k comes from the fit, which has not run (or did not give a k).
        case needsFit
        case tooFewElements(Int)
        case missingK([String])
        case noSource
        case missingFactor(EDXMapMethod, [String])
        case missingDose(String)
        case noMassThickness

        package var errorDescription: String? {
            switch self {
            case .needsFit:
                "The computed k comes from the fit: press Quantify, or choose Typed k-factors under Quantification."
            case .tooFewElements(let n):
                n == 0 ? "Pick at least two elements to quantify." : "Pick a second element to quantify: a composition needs two."
            case .missingK(let elements):
                "Type a k-factor for " + elements.joined(separator: ", ") + " under Quantification."
            case .noSource:
                "Name where the typed k-factors come from under Quantification."
            case .missingFactor(let method, let elements):
                "Type a \(method.factorName) for " + elements.joined(separator: ", ") + " under Quantification."
            case .missingDose(let what):
                "Type the \(what) under Quantification."
            case .noMassThickness:
                "Cliff-Lorimer gives a mass thickness only with the absorption correction (it needs the thickness and the detector geometry). Or choose the zeta factor or cross-section method under Quantification."
            }
        }
    }

    /// The quantified elements that have a map, with their maps in the same order: the inputs of `quantifyMaps`. An element whose
    /// line is off the axis has no window and so no map; it is left out, and the composition is of the elements that have one.
    package static func inputs(quantified: [String], windows: EDXCompute.Windows) -> (symbols: [String], maps: [[Double]]) {
        var symbols: [String] = [], maps: [[Double]] = []
        for s in quantified {
            guard let m = EDXCompute.elementMap(s, in: windows) else { continue }
            symbols.append(s); maps.append(m)
        }
        return (symbols, maps)
    }

    /// The kit's setup for `symbols`, with the words that say where its factors came from and what became of absorption.
    package struct Prepared: Sendable {
        package let setup: EDXQuantificationSetup
        /// "typed k: <source>", "computed k: <source>", "zeta factors: <source>" or "cross sections: <source>".
        package let factorText: String
        /// "absorption applied (take-off 21.6°, one angle)" or "absorption not applied: <why>".
        package let absorptionText: String
    }

    /// The line energies (keV) of the picked elements' windows, by element, for `EDXAbsorptionSetting.lineEnergiesKeV`.
    package static func lineEnergies(_ windows: EDXCompute.Windows) -> [String: Double] {
        var out: [String: Double] = [:]
        for w in windows.windows where w.window != nil && out[w.element] == nil {
            if let e = XRayLines.line(w.id)?.energy { out[w.element] = e }
        }
        return out
    }

    /// The kit's setup for `symbols` from the method: Cliff-Lorimer with the typed k or the fit's computed k, or zeta / cross section with
    /// the dose; with absorption where it is asked for and possible. Throws the refusal that says what to type or run.
    package static func prepare(method: QuantificationMethod, mapMethod: EDXMapMethod = .cliffLorimer, dose: EDXDoseInputs = EDXDoseInputs(),
                                symbols: [String], lineEnergies: [String: Double] = [:], fit: PooledQuantification? = nil,
                                metadata: SpectrumImageMetadata? = nil) throws -> Prepared {
        guard symbols.count >= 2 else { throw Refusal.tooFewElements(symbols.count) }
        func positive(_ v: Double?) -> Double? { v.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
        var setup: EDXQuantificationSetup
        let factorText: String
        switch mapMethod {
        case .cliffLorimer:
            var ks: [Double] = []
            var missing: [String] = []
            if method.kFactorSource == .typed {
                for s in symbols {
                    if let k = method.typedK.first(where: { $0.element == s })?.k, k > 0, k.isFinite { ks.append(k) } else { missing.append(s) }
                }
                guard missing.isEmpty else { throw Refusal.missingK(missing) }
                guard !method.kSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !method.kDate.isEmpty else { throw Refusal.noSource }
                factorText = "typed k: " + method.kSource
            } else {
                guard let fitK = fit?.kFactors, let source = fit?.kFactorSourceDescription else { throw Refusal.needsFit }
                for s in symbols {
                    if let k = fitK.first(where: { $0.element == s })?.k, k > 0, k.isFinite { ks.append(k) } else { missing.append(s) }
                }
                guard missing.isEmpty else { throw Refusal.needsFit }
                factorText = "computed k: " + source
            }
            setup = EDXQuantificationSetup(elements: symbols, method: .cliffLorimer(kFactors: ks, thicknessNm: nil))
        case .zeta, .crossSection:
            let table = mapMethod == .zeta ? dose.zeta : dose.sectionsBarn
            let missing = symbols.filter { positive(table[$0]) == nil }
            guard missing.isEmpty else { throw Refusal.missingFactor(mapMethod, missing) }
            guard !dose.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.noSource }
            guard let current = positive(dose.beamCurrentNA) else { throw Refusal.missingDose("beam current") }
            guard let live = positive(dose.liveTimeSeconds) else { throw Refusal.missingDose("live time") }
            let values = symbols.map { table[$0]! }
            if mapMethod == .zeta {
                setup = EDXQuantificationSetup(elements: symbols, method: .zeta(zetaFactors: values), beamCurrentNA: current, liveTimeSeconds: live)
                factorText = "zeta factors: " + dose.source
            } else {
                guard let area = positive(dose.probeAreaNm2) else { throw Refusal.missingDose("probe area") }
                setup = EDXQuantificationSetup(elements: symbols, method: .crossSection(sectionsBarn: values, probeAreaNm2: area),
                                               beamCurrentNA: current, liveTimeSeconds: live)
                factorText = "cross sections: " + dose.source
            }
        }
        // Absorption: asked for by the Quantification section, possible when the file gives the geometry (and, for Cliff-Lorimer, a thickness).
        var absorptionText = "absorption not applied to maps"
        if method.absorptionCorrection {
            let thickness = method.thickness.flatMap { positive($0.nanometres) }
            let energies = symbols.compactMap { lineEnergies[$0] }
            if case .cliffLorimer = mapMethod, thickness == nil {
                absorptionText = "absorption not applied: type the thickness"
            } else if energies.count != symbols.count {
                absorptionText = "absorption not applied: no line energy for every element"
            } else if let metadata {
                do {
                    let angle = try EDXQuantification.takeOffDegrees(metadata: metadata)
                    setup.absorption = EDXAbsorptionSetting(takeOffDegrees: angle, lineEnergiesKeV: energies)
                    if case .cliffLorimer(let ks, _) = setup.method { setup.method = .cliffLorimer(kFactors: ks, thicknessNm: thickness) }
                    absorptionText = "absorption applied (take-off \(String(format: "%.1f", angle))°, one angle)"
                } catch {
                    absorptionText = "absorption not applied: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
            } else {
                absorptionText = "absorption not applied: no detector geometry"
            }
        }
        return Prepared(setup: setup, factorText: factorText, absorptionText: absorptionText)
    }

    /// `prepare`'s setup alone (typed k, or zeta / cross section with the dose; no absorption).
    package static func setup(method: QuantificationMethod, mapMethod: EDXMapMethod = .cliffLorimer, dose: EDXDoseInputs = EDXDoseInputs(),
                              symbols: [String]) throws -> EDXQuantificationSetup {
        var m = method
        m.absorptionCorrection = false
        return try prepare(method: m, mapMethod: mapMethod, dose: dose, symbols: symbols).setup
    }

    /// The maps over the scan grid. The region is the navigation mask: a pixel outside it is excluded (composition 0), as the
    /// kit's mask does; the whole map masks nothing.
    package static func run(maps: [[Double]], nx: Int, ny: Int, setup: EDXQuantificationSetup, region: EDXRegion) throws -> EDXQuantificationMaps {
        let outside = region.mask(nx: nx, ny: ny).map { $0.map { !$0 } }
        return try EDXQuantification.quantifyMaps(intensityMaps: maps, rows: ny, columns: nx, setup: setup, navigationMask: outside)
    }

    /// The values a tile shows for `mode` (net is not a quantification and has none).
    package static func values(_ result: EDXQuantificationMaps, element index: Int, mode: EDXMapMode) -> [Double]? {
        switch mode {
        case .net: nil
        case .weight: result.weightPercent[index]
        case .atomic: result.atomicPercent[index]
        case .massThickness: nil
        }
    }

    /// The tile footer: the quantity, the factor source, what became of absorption, how many pixels failed and why, and the badge. The
    /// kit's `validation` string is the badge's key ("none" until a standard of known composition is measured).
    package static func footer(mode: EDXMapMode, factorText: String, absorptionText: String, dose: EDXDoseInputs? = nil,
                               result: EDXQuantificationMaps, masked: Int) -> String {
        let failed = result.failures.compactMap { $0 }
        // The order and the words of mac4DSTEM's tile footer (failed, masked, per-pixel, absorption, validation), with this app's own k source
        // and dose where it has them: one vocabulary for the shared EDX room (rooms design section 1).
        var parts: [String] = []
        if let first = failed.first { parts.append("\(failed.count) failed px: \(first)") }
        if masked > 0 { parts.append("\(masked) masked px") }
        parts.append("per-pixel, no \u{03C3}; pool a region for a \u{03C3}")
        parts.append(mode == .massThickness ? "\u{03C1}t (kg/m\u{00B2})" : mode.title)
        parts.append(factorText)
        if let dose, let c = dose.beamCurrentNA, let t = dose.liveTimeSeconds { parts.append("\(String(format: "%g", c)) nA, \(String(format: "%g", t)) s") }
        parts.append(absorptionText)
        parts.append("validation: \(result.validation)")
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - The typed k sheet's draft

/// What the typed-k sheet edits before it commits: one row per quantified element, the source line. The sheet reads and writes
/// this; the session gets `entries` only when the draft is complete.
package nonisolated struct EDXTypedKDraft: Equatable, Sendable {
    package struct Row: Equatable, Identifiable, Sendable {
        package var element: String
        package var k: Double?
        /// Relative 1σ in percent; nil takes the method's default (20 %).
        package var sigmaPercent: Double?
        package var id: String { element }
        package init(element: String, k: Double? = nil, sigmaPercent: Double? = nil) { self.element = element; self.k = k; self.sigmaPercent = sigmaPercent }
    }

    package var rows: [Row]
    package var source: String

    /// Starts from what the method already holds for `elements`.
    package init(elements: [String], current: QuantificationMethod) {
        rows = elements.map { e in
            let t = current.typedK.first { $0.element == e }
            return Row(element: e, k: t?.k, sigmaPercent: t?.relativeSigma.map { $0 * 100 })
        }
        source = current.kFactorSource == .typed ? current.kSource : ""
    }

    /// Why Done is disabled; nil when the draft can be committed.
    package var incompleteReason: String? {
        if rows.isEmpty { return "Pick the elements to quantify first." }
        let missing = rows.filter { !(($0.k ?? 0) > 0) || !($0.k ?? 0).isFinite }.map(\.element)
        if !missing.isEmpty { return "Type a positive k for " + missing.joined(separator: ", ") + "." }
        if let bad = rows.first(where: { ($0.sigmaPercent ?? 0) < 0 || !($0.sigmaPercent ?? 0).isFinite }) { return "σ of \(bad.element) must not be negative." }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name where the k-factors come from." }
        return nil
    }

    package var isComplete: Bool { incompleteReason == nil }

    package var entries: [QuantificationMethod.TypedK] {
        rows.compactMap { r in r.k.map { QuantificationMethod.TypedK(element: r.element, k: $0, relativeSigma: r.sigmaPercent.map { $0 / 100 }) } }
    }
}

// MARK: - The zeta and cross-section sheet's draft

/// What the factors sheet edits for the zeta and cross-section methods: a factor per quantified element, the dose, the source line.
package nonisolated struct EDXFactorsDraft: Equatable, Sendable {
    package struct Row: Equatable, Identifiable, Sendable {
        package var element: String
        package var value: Double?
        package var id: String { element }
        package init(element: String, value: Double? = nil) { self.element = element; self.value = value }
    }

    package var method: EDXMapMethod
    package var rows: [Row]
    package var beamCurrentNA: Double?
    package var liveTimeSeconds: Double?
    package var probeAreaNm2: Double?
    package var source: String

    /// Starts from what `current` holds for `elements`. `method` is `.zeta` or `.crossSection`.
    package init(method: EDXMapMethod, elements: [String], current: EDXDoseInputs) {
        self.method = method
        let table = method == .zeta ? current.zeta : current.sectionsBarn
        rows = elements.map { Row(element: $0, value: table[$0]) }
        beamCurrentNA = current.beamCurrentNA; liveTimeSeconds = current.liveTimeSeconds; probeAreaNm2 = current.probeAreaNm2
        source = current.source
    }

    /// Why Done is disabled; nil when the draft can be committed.
    package var incompleteReason: String? {
        if rows.isEmpty { return "Pick the elements to quantify first." }
        let missing = rows.filter { !(($0.value ?? 0) > 0) || !($0.value ?? 0).isFinite }.map(\.element)
        if !missing.isEmpty { return "Type a positive \(method.factorName) for " + missing.joined(separator: ", ") + "." }
        if !((beamCurrentNA ?? 0) > 0) { return "Type the beam current." }
        if !((liveTimeSeconds ?? 0) > 0) { return "Type the live time." }
        if method == .crossSection, !((probeAreaNm2 ?? 0) > 0) { return "Type the probe area." }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name where the factors come from." }
        return nil
    }

    package var isComplete: Bool { incompleteReason == nil }

    /// `dose` with this draft's factors for its method, the dose and the source written in.
    package func applying(to dose: EDXDoseInputs, date: String) -> EDXDoseInputs {
        var out = dose
        var table = method == .zeta ? out.zeta : out.sectionsBarn
        for r in rows { if let v = r.value { table[r.element] = v } }
        if method == .zeta { out.zeta = table } else { out.sectionsBarn = table }
        out.beamCurrentNA = beamCurrentNA; out.liveTimeSeconds = liveTimeSeconds
        if method == .crossSection { out.probeAreaNm2 = probeAreaNm2 }
        out.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        out.date = date
        return out
    }
}
