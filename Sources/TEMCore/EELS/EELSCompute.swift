// The EELS room's compute, on SpectroKit's `EELSThickness.logRatio`: the t/λ map with the room's choices, and the tiles and
// words made from it. Nothing here is a number of macTEM's own: every value is a `ThicknessPixel` field.
import Foundation
import SpectroCore
import SpectroEELS

/// How I_0 is cut, as the room offers it.
package enum EELSThresholdChoice: Equatable, Sendable {
    /// The kit's estimated rule with its defaults (exSpy `estimate_elastic_scattering_threshold`).
    case estimated
    /// One threshold in eV for every pixel.
    case fixed(Double)

    package var rule: ThresholdRule {
        switch self {
        case .estimated: .estimated()
        case .fixed(let eV): .fixed(eV)
        }
    }
}

/// Where λ comes from, as the room offers it; E0 and the angles come from the file or are typed.
package enum EELSMeanFreePathChoice: Equatable, Sendable {
    case none
    case given(nanometres: Double)
    case iakoubovskii(density: Double, convergenceMrad: Double, collectionMrad: Double)
}

/// One map of the room, as a tile shows it: values over the scan grid, NaN where the kit has none.
package struct EELSMapTile: Identifiable, Equatable, Sendable {
    package let id: String
    package let title: String
    package let unit: String
    package let width: Int
    package let height: Int
    package let values: [Double]
    package let version: Int
    /// "12 px: I_0 <= 0 …": why pixels are hatched.
    package let footer: String?
    /// The one value every finite pixel has, in words ("0 eV"): a flat tile has no range to draw. Nil when the pixels differ.
    package var flatValueText: String? {
        let finite = values.filter { $0.isFinite }
        guard let lo = finite.min(), let hi = finite.max(), lo == hi else { return nil }
        return EELSRoomFormat.sig(lo, 3) + (unit.isEmpty ? "" : " \(unit)")
    }
    /// The tile's one line under its name: "every pixel 0 eV" for a flat map, else its unit.
    package var detailText: String? {
        if let flat = flatValueText { return "every pixel \(flat)" }
        return unit.isEmpty ? nil : unit
    }
    package init(id: String, title: String, unit: String, width: Int, height: Int, values: [Double], version: Int, footer: String?) {
        self.id = id; self.title = title; self.unit = unit; self.width = width; self.height = height
        self.values = values; self.version = version; self.footer = footer
    }
    package static func == (a: EELSMapTile, b: EELSMapTile) -> Bool { a.id == b.id && a.version == b.version && a.footer == b.footer }
}

