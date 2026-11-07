//
//  IndexingResult.swift
//  Role: a Hough run of the Indexing room as it lands (docs/sem/design/indexing-room.md §3, §6): one solution per scan point, filled
//        row by row, so the map grows in place and a stopped run keeps its indexed prefix; the map's layers (IPF-Z, IPF-X, IPF-Y,
//        Phase, CI, Fit, Bands, PQ, D-SEM-84) as RGBA, one pixel per scan point; the status line's readout; the Bands table of the
//        pattern on screen, and each detected band's centre line on that pattern for the overlay.
//
//  Colours: the IPF layers are orix's `IPFColorKeyTSL` of the phase's point group (parity-tested, `SEMColorKeyParityTests`); Phase
//  is the phase's colour; the scalar layers are grey from their smallest to their largest value over the points reached. A point
//  the run has not indexed is black, as orix draws `not_indexed`; a point the run has not reached shows the scan's mean intensity,
//  dimmed, so the map reads as the Patterns room's navigator until Index has passed.
//

import Foundation

/// The Indexing room's map layers (D-SEM-84).
package nonisolated enum IndexingLayer: String, Sendable, CaseIterable, Identifiable, Codable {
    case ipfZ, ipfX, ipfY, phase, confidence, fit, bands, patternQuality

    package var id: String { rawValue }

    /// The picker's word.
    package var title: String {
        switch self {
        case .ipfZ: "IPF-Z"
        case .ipfX: "IPF-X"
        case .ipfY: "IPF-Y"
        case .phase: "Phase"
        case .confidence: "Confidence index"
        case .fit: "Fit"
        case .bands: "Matched bands"
        case .patternQuality: "Pattern quality"
        }
    }

    /// The sample direction an IPF layer colours, nil for the others.
    package var direction: SIMD3<Double>? {
        switch self {
        case .ipfZ: Vector3.z
        case .ipfX: Vector3.x
        case .ipfY: Vector3.y
        default: nil
        }
    }

    /// Whether each point's colour is its own (IPF, Phase); a scalar layer's grey depends on the range of every point reached.
    package var isPointwise: Bool { direction != nil || self == .phase }

    /// What a grey scalar layer says, pyEBSDindex's names: "CI (cm)", "fit (°)".
    package var help: String {
        switch self {
        case .ipfZ, .ipfX, .ipfY: "The crystal direction along the sample's \(title.suffix(1).lowercased()) axis, in the phase's IPF colour key (orix's TSL key)"
        case .phase: "Each point in its phase's colour"
        case .confidence: "pyEBSDindex's confidence metric (cm): the votes of the matched families over all votes, 0 to 1"
        case .fit: "The mean angle between the detected and the matched band normals, degrees"
        case .bands: "The number of detected bands matched to the phase's reflectors"
        case .patternQuality: "The mean Radon peak of the detected bands (pyEBSDindex's pq)"
        }
    }

    /// The scalar of a solution on this layer; nil where it has none (the orientation's layers on a point not indexed).
    package func value(_ s: HoughIndexer.Solution) -> Double? {
        switch self {
        case .confidence: return s.phase >= 0 ? s.confidence : nil
        case .fit: return s.phase >= 0 ? s.fit : nil
        case .bands: return Double(s.matchedBands)
        case .patternQuality: return s.patternQuality.isFinite ? s.patternQuality : nil
        case .ipfZ, .ipfX, .ipfY, .phase: return nil
        }
    }
}

