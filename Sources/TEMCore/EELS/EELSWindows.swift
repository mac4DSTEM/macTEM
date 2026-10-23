// The EELS room's per-edge windows, the background choice, the reference spectra and the check that a window does not sit on a stretch with no counts.
// Nothing here makes a number of macTEM's own beyond choosing windows: the defaults are the kit's (`EdgeWindows.defaults`), the background under a window while it is
// dragged is the kit's `EELSBackground.preview`, a reference is the region's counts less that background, or an MSA file read by FormatoKit.
import Foundation
import FormatoCore
import FormatoMSA
import SpectroCore
import SpectroEELS

// MARK: - Dead stretches

/// A stretch of the energy axis where the spectrum holds no counts (a detector range that ends, a dark-subtracted tail): a signal window on it is refused by name.
package nonisolated enum EELSDeadStretch {
    /// The summed counts of each channel of `core` over every pixel, in the order of the axis.
    package static func channelSums(of core: CoreLossSpectrumImage) -> [Double] {
        var sums = [Double](repeating: 0, count: core.channels)
        let n = core.channels
        core.counts.withUnsafeBufferPointer { c in
            for p in 0..<core.pixelCount {
                let base = p * n
                for k in 0..<n { sums[k] += c[base + k] }
            }
        }
        return sums
    }

    /// The energy ranges of `counts` (a summed spectrum on `origin + step * i`) where at least `minimumChannels` channels in a row hold no counts (zero or below).
    /// A run of fewer is noise in a sparse spectrum, not a stretch.
    package static func stretches(counts: [Double], origin: Double, step: Double, minimumChannels: Int = 8) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var runStart: Int?
        func close(at end: Int) {
            if let s = runStart, end - s >= minimumChannels { out.append((origin + step * Double(s))...(origin + step * Double(end - 1))) }
            runStart = nil
        }
        for (i, v) in counts.enumerated() {
            if v <= 0 { if runStart == nil { runStart = i } } else { close(at: i) }
        }
        close(at: counts.count)
        return out
    }

    /// The sentence that names why `edge` is not fitted when its background or signal window overlaps a stretch; nil when neither does.
    package static func refusal(title: String, windows: EELSEdgeWindows, stretches: [ClosedRange<Double>]) -> String? {
        func hit(_ w: ClosedRange<Double>) -> ClosedRange<Double>? { stretches.first { $0.overlaps(w) } }
        func eV(_ v: Double) -> String { EELSRoomFormat.sig(v, 4) }
        if let s = hit(windows.signal) {
            return "\(title): the core loss holds no counts from \(eV(s.lowerBound)) to \(eV(s.upperBound)) eV, where its signal window (\(eV(windows.signal.lowerBound))–\(eV(windows.signal.upperBound)) eV) sits; not fitted."
        }
        if let s = hit(windows.background) {
            return "\(title): the core loss holds no counts from \(eV(s.lowerBound)) to \(eV(s.upperBound)) eV, where its background window (\(eV(windows.background.lowerBound))–\(eV(windows.background.upperBound)) eV) sits; not fitted."
        }
        return nil
    }
}

// MARK: - Windows