package enum EELSCompute {

    /// The map: the kit's log-ratio method. Throws `EELSThicknessError` (inputs it cannot start from) or `SpectroCancelled`.
    package static func map(image: LowLossSpectrumImage, threshold: EELSThresholdChoice, meanFreePath: MeanFreePathSource?,
                            cancelled: @Sendable () -> Bool = SpectroCancellation.task,
                            progress: (@Sendable (Double) -> Void)? = nil) throws -> ThicknessMap {
        try EELSThickness.logRatio(image, threshold: threshold.rule, meanFreePath: meanFreePath, cancelled: cancelled, progress: progress)
    }

    /// The kit's source for a choice and the file's or typed beam energy; nil for none. Throws a sentence when the beam energy is missing.
    package static func source(_ choice: EELSMeanFreePathChoice, beamEnergyKeV: Double?) throws -> MeanFreePathSource? {
        switch choice {
        case .none: return nil
        case .given(let nm): return .given(nm)
        case .iakoubovskii(let rho, let alpha, let beta):
            guard let e0 = beamEnergyKeV, e0 > 0 else { throw EELSRoomRefusal.needsBeamEnergy }
            return .iakoubovskii(density: rho, beamEnergyKeV: e0, convergenceMrad: alpha, collectionMrad: beta)
        }
    }

    /// The five tiles of the design: t/λ, t (when λ is given), the zero-loss peak's centre, I_0 and I_total.
    package static func tiles(_ map: ThicknessMap, version: Int) -> [EELSMapTile] {
        func tile(_ id: String, _ title: String, _ unit: String, _ value: (ThicknessPixel) -> Double?, footer: String? = nil) -> EELSMapTile {
            EELSMapTile(id: id, title: title, unit: unit, width: map.nx, height: map.ny, values: map.pixels.map { value($0) ?? .nan },
                        version: version, footer: footer)
        }
        let reasons = unavailable(map)
        let why = reasons.isEmpty ? nil : reasons.map { "\($0.count) px: \($0.reason)" }.joined(separator: "; ")
        var out = [tile("tOverLambda", "t/λ", "", { $0.tOverLambda }, footer: why)]
        if map.meanFreePathNM != nil { out.append(tile("thickness", "t", "nm", { $0.thicknessNM }, footer: why)) }
        out.append(tile("zlpCentre", "ZLP centre", "eV", { $0.zlpCentreEV }))
        out.append(tile("i0", "I₀", "counts", { $0.i0 }))
        out.append(tile("iTotal", "I total", "counts", { $0.iTotal }))
        return out
    }

    /// Where the zero-loss peak was before Align (`ZeroLossAlignment.initialCentreEV`, nil where it could not be found), as a tile beside the map's own
    /// ZLP centre (after): the pair shows what Align did.
    package static func beforeTile(_ alignment: ZeroLossAlignment, nx: Int, ny: Int, version: Int) -> EELSMapTile {
        EELSMapTile(id: "zlpCentreBefore", title: "ZLP centre (before)", unit: "eV", width: nx, height: ny,
                    values: alignment.initialCentreEV.map { $0 ?? .nan }, version: version, footer: nil)
    }

    /// The zero-loss shift Align applied at each pixel (`ZeroLossAlignment.shiftEV`, nil where the kit masked it), as a tile: the room's ZLP segment and the
    /// tile beside the anchor after Align. Diverging, 0 at the centre.
    package static func shiftTile(_ alignment: ZeroLossAlignment, nx: Int, ny: Int, version: Int) -> EELSMapTile {
        EELSMapTile(id: "zlpShift", title: "ZLP shift", unit: "eV", width: nx, height: ny,
                    values: alignment.shiftEV.map { $0 ?? .nan }, version: version, footer: nil)
    }

    /// The pixel under the pointer, in scan pixels. Equatable, so a hover that stays on the same pixel notifies nobody.
    package nonisolated struct Pixel: Equatable, Sendable {
        package var x: Int
        package var y: Int
        package init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    /// One reason a pixel has no t/λ and how many pixels have it.
    package nonisolated struct UnavailableReason: Equatable, Sendable {
        package let reason: String
        package let count: Int
    }

    /// `unavailable` as values, for a session to hold: made once when a map lands, not in a view body per hover.
    package static func unavailableReasons(_ map: ThicknessMap) -> [UnavailableReason] {
        unavailable(map).map { UnavailableReason(reason: $0.reason, count: $0.count) }
    }

    /// Pixels with no t/λ, grouped by the kit's reason, most numerous first.
    package static func unavailable(_ map: ThicknessMap) -> [(reason: String, count: Int)] {
        var counts: [ThicknessUnavailable: Int] = [:]
        for p in map.pixels { if let u = p.unavailable { counts[u, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key.description, $0.value) }
    }
}

package enum EELSRoomRefusal: Error, Equatable, LocalizedError {
    case needsBeamEnergy
    package var errorDescription: String? {
        "Iakoubovskii's mean free path needs the beam energy and the file does not state it: type it under Mean Free Path."
    }
}

// MARK: - Exports

extension EELSCompute {
    /// Per-pixel diagnostics, the kit's fields: x, y, t/λ, σ, I_0, I_total, ZLP centre, threshold, t (nm), and the reason where there is none.
    package static func diagnosticsCSV(_ map: ThicknessMap, fileName: String) -> String {
        func g(_ v: Double?) -> String { v.map { String(format: "%.9g", $0) } ?? "" }
        var out = ["# macTEM EELS thickness, file: \(fileName), method: \(map.method), validation: \(map.validation)",
                   "x,y,t_over_lambda,sigma_counting,i0,i_total,zlp_centre_eV,threshold_eV,thickness_nm,unavailable"]
        for y in 0..<map.ny {
            for x in 0..<map.nx {
                let p = map[x, y]
                out.append("\(x),\(y),\(g(p.tOverLambda)),\(g(p.sigmaCounting)),\(g(p.i0)),\(g(p.iTotal)),\(g(p.zlpCentreEV)),\(g(p.thresholdEV)),\(g(p.thicknessNM)),"
                           + (p.unavailable.map { "\"\($0.description)\"" } ?? ""))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The method as JSON: what made the map, with the badge, so another reader (mac4DSTEM's thickness row) can name its source.
    package static func methodJSON(_ map: ThicknessMap, fileName: String, origin: String) -> String {
        var d: [String: Any] = ["file": fileName, "origin": origin, "method": map.method, "validation": map.validation,
                                "width": map.nx, "height": map.ny]
        switch map.zeroLoss {
        case .zeroLossSpectrum: d["zero_loss"] = "separate zero-loss spectrum"
        case .threshold(let rule):
            switch rule {
            case .estimated: d["zero_loss"] = "estimated threshold"
            case .fixed(let eV): d["zero_loss"] = "fixed threshold \(eV) eV"
            case .perPixel: d["zero_loss"] = "per-pixel threshold"
            }
        }
        if let t = map.estimatedTolerance { d["estimated_tolerance_counts_per_eV"] = t }
        if let l = map.meanFreePathNM { d["mean_free_path_nm"] = l }
        if let a = map.angularCorrection { d["angular_correction"] = a }
        let finite = map.pixels.compactMap(\.tOverLambda)
        d["pixels_with_t_over_lambda"] = finite.count
        d["pixels_unavailable"] = map.pixels.count - finite.count
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