/// One Hough run of a scan, filled row by row.
package nonisolated struct IndexingResult: Sendable {
    package let scanRows: Int
    package let scanColumns: Int
    /// The phases indexed against; a solution's `phase` indexes this list.
    package let phases: [IndexingPhase]
    /// One per scan point in map order; nil until its row has landed.
    package private(set) var solutions: [HoughIndexer.Solution?]
    /// The rows landed (they land in order: a stopped run keeps rows 0..<rowsDone).
    package private(set) var rowsDone = 0

    package init(scanRows: Int, scanColumns: Int, phases: [IndexingPhase]) {
        self.scanRows = scanRows
        self.scanColumns = scanColumns
        self.phases = phases
        solutions = [HoughIndexer.Solution?](repeating: nil, count: max(scanRows, 0) * max(scanColumns, 0))
    }

    /// Lands scan row `row`'s solutions; a row of the wrong length or outside the scan is dropped.
    package mutating func land(_ row: [HoughIndexer.Solution], at index: Int) {
        guard index >= 0, index < scanRows, row.count == scanColumns else { return }
        for c in 0..<scanColumns { solutions[index * scanColumns + c] = row[c] }
        rowsDone = max(rowsDone, index + 1)
    }

    package var isComplete: Bool { rowsDone >= scanRows }
    package var pointCount: Int { scanRows * scanColumns }
    package var reachedCount: Int { solutions.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    package var indexedCount: Int { solutions.reduce(0) { $0 + (($1?.phase ?? -1) >= 0 ? 1 : 0) } }

    /// Points indexed as each phase, in `phases` order.
    package var countsByPhase: [Int] {
        var counts = [Int](repeating: 0, count: phases.count)
        for case let s? in solutions where phases.indices.contains(s.phase) { counts[s.phase] += 1 }
        return counts
    }

    package func solution(at position: EBSDPosition) -> HoughIndexer.Solution? {
        guard position.isInside(rows: scanRows, columns: scanColumns) else { return nil }
        return solutions[position.index(columns: scanColumns)]
    }

    package func phase(of s: HoughIndexer.Solution) -> IndexingPhase? {
        phases.indices.contains(s.phase) ? phases[s.phase] : nil
    }

    /// orix's Bunge Euler angles (φ₁, Φ, φ₂) of a solution's orientation, degrees, φ₁ and φ₂ in [0, 360).
    package static func eulerDegrees(_ s: HoughIndexer.Solution) -> SIMD3<Double> {
        Rotation(unit: s.quaternion).euler * (180 / Double.pi)
    }

    // MARK: - The status line

    private static func fixed(_ v: Double, _ digits: Int, _ locale: Locale) -> String {
        guard v.isFinite else { return "—" }
        return v.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(digits)))
    }

    /// The status line over the map: "row 12 · col 40 · Ni · φ₁ 12,3° Φ 44,0° φ₂ 271,5° · CI 0,82 · fit 0,6° · bands 9 of 10"; a point
    /// not indexed says so with its band count, a point the run has not reached says "not indexed yet". nil outside the scan.
    package func readout(at position: EBSDPosition, locale: Locale = .autoupdatingCurrent) -> String? {
        guard position.isInside(rows: scanRows, columns: scanColumns) else { return nil }
        let head = "row \(position.row) · col \(position.column)"
        guard let s = solution(at: position) else { return head + " · not indexed yet" }
        let bands = "bands \(s.matchedBands) of \(s.bandMatch.count)"
        guard let indexedPhase = self.phase(of: s) else { return head + " · not indexed · " + bands }
        let e = Self.eulerDegrees(s)
        return head + " · \(indexedPhase.name) · φ₁ \(Self.fixed(e.x, 1, locale))° Φ \(Self.fixed(e.y, 1, locale))° φ₂ \(Self.fixed(e.z, 1, locale))°"
            + " · CI \(Self.fixed(s.confidence, 2, locale)) · fit \(Self.fixed(s.fit, 2, locale))° · " + bands
    }

    // MARK: - The results as a table

    /// One row of the Results table and of the CSV.
    package struct Row: Sendable, Identifiable, Equatable {
        /// The point's index in map order.
        package let id: Int
        package let row: Int
        package let column: Int
        package let phase: String
        package let phi1: Double
        package let capitalPhi: Double
        package let phi2: Double
        package let confidence: Double
        package let fit: Double
        package let bands: Int
        package let patternQuality: Double

        package var position: EBSDPosition { EBSDPosition(row: row, column: column) }
    }

    /// The reached points, in map order. Not indexed: phase "not indexed", the Euler angles and fit NaN, CI 0.
    package var rows: [Row] {
        var out: [Row] = []
        out.reserveCapacity(rowsDone * scanColumns)
        for (i, solution) in solutions.enumerated() {
            guard let s = solution else { continue }
            let indexed = self.phase(of: s)
            let e = indexed == nil ? SIMD3<Double>(.nan, .nan, .nan) : Self.eulerDegrees(s)
            out.append(Row(id: i, row: i / scanColumns, column: i % scanColumns, phase: indexed?.name ?? "not indexed",
                           phi1: e.x, capitalPhi: e.y, phi2: e.z, confidence: indexed == nil ? 0 : s.confidence,
                           fit: indexed == nil ? .nan : s.fit, bands: s.matchedBands, patternQuality: s.patternQuality))
        }
        return out
    }

    /// The reached points as CSV (locale-free numbers, one header line): row, column, x and y in the scan unit, phase, the Euler
    /// angles in degrees, CI, fit, matched bands, pattern quality.
    package func csv(stepX: Double, stepY: Double) -> String {
        var lines = ["row,column,x,y,phase,phi1_deg,Phi_deg,phi2_deg,ci,fit_deg,matched_bands,pattern_quality"]
        func number(_ v: Double) -> String { v.isFinite ? String(format: "%.6g", v) : "" }
        for r in rows {
            let phase = r.phase.contains(",") ? "\"\(r.phase)\"" : r.phase
            lines.append([String(r.row), String(r.column), number(Double(r.column) * stepX), number(Double(r.row) * stepY), phase,
                          number(r.phi1), number(r.capitalPhi), number(r.phi2), number(r.confidence), number(r.fit), String(r.bands),
                          number(r.patternQuality)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - The map as RGBA

/// The colour keys of one layer for a run's phases, made once (a key's sector and azimuth table take a few milliseconds).
package nonisolated struct IndexingPalette: Sendable {
    package let layer: IndexingLayer
    private let keys: [IPFColorKeyTSL?]
    private let phaseColors: [SIMD3<Double>]

    package init(layer: IndexingLayer, phases: [IndexingPhase]) {
        self.layer = layer
        if let direction = layer.direction {
            keys = phases.map { phase in phase.pointGroup.map { IPFColorKeyTSL($0, direction: direction) } }
        } else {
            keys = phases.map { _ in nil }
        }
        phaseColors = phases.map(\.colorRGB)
    }

    /// The colour of each indexed solution in `solutions` (by its position in the list), nil for the points with none on this layer.
    func pointColors(_ solutions: [HoughIndexer.Solution?]) -> [SIMD3<Double>?] {
        var out = [SIMD3<Double>?](repeating: nil, count: solutions.count)
        switch layer {
        case .phase:
            for (i, s) in solutions.enumerated() {
                if let s, phaseColors.indices.contains(s.phase) { out[i] = phaseColors[s.phase] }
            }
        case .ipfZ, .ipfX, .ipfY:
            for (p, key) in keys.enumerated() {
                guard let key else { continue }
                let members = solutions.indices.filter { solutions[$0]?.phase == p }
                guard !members.isEmpty else { continue }
                let colors = key.color(of: members.map { solutions[$0]?.quaternion ?? SIMD4(1, 0, 0, 0) })
                for (k, i) in members.enumerated() { out[i] = colors[k] }
            }
        case .confidence, .fit, .bands, .patternQuality:
            break
        }
        return out
    }
}

package nonisolated enum IndexingRaster {
    /// How much of the mean intensity a point the run has not reached shows.
    static let backdropDimming = 0.45

    /// The layer over the whole scan, 4 bytes per point (alpha 255), scan row-major. `backdrop`: the scan's mean intensity per
    /// point (the Patterns room's navigator), drawn dimmed where the run has not reached; nil draws those points dark grey.
    package static func rgba(_ result: IndexingResult, palette: IndexingPalette, backdrop: [Float]?) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: result.pointCount * 4)
        paint(&out, result: result, palette: palette, backdrop: backdrop, rows: 0..<result.scanRows)
        return out
    }

    /// The scan before any run: the mean intensity dimmed, or dark grey without it.
    package static func backdrop(scanRows: Int, scanColumns: Int, means: [Float]?) -> [UInt8] {
        let n = max(scanRows, 0) * max(scanColumns, 0)
        var out = [UInt8](repeating: 255, count: n * 4)
        let range = meanRange(means, count: n)
        for i in 0..<n {
            let g = grey(means, i, range)
            out[4 * i] = g; out[4 * i + 1] = g; out[4 * i + 2] = g
        }
        return out
    }

    /// Repaints scan rows `rows` of `rgba` (a pointwise layer only needs the rows that landed; a scalar layer's range moves with
    /// every row, so the caller repaints all of it).
    package static func paint(_ rgba: inout [UInt8], result: IndexingResult, palette: IndexingPalette, backdrop: [Float]?, rows: Range<Int>) {
        let columns = result.scanColumns
        let clamped = max(rows.lowerBound, 0)..<min(rows.upperBound, result.scanRows)
        guard rgba.count == result.pointCount * 4, !clamped.isEmpty else { return }
        let start = clamped.lowerBound * columns, end = clamped.upperBound * columns
        let slice = Array(result.solutions[start..<end])
        let colors = palette.layer.isPointwise ? palette.pointColors(slice) : []
        let scalar = palette.layer.isPointwise ? nil : scalarRange(result, layer: palette.layer)
        let means = meanRange(backdrop, count: result.pointCount)
        for (k, solution) in slice.enumerated() {
            let i = start + k
            let rgb: SIMD3<Double>
            if let s = solution {
                if palette.layer.isPointwise {
                    rgb = colors[k] ?? SIMD3(0, 0, 0)
                } else if let v = palette.layer.value(s), let scalar {
                    let t = scalar.upperBound > scalar.lowerBound ? (v - scalar.lowerBound) / (scalar.upperBound - scalar.lowerBound) : 1
                    rgb = SIMD3(repeating: min(max(t, 0), 1))
                } else {
                    rgb = SIMD3(0, 0, 0)
                }
                rgba[4 * i] = byte(rgb.x); rgba[4 * i + 1] = byte(rgb.y); rgba[4 * i + 2] = byte(rgb.z)
            } else {
                let g = grey(backdrop, i, means)
                rgba[4 * i] = g; rgba[4 * i + 1] = g; rgba[4 * i + 2] = g
            }
            rgba[4 * i + 3] = 255
        }
    }

    /// The smallest and largest finite value of a scalar layer over the points reached; nil when there is none.
    package static func scalarRange(_ result: IndexingResult, layer: IndexingLayer) -> ClosedRange<Double>? {
        var lo = Double.infinity, hi = -Double.infinity
        for case let s? in result.solutions {
            guard let v = layer.value(s), v.isFinite else { continue }
            lo = min(lo, v); hi = max(hi, v)
        }
        return lo <= hi ? lo...hi : nil
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }

    private static func meanRange(_ means: [Float]?, count: Int) -> ClosedRange<Float>? {
        guard let means, means.count == count else { return nil }
        var lo = Float.infinity, hi = -Float.infinity
        for v in means where v.isFinite { lo = min(lo, v); hi = max(hi, v) }
        return lo <= hi ? lo...hi : nil
    }

    private static func grey(_ means: [Float]?, _ i: Int, _ range: ClosedRange<Float>?) -> UInt8 {
        guard let means, let range, means.indices.contains(i), means[i].isFinite else { return byte(0.15) }
        let t = range.upperBound > range.lowerBound ? Double((means[i] - range.lowerBound) / (range.upperBound - range.lowerBound)) : 0.5
        return byte(t * backdropDimming)
    }
}

// MARK: - The bands of the pattern on screen

/// One detected band of the pattern on screen, with what the solution made of it (the Bands table and the overlay).
package nonisolated struct IndexedBand: Sendable, Identifiable, Equatable {
    /// The band's rank among the detected (1 is the strongest).
    package let id: Int
    /// pyEBSDindex's band: distance from the pattern centre (px) and angle (degrees), lower-left origin.
    package let rho: Double
    package let thetaDegrees: Double
    /// The convolved Radon peak and the band-width metric.
    package let peak: Double
    package let width: Double
    package let isValid: Bool
    /// The matched reflector family ("{111}") and the angle between the band's normal and it after the fit (degrees); nil when the
    /// band was not matched or the point is not indexed.
    package let family: String?
    package let fitDegrees: Double?
    /// The band's centre line on the pattern, (column, row) with pixel centres at integers and row 0 at the top; nil when it misses.
    package let start: SIMD2<Double>?
    package let end: SIMD2<Double>?

    package var isMatched: Bool { family != nil }

    /// The bands of a pattern of `rows` × `columns` px with what `solution` (nil: none) matched them to, `libraries` in the solution's
    /// phase order.
    package static func bands(_ bands: [HoughBandDetector.Band], solution: HoughIndexer.Solution?, libraries: [HoughReflectorLibrary],
                              rows: Int, columns: Int) -> [IndexedBand] {
        let library: HoughReflectorLibrary? = solution.flatMap { libraries.indices.contains($0.phase) ? libraries[$0.phase] : nil }
        return bands.enumerated().map { k, band in
            var family: String?, fit: Double?
            if let solution, let library, solution.bandMatch.indices.contains(k) {
                let variant = solution.bandMatch[k]
                if variant >= 0, library.familyID.indices.contains(variant) {
                    let f = library.familyID[variant]
                    if library.poleFamilies.indices.contains(f) { family = familyLabel(library.poleFamilies[f]) }
                    if solution.bandFit.indices.contains(k) { fit = solution.bandFit[k] }
                }
            }
            let line = band.valid ? segment(rho: band.rho, theta: band.theta, rows: rows, columns: columns) : nil
            return IndexedBand(id: k + 1, rho: band.rho, thetaDegrees: band.theta * 180 / Double.pi, peak: band.max, width: band.width,
                               isValid: band.valid, family: family, fitDegrees: fit, start: line?.start, end: line?.end)
        }
    }

    /// "{111}", "{002}", "{10-11}".
    package static func familyLabel(_ hkl: [Int]) -> String {
        let wide = hkl.contains { abs($0) > 9 }
        return "{" + hkl.map(String.init).joined(separator: wide ? " " : "") + "}"
    }

    /// The centre line of the band (rho, theta) on a pattern of `rows` × `columns` px, clipped to the pattern. The band detector's
    /// frame (`HoughBandDetector`): x right and y UP from the pattern centre, the band the points with x cos θ + y sin θ = ρ; the
    /// pattern's pixel centres are at column − (columns − 1)/2 and (rows − 1)/2 − row in it.
    package static func segment(rho: Double, theta: Double, rows: Int, columns: Int) -> (start: SIMD2<Double>, end: SIMD2<Double>)? {
        guard rows > 0, columns > 0, rho.isFinite, theta.isFinite else { return nil }
        let s = sin(theta), c = cos(theta)
        let foot = SIMD2(rho * c + Double(columns - 1) / 2, Double(rows - 1) / 2 - rho * s)
        let direction = SIMD2(s, c)
        let lo = SIMD2(-0.5, -0.5), hi = SIMD2(Double(columns) - 0.5, Double(rows) - 0.5)
        var t0 = -Double.infinity, t1 = Double.infinity
        for axis in 0..<2 {
            if abs(direction[axis]) < 1e-12 {
                if foot[axis] < lo[axis] || foot[axis] > hi[axis] { return nil }
            } else {
                let a = (lo[axis] - foot[axis]) / direction[axis], b = (hi[axis] - foot[axis]) / direction[axis]
                t0 = max(t0, min(a, b))
                t1 = min(t1, max(a, b))
            }
        }
        guard t0 < t1 else { return nil }
        return (foot + t0 * direction, foot + t1 * direction)
    }
}

// MARK: - The colour key

package nonisolated enum IndexingColorKey {
    /// The IPF colour key of a point group as a picture about `side` pixels on its longer edge (orix's TSL key in the stereographic
    /// projection; pixels outside the sector are transparent).
    package static func image(_ pointGroup: PointGroup, side: Int = 160) -> IPFKeyImage {
        let key = DirectionColorKeyTSL(pointGroup)
        let extent = key.sector.stereographicExtent ?? (-1...1, -1...1)
        let span = max(extent.x.upperBound - extent.x.lowerBound, extent.y.upperBound - extent.y.lowerBound)
        return key.keyImage(step: max(span / Double(max(side, 8)), 1e-4), extent: extent)
    }
}