/// One edge's background and signal windows in absolute energy, as the room draws and drags them. The defaults are the kit's (`EdgeWindows.defaults`: its
/// documented constants are the only copy of the rules); the kit's fit takes them as `EdgeWindows` (`kit`).
package nonisolated struct EELSEdgeWindows: Equatable, Sendable {
    package var background: ClosedRange<Double>
    package var signal: ClosedRange<Double>

    package static let minimumWidthEV = 1.0

    package init(background: ClosedRange<Double>, signal: ClosedRange<Double>) { self.background = background; self.signal = signal }
    package init(_ kit: EdgeWindows) { self.init(background: kit.backgroundEV, signal: kit.signalEV) }

    /// What the kit's fit takes for one edge (one background window; the second is not used by the room).
    package var kit: EdgeWindows { EdgeWindows(backgroundEV: background, signalEV: signal) }

    /// What a drag can grab: a window's body, or one of its ends.
    package enum Handle: Equatable, Sendable { case backgroundBody, backgroundLower, backgroundUpper, signalBody, signalLower, signalUpper }

    /// The windows after `handle` moved by `delta` eV: a body moves the whole window, an end resizes it. A window keeps at least `minimumWidthEV`, the background
    /// stays below the signal, and nothing goes below `limit`'s start or above its end.
    package func moved(_ handle: Handle, by delta: Double, within limit: ClosedRange<Double>) -> EELSEdgeWindows {
        var out = self
        let minW = Self.minimumWidthEV
        func shifted(_ w: ClosedRange<Double>, lowerBound: Double, upperBound: Double) -> ClosedRange<Double> {
            let width = w.upperBound - w.lowerBound
            let lo = min(max(w.lowerBound + delta, lowerBound), max(upperBound - width, lowerBound))
            return lo...(lo + width)
        }
        switch handle {
        case .backgroundBody: out.background = shifted(background, lowerBound: limit.lowerBound, upperBound: signal.lowerBound)
        case .signalBody: out.signal = shifted(signal, lowerBound: background.upperBound, upperBound: limit.upperBound)
        case .backgroundLower: out.background = min(max(background.lowerBound + delta, limit.lowerBound), background.upperBound - minW)...background.upperBound
        case .backgroundUpper: out.background = background.lowerBound...min(max(background.upperBound + delta, background.lowerBound + minW), signal.lowerBound)
        case .signalLower: out.signal = min(max(signal.lowerBound + delta, background.upperBound), signal.upperBound - minW)...signal.upperBound
        case .signalUpper: out.signal = signal.lowerBound...min(max(signal.upperBound + delta, signal.lowerBound + minW), limit.upperBound)
        }
        return out
    }

    /// The handle at `energy` within `tolerance` eV: an end first, else a body, else nil.
    package func handle(at energy: Double, tolerance: Double) -> Handle? {
        let ends: [(Handle, Double)] = [(.backgroundLower, background.lowerBound), (.backgroundUpper, background.upperBound),
                                        (.signalLower, signal.lowerBound), (.signalUpper, signal.upperBound)]
        if let end = ends.filter({ abs($0.1 - energy) <= tolerance }).min(by: { abs($0.1 - energy) < abs($1.1 - energy) }) { return end.0 }
        if background.contains(energy) { return .backgroundBody }
        if signal.contains(energy) { return .signalBody }
        return nil
    }
}

// MARK: - Background

/// The Fitting section's background control: only the power law is in the kit today.
package nonisolated enum EELSBackgroundChoice: String, CaseIterable, Identifiable, Sendable {
    case powerLaw, lcpl, polynomial, linear

    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .powerLaw: "Power law"
        case .lcpl: "LCPL"
        case .polynomial: "Polynomial"
        case .linear: "Linear"
        }
    }

    /// Why the choice cannot be picked now; nil when it can.
    package var disabledReason: String? {
        self == .powerLaw ? nil : "\(title) is not in SpectroKit yet: only the power law fits today."
    }
}

// MARK: - Reference spectra

/// A reference spectrum for the MLLS fit: a region's background-subtracted edge, or a spectrum imported from an MSA file.
package nonisolated struct EELSReference: Identifiable, Equatable, Sendable {
    package enum Origin: Equatable, Sendable { case region(String, edge: String), imported(String) }
    package let id: String
    package var name: String
    package let origin: Origin
    package let curve: EELSPlotCurve

    package init(id: String = UUID().uuidString, name: String, origin: Origin, curve: EELSPlotCurve) {
        self.id = id; self.name = name; self.origin = origin; self.curve = curve
    }

    /// "Region 1 · Si K" / "from silicon.msa".
    package var originText: String {
        switch origin {
        case .region(let region, let edge): "\(region) · \(edge)"
        case .imported(let file): "from \(file)"
        }
    }

    /// The note under the list: the references are kept and drawn; the fit that uses them is not in the kit.
    package static let note = "References are kept and drawn. The MLLS fit with references is not in SpectroKit yet, so they change no number."
}

