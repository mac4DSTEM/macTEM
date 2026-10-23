// The EDX room's compute, on SpectroKit: the region's spectrum, the line windows and net-count maps, Auto ID, the pooled
// Cliff-Lorimer quantification with its unlisted-line check, and the two exports. Nothing here is a number of macTEM's own:
// each call is the kit's (mac4DSTEM's SpectroscopyRoomController is the blueprint), and the room only chooses the inputs.
import Foundation
import SpectroCore
import SpectroEDX

// MARK: - What the room holds about an element and a region

/// An element the room fits: quantified (it gets an at%) or fitted only (its lines are modelled, it gets no at%).
package enum EDXRole: String, Sendable, Equatable {
    case quantify
    case fitOnly
}

package struct EDXPick: Equatable, Sendable {
    package var symbol: String
    package var role: EDXRole
    /// Picked by hand: Auto ID never removes it, and a hand-removed element is not added again.
    package var manual: Bool
    /// The line family the maps sum (nil: the element's default) and the lines the person checked (empty: the family's alpha line), as SpectroKit's `ElementWindows.Pick`.
    package var family: XRayFamily?
    package var lines: [String]
    package init(symbol: String, role: EDXRole, manual: Bool, family: XRayFamily? = nil, lines: [String] = []) {
        self.symbol = symbol; self.role = role; self.manual = manual; self.family = family; self.lines = lines
    }
}

/// The pixels the spectrum is summed over: the whole map or one shape drawn on a map, in pixels of the scan grid. The shapes are the
/// kit's `SpectrumRegionShape` (a pixel is in when its centre is); mac4DSTEM also takes pools from a 4D scan, macTEM has none.
package enum EDXRegion: Equatable, Sendable {
    case wholeMap
    case rectangle(PixelRect)
    /// The ellipse inscribed in the rectangle.
    case ellipse(PixelRect)
    /// A closed polygon, vertices in pixel coordinates (the last joins the first).
    case polygon([PixelPoint])

    package var name: String {
        switch self {
        case .wholeMap: "Whole map"
        default: "Region"
        }
    }

    /// "whole", "rectangle", "ellipse", "polygon": the word the exports use.
    package var shapeName: String {
        switch self {
        case .wholeMap: "whole"
        case .rectangle: "rectangle"
        case .ellipse: "ellipse"
        case .polygon: "polygon"
        }
    }

    package var shape: SpectrumRegionShape? {
        switch self {
        case .wholeMap: nil
        case .rectangle(let r): .rectangle(r)
        case .ellipse(let r): .ellipse(r)
        case .polygon(let v): .polygon(v)
        }
    }

    /// nil = every pixel (the kit's convention).
    package func mask(nx: Int, ny: Int) -> PixelMask? { shape?.mask(nx: nx, ny: ny) }

    package func pixelCount(nx: Int, ny: Int) -> Int {
        mask(nx: nx, ny: ny).map { $0.reduce(0) { $0 + ($1 ? 1 : 0) } } ?? nx * ny
    }

    /// What a cache entry about this region is keyed by: the content of the region, not an id.
    package var cacheKey: String {
        switch self {
        case .wholeMap: "whole"
        case .rectangle(let r): "rect:\(r.x0),\(r.y0),\(r.x1),\(r.y1)"
        case .ellipse(let r): "ellipse:\(r.x0),\(r.y0),\(r.x1),\(r.y1)"
        case .polygon(let v): "poly:" + v.map { "\($0.x),\($0.y)" }.joined(separator: ";")
        }
    }
}

// MARK: - Cache