package nonisolated enum EELSReferenceError: Error, Equatable, LocalizedError {
    case notEnergyLoss(String)
    package var errorDescription: String? {
        switch self {
        case .notEnergyLoss(let why): why
        }
    }
}

package nonisolated enum EELSBackgroundFit {
    /// The kit's live-drag preview (`EELSBackground.preview`, HyperSpy's two-area power law) fitted to `curve` over `windows.background`, as counts per channel over `range`
    /// on the curve's channels (NaN elsewhere). nil when the kit has no estimate (a window that is not inside the axis, too narrow or not positive).
    package static func extrapolation(of curve: EELSPlotCurve, windows: EELSEdgeWindows, over range: ClosedRange<Double>) -> [Double]? {
        guard curve.counts.count > 8, curve.step > 0,
              let preview = try? EELSBackground.preview(counts: curve.counts, axis: EnergyAxis(offset: curve.origin, scale: curve.step, size: curve.counts.count),
                                                        window: windows.background, extrapolateTo: range) else { return nil }
        var out = [Double](repeating: .nan, count: curve.counts.count)
        for (k, channel) in preview.channels.enumerated() where preview.curve[k].isFinite && preview.curve[k] > 0 { out[channel] = preview.curve[k] }
        return out
    }
}

// MARK: - The windows handed to the kit

/// The windows of the picked edges as the kit's fit takes them: one per fitted edge in onset order (twins of one element and family are one, as the kit groups them),
/// the defaults from `EdgeWindows.defaults` with the neighbours' ends, the person's edits over them. The kit refuses the rest, and `sentence` says what it refused.
package nonisolated enum EELSWindowPlan {
    package struct Entry: Equatable, Sendable {
        /// The edge the kit's result carries for the group (the shell with the last name), and every picked shell of it.
        package let master: CoreLossEdge
        package let edges: [CoreLossEdge]
        package let windows: EELSEdgeWindows
        package let isEdited: Bool
        package var key: String { EELSFitCompute.id(master) }
    }

    /// The kit's groups: one per element and shell family, ordered by the master's onset (then the element).
    package static func groups(of edges: [CoreLossEdge]) -> [[CoreLossEdge]] {
        var byKey: [String: [CoreLossEdge]] = [:]
        for e in edges { byKey[e.element + " " + e.family, default: []].append(e) }
        let groups = byKey.values.map { $0.sorted { $0.subshell < $1.subshell } }
        return groups.sorted { ($0.last!.onsetEV, $0.last!.element) < ($1.last!.onsetEV, $1.last!.element) }
    }

    /// The window of every group in onset order. A group not in `edited` has the kit's defaults, squeezed by the neighbours' final windows.
    package static func plan(for edges: [CoreLossEdge], edited: [String: EELSEdgeWindows], axis: EnergyAxis) -> [Entry] {
        let groups = groups(of: edges)
        var out: [Entry] = []
        for (i, group) in groups.enumerated() {
            let master = group.last!
            let key = EELSFitCompute.id(master)
            if let w = edited[key] { out.append(Entry(master: master, edges: group, windows: w, isEdited: true)); continue }
            // The preceding edge's window and name are handed over, so the kit's close-edge rule (a window narrower than 20 eV shares the preceding
            // edge's window, with a note) can apply. Not its onset: the stretch between the onsets holds the preceding edge, which only a stripping
            // fit removes, and the room does not strip (`EELSModelOptions.stripPrecedingEdges` is off: it over-strips O K on the real a-C maps).
            let defaults = EdgeWindows.defaults(onsetEV: master.onsetEV, family: master.family, precedingSignalEndEV: out.last?.windows.signal.upperBound,
                                                nextOnsetEV: i + 1 < groups.count ? groups[i + 1].last!.onsetEV : nil, axis: axis,
                                                precedingOnsetEV: nil, precedingBackgroundEV: out.last?.windows.background,
                                                precedingName: out.last.map { EELSFitCompute.id($0.master) })
            out.append(Entry(master: master, edges: group, windows: EELSEdgeWindows(defaults), isEdited: false))
        }
        return out
    }

    /// The same windows as the plan, without the person's edit of `edge`'s group: what the drag would return to.
    package static func defaultWindows(of edge: CoreLossEdge, among edges: [CoreLossEdge], edited: [String: EELSEdgeWindows], axis: EnergyAxis) -> EELSEdgeWindows? {
        var rest = edited
        if let master = groups(of: edges).first(where: { $0.contains(edge) })?.last { rest[EELSFitCompute.id(master)] = nil }
        return plan(for: edges, edited: rest, axis: axis).first { $0.edges.contains(edge) }?.windows
    }

    /// The sentence for a fit the kit refused because of a window; nil for any other kit error. The kit's errors carry the fields (the edges, the numbers and, for an
    /// invalid window, its own reason); the kit has no localized text, so the room puts them in a sentence.
    package static func sentence(for error: Error) -> String? {
        guard let e = error as? EELSModelError else { return nil }
        func eV(_ v: Double) -> String { EELSRoomFormat.sig(v, 4) }
        switch e {
        case .overlappingSignalWindows(let a, let b): return "The signal windows of \(a) and \(b) share energies; each channel of the signal belongs to one edge. Move or narrow one of them."
        case .edgeWindowInvalid(let edge, let why): return "\(edge): \(why)."
        case .edgeWindowCountMismatch(let expected, let got): return "The fit takes one window pair per edge: \(expected) edges, \(got) windows."
        case .backgroundWindowEmpty: return "A background window holds no channel of the core loss."
        case .backgroundNotEstimable(let why): return "The background cannot be estimated: \(why)."
        default: return nil
        }
    }
}