/// Spectra by region and maps by line window, written by detached tasks and read by the next one. Keys are the content (the
/// region's pixels, the window's channels), so nothing in here can be stale; a new file starts a new cache.
package final class EDXComputeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var spectra: [String: [UInt64]] = [:]
    private var maps: [String: [Double]] = [:]
    private var refinements: [String: AxisRefinementResult] = [:]
    private var proposals: [String: ProposalResult] = [:]

    package init() {}

    package func spectrum(_ key: String) -> [UInt64]? { lock.withLock { spectra[key] } }
    package func setSpectrum(_ s: [UInt64], _ key: String) { lock.withLock { spectra[key] = s } }
    package func map(_ key: String) -> [Double]? { lock.withLock { maps[key] } }
    package func setMap(_ m: [Double], _ key: String) { lock.withLock { maps[key] = m } }
    package func refinement(_ key: String) -> AxisRefinementResult? { lock.withLock { refinements[key] } }
    package func setRefinement(_ r: AxisRefinementResult, _ key: String) { lock.withLock { refinements[key] = r } }
    package func proposal(_ key: String) -> ProposalResult? { lock.withLock { proposals[key] } }
    package func setProposal(_ p: ProposalResult, _ key: String) { lock.withLock { proposals[key] = p } }

    /// One window's map key: the channel ranges decide the map, nothing else does.
    package static func key(_ w: ResolvedWindow) -> String {
        ([w.signal] + (w.background.map { [$0.left, $0.right] } ?? [])).map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: "|")
            + (w.background.map { "|s\($0.scale)" } ?? "")
    }
}

// MARK: - The compute

package enum EDXCompute {
    /// The computed-k and absorption data files (SpectroKit's resource bundle, inside the app); nil when it lacks them.
    package static let tables: QuantificationTables? = QuantificationTables.bundled()

    // MARK: Spectrum and maps

    package static func spectrum(source: any SpectrumImageSource, region: EDXRegion, cache: EDXComputeCache) -> [UInt64] {
        let key = region.cacheKey
        if let s = cache.spectrum(key) { return s }
        let s = source.sum(mask: region.mask(nx: source.nx, ny: source.ny))
        cache.setSpectrum(s, key)
        return s
    }

    package struct Windows: Sendable {
        package let windows: [LineWindow]
        package let counts: [LineNetCount?]
        package let maps: [[Double]?]
    }

    /// The line windows of the picked elements on the file's axis, their net counts in `spectrum` and their net-count maps
    /// (only the windows whose map is not cached are summed).
    package static func windows(source: any SpectrumImageSource, spectrum: [UInt64], picks: [EDXPick], cache: EDXComputeCache) -> Windows {
        let windows = ElementWindows.build(picks: picks.map { ElementWindows.Pick(symbol: $0.symbol, family: $0.family, lines: $0.lines) },
                                           axis: source.energyAxis, beamEnergyKeV: source.metadata.beamEnergyKeV)
        let counts = ElementWindows.netCounts(spectrum: spectrum, windows: windows)
        let missing = windows.filter { w in w.window.map { cache.map(EDXComputeCache.key($0)) == nil } ?? false }
        if !missing.isEmpty {
            let fresh = ElementWindows.maps(image: source, windows: missing)
            for (w, m) in zip(missing, fresh) { if let w = w.window, let m { cache.setMap(m, EDXComputeCache.key(w)) } }
        }
        let maps = windows.map { w in w.window.flatMap { cache.map(EDXComputeCache.key($0)) } }
        return Windows(windows: windows, counts: counts, maps: maps)
    }

    /// An element's map: the sum of its windows' nets (one window unless the element has two lines on the axis).
    package static func elementMap(_ symbol: String, in w: Windows) -> [Double]? {
        let parts = w.windows.indices.filter { w.windows[$0].element == symbol }.compactMap { w.maps[$0] }
        guard var sum = parts.first else { return nil }
        for p in parts.dropFirst() { for i in sum.indices { sum[i] += p[i] } }
        return sum
    }

    // MARK: Auto ID

    package struct Suggestion: Equatable, Sendable {
        package var symbol: String
        package var role: EDXRole
        package var reason: String
    }

    package struct AutoIDOutcome: Equatable, Sendable {
        package var region: String
        package var suggestions: [Suggestion]
        /// Sum-peak questions: an energy that is a pile-up peak or an element, never offered as an element.
        package var suspects: [String]
        /// Proposals that sit beside a listed line or a split edge: an unexplained excess, not an element.
        package var excesses: [String]
        /// Proposals by one L or M line whose K or L line the fitted range cannot hold: shown, never added (the confirm-elements step made explicit).
        package var uncorroborated: [String] = []
        /// The proposer's own notes and what it did not test.
        package var notes: [String]
    }

    package static let autoIDNeedsBeamNote = "Auto ID needs the beam energy and the file does not state it: type it under Quantification."

    /// Which proposed K lines anchor an axis refinement: at least two at or above 3 L_D, spanning 3 keV or more (one line cannot tell an
    /// offset from a gain, and a refinement on Cu alone drifted by 46 eV on the owner's file 1339, 2026-10-22). nil: no refinement.
    package static func refinementAnchors(_ result: ProposalResult) -> [String]? {
        let k = result.proposed.filter { XRayLines.line($0.group)?.family == .K && $0.significance >= 3 }
        guard k.count >= 2, let lo = k.map(\.energyKeV).min(), let hi = k.map(\.energyKeV).max(), hi - lo >= 3 else { return nil }
        return k.map(\.element)
    }

    /// Auto ID: the element proposer on the region's spectrum with the listed elements as the current set, then the shipped
    /// rule set. DEVIATION (as mac4DSTEM's controller): the default continuum, not the Quantification choices: Auto ID screens, it
    /// does not quantify. The AXIS is refined first when `metadata` is given: the first proposal's K lines (`refinementAnchors`) are
    /// fitted once with the pooled quantifier, which refines the offset, gain and detector width as Quantify does, and the proposal
    /// is made again on that axis (measured 2026-10-22 on the owner's three files: the file's 130 eV width against the refined 133 to
    /// 135 eV was most of the misfit beside the strong K lines, which inflated every neighbour's limit and hid Si). `computedK`: a
    /// computed k covers K lines only, so a pick on an L or M group is applied as Fit only.
    package static func autoID(spectrum: [UInt64], axis fileAxis: EnergyAxis, beam: Double, listed: [String], computedK: Bool,
                               regionName: String, metadata: SpectrumImageMetadata? = nil) throws -> AutoIDOutcome {
        let counts = spectrum.map { Double($0) }
        var axis = fileAxis
        var settings = FitSettings.standard(elements: listed, axis: axis, resolutionMnKaEV: ElementWindows.defaultResolutionMnKaEV, beamEnergy: beam)
        var result = try ElementProposer().propose(counts: counts, axis: axis, settings: settings)
        var refinementNote: String?
        // Two rounds at most: the second proposal often adds a K line the first could not see at the file's width (Si beside Al on the owner's files), and
        // the refinement on the larger anchor set is the one Quantify would make; a third round changes nothing measurable (2026-10-22).
        var anchorsUsed: [String] = []
        for _ in 0..<2 {
            guard let metadata, let anchors = refinementAnchors(result), anchors != anchorsUsed else { break }
            var m = QuantificationMethod()
            m.elements = (listed + anchors.filter { !listed.contains($0) }).map { QuantificationMethod.ElementState(symbol: $0, role: .quantify, isManual: false) }
            m.beamEnergyKeV = beam
            let input = PooledQuantificationInput(counts: spectrum, axis: fileAxis, method: m, metadata: metadata, regionName: regionName, pixelCount: 1)
            guard let fit = try? PooledQuantifier.run(input, tables: tables), let r = fit.refinement, fit.usedAxis == r.refinedAxis else { break }
            anchorsUsed = anchors
            axis = r.refinedAxis
            settings = FitSettings.standard(elements: listed, axis: axis, resolutionMnKaEV: r.resolutionMnKaEV, beamEnergy: beam)
            result = try ElementProposer().propose(counts: counts, axis: axis, settings: settings)
            refinementNote = String(format: "Energy axis refined on %@ before the proposal: offset %+.1f eV, gain %+.3f %%, FWHM(Mn K\u{03B1}) %.0f eV (file %.0f eV).",
                                    anchors.joined(separator: ", "), r.offsetShiftEV, r.gainShift * 100, r.resolutionMnKaEV, ElementWindows.defaultResolutionMnKaEV)
        }
        return outcome(of: result, settings: settings, axis: axis, computedK: computedK, regionName: regionName, refinementNote: refinementNote)
    }

    /// The room's reading of a proposal: the shipped rules, the picks (an excess beside a listed line is not an element; a find the kit could not
    /// confirm is uncorroborated, never added), the sum-peak suspects and the notes. `settings` and `axis` are the ones the proposal ran with.
    package static func outcome(of result: ProposalResult, settings: FitSettings, axis: EnergyAxis, computedK: Bool, regionName: String,
                                refinementNote: String? = nil) -> AutoIDOutcome {
        let ruled = ProposalRules.shipped.apply(result, resolutionMnKaEV: settings.resolutionMnKaEV)

        let groups = EDSLineModel.build(elements: settings.elements, axis: axis, beamEnergy: settings.beamEnergy,
                                        resolutionMnKaEV: settings.resolutionMnKaEV, escapePeaks: settings.escapePeaks).groups
        var edges: [Double] = []
        if case .continuum(let form) = settings.background { edges = form.edges }
        let besideLine: (Double, String) -> String? = { e, element in
            return UnlistedLineChecker.neighbour(energyKeV: e, listedGroups: groups, resolutionMnKaEV: settings.resolutionMnKaEV,
                                                 edges: edges, element: element)?.line
        }
        func stats(_ c: ElementCandidate) -> String {
            var t = String(format: "net %@ counts, %.1f \u{00D7} L_D", UnlistedLineChecker.grouped(c.net), c.significance)
            if let x = result.reducedChiSquared { t += ", " + PooledQuantifier.qualityText(label: "\u{03C7}\u{00B2}\u{1D63} (Pearson)", value: x) }
            return t
        }
        func strongestFirst(_ cs: [ElementCandidate]) -> [ElementCandidate] {
            cs.enumerated().sorted { $0.element.significance != $1.element.significance
                ? $0.element.significance > $1.element.significance : $0.offset < $1.offset }.map(\.element)
        }

        var suggestions: [Suggestion] = []
        var excesses: [String] = []
        var uncorroborated: [String] = []
        for c in strongestFirst(ruled.picks) {
            if let line = besideLine(c.energyKeV, c.element) {
                excesses.append("unexplained excess beside \(line) (proposer's label \(UnlistedLineChecker.displayName(c.group))): \(stats(c))")
                continue
            }
            guard EDXElements.unavailableReason(symbol: c.element) == nil else { continue }
            // A computed k has no L or M lines; a FIB question's remedy is "keep Ga fitted but excluded from Quantify".
            let noK = computedK && !(XRayLines.line(c.group).map { $0.family == .K } ?? true)
            let fib = c.conflicts.contains { $0.kind == .fibContamination }
            var reason = (noK ? "fit only (no computed k for L/M lines): " : "") + stats(c)
            let questions = c.conflicts.map(\.question)
            if !questions.isEmpty { reason += ". " + questions.joined(separator: " ") }
            if let rule = ruled.ruleReason(for: c.element) { reason += (reason.hasSuffix(".") ? " " : ". ") + rule }
            suggestions.append(Suggestion(symbol: c.element, role: (noK || fib) ? .fitOnly : .quantify, reason: reason))
        }
        // The kit's own confirmation rule: a find by an L or M line whose K or L line the fitted range cannot hold is possible only (shown, never added).
        for c in strongestFirst(result.candidates.filter { $0.unconfirmable }) {
            uncorroborated.append("\(c.element) by \(UnlistedLineChecker.displayName(c.group)): \(c.possibleReason ?? "") \(stats(c))")
        }
        let suspects = strongestFirst(ruled.heldQuestions).map { c -> String in
            let sums = c.conflicts.filter { $0.kind == .sumPeak }
            var lead = sums.map { conflict -> String in
                var t = conflict.id
                if t.hasPrefix("sum-") { t.removeFirst(4) }
                let tail = "-" + conflict.element
                if t.hasSuffix(tail) { t.removeLast(tail.count) }
                return t
            }.joined(separator: " / ")
            if lead.isEmpty { lead = "pile-up" }
            return "\(lead)? (or \(ElementWindows.label(ofLineID: c.group))) at \(String(format: "%.3f", c.energyKeV)) keV: \(stats(c))"
        }
        var notes = (refinementNote.map { [$0] } ?? []) + result.notes
        for (element, reason) in result.refused where !LineConflicts.refusedElements.contains(element) { notes.append("\(element) not tested: \(reason)") }
        if !ruled.withheld.isEmpty {
            notes.append("Withheld by the rules: " + ruled.withheld.map { w in
                "\(UnlistedLineChecker.displayName(w.candidate.group)) (\(w.rule.rawValue), \(w.why))"
            }.joined(separator: ", ") + ".")
        }
        if !ruled.familyWithheld.isEmpty {
            notes.append("Withheld by the family rule: " + ruled.familyWithheld.map { "\($0.element) (\($0.familyNote ?? ""))" }.joined(separator: " ") )
        }
        if !ruled.rules.isNone { notes.append("Rules " + ProposalRules.source + ".") }
        return AutoIDOutcome(region: regionName, suggestions: suggestions, suspects: suspects, excesses: excesses, uncorroborated: uncorroborated, notes: notes)
    }

    // MARK: Quantify

    package struct Quantified: Sendable {
        package let fit: PooledQuantification
        package let input: PooledQuantificationInput
    }

    /// The pooled fit of the region's spectrum with the method: Cliff-Lorimer with the typed or computed k, the absorption
    /// correction, the axis refinement (cached per region, elements and background: it does not depend on the estimator, k
    /// or absorption). Throws the kit's refusal in its own words.
    package static func quantify(spectrum: [UInt64], region: EDXRegion, source: any SpectrumImageSource, method: QuantificationMethod,
                                 cache: EDXComputeCache) throws -> Quantified {
        let on = method.elements.filter { $0.role != .off }.map(\.symbol).sorted().joined(separator: ",")
        let key = "\(region.cacheKey)|\(on)|\(method.background.rawValue)|\(method.polynomialOrder ?? 6)|"
            + "\(method.beamEnergyKeV ?? source.metadata.beamEnergyKeV ?? 0)|\(method.fitToKeV.map { "\($0)" } ?? "default")"
        let input = PooledQuantificationInput(counts: spectrum, axis: source.energyAxis, method: method, metadata: source.metadata,
                                              regionName: region.name, pixelCount: region.pixelCount(nx: source.nx, ny: source.ny),
                                              refinement: cache.refinement(key))
        let fit = try PooledQuantifier.run(input, tables: tables)
        if let r = fit.refinement, input.refinement == nil { cache.setRefinement(r, key) }
        return Quantified(fit: fit, input: input)
    }

    /// The unlisted-line check and the fit-range sensitivity for a finished fit (the proposer, 5 to 20 s at 4096 channels,
    /// cached per region and settings; then one refit). Throws `ProposerError.cancelled` when the caller's task was cancelled.
    package static func checked(_ q: Quantified, region: EDXRegion, cache: EDXComputeCache) throws -> PooledQuantification {
        let key = "\(region.cacheKey)|\(q.fit.usedAxis)|\(UnlistedLineChecker.proposerSettings(q.fit))"
        let proposal: ProposalResult
        if let p = cache.proposal(key) { proposal = p } else {
            proposal = try UnlistedLineChecker.propose(counts: q.input.counts.map { Double($0) }, quantification: q.fit)
            cache.setProposal(proposal, key)
        }
        let check = UnlistedLineChecker.check(proposal: proposal, input: q.input, quantification: q.fit)
        var shown = UnlistedLineChecker.withholding(q.fit, check)
        if let s = FitRangeSensitivityCheck.run(input: q.input, quantification: q.fit) {
            shown = FitRangeSensitivityCheck.attaching(shown, s)
        }
        return shown
    }

    // MARK: Export

    /// The first `#` line of the results CSV names this app; the kit's own default is the neutral "Spectroscopy quantification".
    package static let csvTitle = "macTEM Spectroscopy quantification"

    package static func resultsCSV(_ q: PooledQuantification, regionName: String) -> String {
        SpectroscopyExport.csv(q, regionName: regionName, title: csvTitle)
    }

    /// The region's spectrum as text: energy of each channel (keV, the file's axis) and its counts.
    package static func spectrumCSV(counts: [UInt64], axis: EnergyAxis, fileName: String, regionName: String) -> String {
        var out = ["# \(csvTitle.replacingOccurrences(of: "quantification", with: "spectrum")), file: \(fileName), region: \(regionName)",
                   "# energy axis of the file: E(i) = offset + i \u{00B7} dispersion, offset \(String(format: "%.6g", axis.offset)) keV, dispersion \(String(format: "%.6g", axis.scale)) keV",
                   "energy_keV,counts"]
        for (i, c) in counts.enumerated() { out.append(String(format: "%.6f,%llu", axis.energy(ofChannel: i), c)) }
        return out.joined(separator: "\n") + "\n"
    }
}