package nonisolated enum EELSReferenceCompute {
    /// "From region": the region's core-loss counts over the edge's signal window less the kit's power-law background fitted over its background window.
    package static func fromRegion(name: String, edge: CoreLossEdge, core: EELSPlotCurve, windows: EELSEdgeWindows) -> EELSReference? {
        guard let background = EELSBackgroundFit.extrapolation(of: core, windows: windows, over: windows.signal) else { return nil }
        var counts: [Double] = [], first: Int?
        for k in 0..<core.counts.count where windows.signal.contains(core.energy(k)) && background[k].isFinite {
            if first == nil { first = k }
            counts.append(core.counts[k] - background[k])
        }
        guard let first, counts.count > 1 else { return nil }
        return EELSReference(name: "\(name) · \(EELSFitCompute.title(edge))", origin: .region(name, edge: EELSFitCompute.title(edge)),
                             curve: EELSPlotCurve(origin: core.energy(first), step: core.step, counts: counts))
    }

    /// An MSA file read through FormatoKit: one spectrum on an energy axis in eV (FormatoKit's MSA reader gives the axis offset and scale and the counts).
    package static func importMSA(url: URL) throws -> EELSReference {
        let spectrum = try MSAReader.read(path: url.path)
        let signal = spectrum.signal
        guard let axis = signal.axes.last, signal.axes.count == 1 else {
            throw EELSReferenceError.notEnergyLoss("\(url.lastPathComponent) holds more than one spectrum: a reference is one spectrum.")
        }
        guard axis.units.lowercased() == "ev" || axis.units.isEmpty else {
            throw EELSReferenceError.notEnergyLoss("\(url.lastPathComponent): the axis is in \"\(axis.units)\", not eV.")
        }
        let counts = signal.data.doubles()
        guard counts.count == axis.size, axis.scale > 0 else {
            throw EELSReferenceError.notEnergyLoss("\(url.lastPathComponent): no energy axis to put the reference on.")
        }
        let name = url.deletingPathExtension().lastPathComponent
        return EELSReference(name: name, origin: .imported(url.lastPathComponent), curve: EELSPlotCurve(origin: axis.offset, step: axis.scale, counts: counts))
    }
}
