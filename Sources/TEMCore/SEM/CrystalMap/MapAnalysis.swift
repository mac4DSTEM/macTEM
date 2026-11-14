//
//  MapAnalysis.swift
//  What the Maps room computes from a crystal map beyond its colours (docs/sem/design/orientation-maps-room.md §3-§4, brief
//  P5-04): the grains, their boundaries, KAM and GOS (DefDAP 1.3.1's functions, `GrainAnalysis`), the GND density
//  (`NyeTensor`, Pantleon 2008 as DefDAP computes it), the grain table (size, equivalent diameter, mean orientation, GOS,
//  neighbours) with the ASTM E112 grain size number from the mean lineal intercept, each grain's Schmid factors and slip traces
//  (`SlipTraceAnalysis`), and the texture of one phase (pole figures, the IPF density and ODF sections, `PoleFigures` and
//  `OrientationDensity`, orix 0.15.0's). Every number is one of those ported functions on the map's own arrays; this file lays
//  them out as the room draws them: per grid cell, row-major, NaN where no value is.
//
//  The frame: the map's Euler angles as the reader gave them (orix's convention, lab to crystal), so the Schmid load and the
//  slip traces are in the frame the IPF maps colour; DefDAP's EDAX frame change is not applied (D-SEM-101). The quaternion
//  DefDAP builds from the Bunge angles is orix's `eu2qu` term for term, so a grain's mean orientation reads back through
//  `RotationConversions.qu2eu`.
//
//  Parity: the grain map, KAM and GOS of orix-data's two-phase steel against `m5/grains-sdss`; the pole figures and ODF are the
//  ported functions held to `m5/texture-cubic` and `m5/texture-ti` (docs/parity.md).
//

import Foundation

/// A map the Maps room draws from the analysis, beside the file's own columns.
package nonisolated enum DerivedMapLayer: String, CaseIterable, Sendable, Hashable {
    /// Kernel average misorientation, degrees (first neighbours of the same phase, above the KAM maximum dropped).
    case kam
    /// Grain orientation spread, degrees: each point carries its grain's.
    case gos
    /// Geometrically necessary dislocation density, log10 of m⁻².
    case gnd
    /// Each grain in its own colour.
    case grains
    /// Each grain's largest Schmid factor for the load direction.
    case schmid

    package var title: String {
        switch self {
        case .kam: "KAM"
        case .gos: "GOS"
        case .gnd: "GND"
        case .grains: "Grains"
        case .schmid: "Schmid factor"
        }
    }

    /// The colour bar's unit.
    package var unit: String {
        switch self {
        case .kam, .gos: "°"
        case .gnd: "log₁₀ m⁻²"
        case .grains, .schmid: ""
        }
    }
}

/// The analysis settings the inspector's Grains and Misorientation sections hold.
package nonisolated struct MapAnalysisSettings: Sendable, Equatable, Hashable {
    /// The misorientation (°) above which two neighbours are on different grains.
    package var boundaryDegrees: Double = 5
    /// Grains of fewer points are left out (their points read −2, DefDAP's mark).
    package var minimumSize: Int = 10
    /// KAM drops a neighbour more misoriented than this (°).
    package var kamMaxDegrees: Double = 5

    package init(boundaryDegrees: Double = 5, minimumSize: Int = 10, kamMaxDegrees: Double = 5) {
        self.boundaryDegrees = boundaryDegrees
        self.minimumSize = minimumSize
        self.kamMaxDegrees = kamMaxDegrees
    }
}

/// One row of the grain table.
package nonisolated struct GrainRow: Sendable, Equatable, Identifiable {
    /// The grain's number on the grain map (1, 2, ...).
    package let id: Int
    /// The crystal map's phase id, nil for a grain DefDAP could not give one phase.
    package let phaseID: Int?
    package let phaseName: String
    package let points: Int
    /// Points × step², in the scan unit squared.
    package let area: Double
    /// The diameter of the circle of the grain's area, in the scan unit.
    package let diameter: Double
    /// The mean orientation (DefDAP's `calc_average_ori`) as Bunge angles in degrees.
    package let euler: SIMD3<Double>
    /// The mean orientation as a quaternion (lab to crystal).
    package let orientation: SIMD4<Double>
    /// The grain orientation spread, degrees.
    package let gosDegrees: Double
    /// Grains sharing a boundary with this one.
    package let neighbours: Int
    /// The centroid: column, row.
    package let centroid: SIMD2<Double>
}

/// A grain's slip systems under one load: per plane group its trace and the largest Schmid factor of its directions.
package nonisolated struct GrainSlip: Sendable, Equatable {
    package struct Plane: Sendable, Equatable {
        /// "(111)".
        package let label: String
        /// Radians from the map's +y axis, counter-clockwise; NaN for a plane parallel to the map.
        package let traceAngle: Double
        /// Radians between the plane and the map plane.
        package let inclination: Double
        /// The largest Schmid factor of the plane's systems.
        package let schmid: Double
        /// DefDAP's trace colour of the group.
        package let colour: String
    }

    package let grain: Int
    package let planes: [Plane]
    package var maximumSchmid: Double { planes.map(\.schmid).max() ?? .nan }
}

package nonisolated struct MapAnalysis: Sendable {
    package enum Refusal: Error, Equatable, Sendable, LocalizedError {
        /// The points in data do not fill the map's rectangle in row order (a sliced map).
        case notAGrid
        case grains(String)

        package var errorDescription: String? {
            switch self {
            case .notAGrid: "Grains need the whole map: this one is a slice of its scan."
            case .grains(let text): text
            }
        }
    }

    package let settings: MapAnalysisSettings
    package let rows: Int
    package let columns: Int
    package let grainMap: GrainMap
    package let grains: GrainAnalysis
    /// Per grid cell, the GND density in m⁻² (NaN where not indexed); nil when the first phase has no crystal structure DefDAP knows.
    package let gnd: [Double]?
    /// The grain table, in grain number order.
    package let table: [GrainRow]
    /// The crystal map's phase id of each of DefDAP's phase numbers (index = number − 1).
    package let phaseIDs: [Int]
    /// The mean lineal intercept in the scan unit; nil without a boundary.
    package let meanLinealIntercept: Double?
    /// The scan unit of the lengths.
    package let scanUnit: String
    /// Why `gnd` is nil although the phase has a structure DefDAP knows (a step in no length unit); nil otherwise.
    package let gndRefusal: String?

    /// The analysis of `map` with `settings` (a whole map: the points in data fill rows × columns in row order). `isCancelled` is asked
    /// through the grain analysis (`GrainAnalysis.run`) and before the GND and the table; it throws `CancellationError` once it says so
    /// (the Maps room's Stop).
    package static func run(_ map: CrystalMap, settings: MapAnalysisSettings = MapAnalysisSettings(),
                            isCancelled: () -> Bool = { false }) throws -> MapAnalysis {
        let (rows, columns) = OrientationMaps.gridShape(map)
        guard rows * columns == map.size, OrientationMaps.pointIndexGrid(map) == map.ids else { throw Refusal.notAGrid }
        let grainMap: GrainMap
        do { grainMap = try GrainMap(map: map) } catch { throw Refusal.grains(error.localizedDescription) }
        let analysis: GrainAnalysis
        do {
            analysis = try GrainAnalysis.run(grainMap, boundaryDegrees: settings.boundaryDegrees, minimumSize: settings.minimumSize,
                                             kam: .symmetric(thresholdDegrees: settings.kamMaxDegrees), isCancelled: isCancelled)
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw Refusal.grains(error.localizedDescription)
        }
        if isCancelled() { throw CancellationError() }
        let indexed = map.phases.entries.filter { $0.id != PhaseList.notIndexedID }
        let phaseIDs = indexed.map(\.id)

        // GND: DefDAP takes the primary phase's crystal structure for the whole map; the step in micrometres.
        var gnd: [Double]?
        var gndRefusal: String?
        if let first = indexed.first, let group = first.phase.pointGroup, let structure = DefDAPCrystalStructure(pointGroup: group) {
            // A step in no length unit refuses the GND rather than guessing µm (macEM#611).
            if let micrometres = Self.micrometres(grainMap.step, unit: map.scanUnit) {
                let result = NyeTensor.compute(quaternions: grainMap.quaternions, rows: rows, columns: columns, stepMicrons: micrometres,
                                               structure: structure)
                gnd = zip(result.gnd, grainMap.phase).map { $1 == 0 ? .nan : $0 }
            } else {
                gndRefusal = Self.gndNeedsALength(unit: map.scanUnit)
            }
        }
        if isCancelled() { throw CancellationError() }

        // The table.
        let segmentation = analysis.segmentation
        let gos = analysis.statistics.gos
        var neighbourCount = [Int](repeating: 0, count: segmentation.grains.count)
        for pair in analysis.neighbours {
            if pair.a < neighbourCount.count { neighbourCount[pair.a] += 1 }
            if pair.b < neighbourCount.count { neighbourCount[pair.b] += 1 }
        }
        let areas = segmentation.areas, diameters = segmentation.equivalentCircleDiameters
        var table: [GrainRow] = []
        table.reserveCapacity(segmentation.grains.count)
        for (k, grain) in segmentation.grains.enumerated() {
            let phaseID = grain.phaseIndex.map { phaseIDs[$0] }
            let name = phaseID.flatMap { id in map.phases[id: id]?.name } ?? "mixed"
            var sum = SIMD2<Double>(0, 0)
            for p in grain.points { sum += SIMD2(Double(p % columns), Double(p / columns)) }
            let q = analysis.statistics.averageOrientations[k]
            table.append(GrainRow(id: grain.id + 1, phaseID: phaseID, phaseName: name, points: grain.size, area: areas[k],
                                  diameter: diameters[k], euler: RotationConversions.qu2eu(q) * (180 / Double.pi), orientation: q,
                                  gosDegrees: gos[k] * 180 / Double.pi, neighbours: neighbourCount[k],
                                  centroid: sum / Double(max(grain.size, 1))))
        }
        return MapAnalysis(settings: settings, rows: rows, columns: columns, grainMap: grainMap, grains: analysis, gnd: gnd, table: table,
                           phaseIDs: phaseIDs,
                           meanLinealIntercept: GrainSegmentation.meanLinealIntercept(boundaries: analysis.boundaries, step: grainMap.step, stepY: grainMap.stepY),
                           scanUnit: map.scanUnit, gndRefusal: gndRefusal)
    }

    /// The same off the caller's actor; a cancelled task stops at its next row or grain and throws `CancellationError`.
    @concurrent package static func runAsync(_ map: CrystalMap, settings: MapAnalysisSettings) async throws -> MapAnalysis {
        try run(map, settings: settings, isCancelled: { Task.isCancelled })
    }

    /// A length in `unit` in micrometres (the readers write "um"; nm and mm convert); nil for a unit that is no length ("px", or one
    /// the app does not know), which before macEM#611 was taken as micrometres.
    package static func micrometres(_ length: Double, unit: String) -> Double? {
        switch unit.lowercased() {
        case "nm": length / 1000
        case "mm": length * 1000
        case "um", "µm", "μm", "micron", "microns": length
        default: nil
        }
    }

    /// Why the map has no GND density although its phase has a structure: its step is in no length unit.
    package static func gndNeedsALength(unit: String) -> String {
        "No GND density: the map's step is in \(unit.isEmpty ? "no unit" : "\"\(unit)\"") rather than a length, so a density per m² cannot be given. The grains, KAM and GOS do not need one."
    }

    // MARK: Numbers

    /// The grains' mean equivalent diameter by number and weighted by area, in the scan unit.
    package var meanDiameter: (byNumber: Double, byArea: Double)? {
        guard !table.isEmpty else { return nil }
        let n = Double(table.count)
        let byNumber = table.reduce(0) { $0 + $1.diameter } / n
        let totalArea = table.reduce(0) { $0 + $1.area }
        let byArea = totalArea > 0 ? table.reduce(0) { $0 + $1.diameter * $1.area } / totalArea : .nan
        return (byNumber, byArea)
    }

    /// ASTM E112's grain size number from the mean lineal intercept; nil without a boundary or with a scan unit that is no length.
    package var astmGrainSizeNumber: Double? {
        guard let l = meanLinealIntercept, let um = Self.micrometres(l, unit: scanUnit) else { return nil }
        return GrainSegmentation.astmGrainSizeNumber(meanLinealInterceptMillimetres: um / 1000)
    }

    /// The grain number (1, 2, ...) at a grid cell; nil for a point of no grain (too small, or not indexed).
    package func grain(atRow row: Int, column: Int) -> Int? {
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        let g = grains.segmentation.grainMap[row * columns + column]
        return g > 0 ? g : nil
    }

    // MARK: Pictures

    /// The values of a scalar derived layer per grid cell (NaN where none); nil for the grain colours or a layer with no numbers
    /// (GND without a crystal structure, Schmid without slip systems).
    package func values(_ layer: DerivedMapLayer, slip: [GrainSlip] = []) -> [Double]? {
        switch layer {
        case .kam:
            return grains.kam.map { $0 * 180 / Double.pi }
        case .gos:
            return grains.statistics.gosMap(grains.segmentation).map { $0 * 180 / Double.pi }
        case .gnd:
            return gnd?.map { $0 > 0 ? log10($0) : .nan }
        case .schmid:
            guard !slip.isEmpty else { return nil }
            var byGrain: [Int: Double] = [:]
            for s in slip { byGrain[s.grain] = s.maximumSchmid }
            return grains.segmentation.grainMap.map { byGrain[$0] ?? .nan }
        case .grains:
            return nil
        }
    }

    /// The grain colours per grid cell: each grain a hue from the golden ratio by its number (neighbours read apart), points of
    /// grains below the minimum size grey, points of no grain black.
    package var grainColours: [SIMD3<Double>] {
        grains.segmentation.grainMap.map { g in
            if g == -2 { return SIMD3(0.5, 0.5, 0.5) }
            guard g > 0 else { return .zero }
            return Self.grainColour(g)
        }
    }

    /// The colour of grain `number`.
    package static func grainColour(_ number: Int) -> SIMD3<Double> {
        let hue = (Double(number) * 0.618_033_988_749_895).truncatingRemainder(dividingBy: 1)
        let value = number % 2 == 0 ? 0.95 : 0.78
        return DirectionColorKeyTSL.hsvToRGB(hue, 0.55, value)
    }

    /// The raster of a derived layer.
    package func raster(_ layer: DerivedMapLayer, slip: [GrainSlip] = []) -> OrientationMapRaster {
        let inData = grainMap.phase.map { $0 != 0 }
        if layer == .grains {
            return OrientationMapRaster(rows: rows, columns: columns, rgb: grainColours, values: nil, inData: inData)
        }
        let values = self.values(layer, slip: slip) ?? [Double](repeating: .nan, count: rows * columns)
        return OrientationMapRaster(rows: rows, columns: columns, rgb: nil, values: values, inData: inData)
    }

    // MARK: Boundaries

    /// The boundary edges to draw, in image coordinates (a pixel's centre at integers): the edge right of a point is the segment
    /// x = c + ½ from y = r − ½ to r + ½, the edge below it y = r + ½. Grain boundaries that are not phase boundaries, and phase
    /// boundaries, apart.
    package func boundaryEdges() -> (grain: [(SIMD2<Double>, SIMD2<Double>)], phase: [(SIMD2<Double>, SIMD2<Double>)]) {
        let b = grains.boundaries
        var grain: [(SIMD2<Double>, SIMD2<Double>)] = [], phase: [(SIMD2<Double>, SIMD2<Double>)] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let i = r * columns + c
                if c + 1 < columns, b.grainX[i] || b.phaseX[i] {
                    let edge = (SIMD2(Double(c) + 0.5, Double(r) - 0.5), SIMD2(Double(c) + 0.5, Double(r) + 0.5))
                    if b.phaseX[i] { phase.append(edge) } else { grain.append(edge) }
                }
                if r + 1 < rows, b.grainY[i] || b.phaseY[i] {
                    let edge = (SIMD2(Double(c) - 0.5, Double(r) + 0.5), SIMD2(Double(c) + 0.5, Double(r) + 0.5))
                    if b.phaseY[i] { phase.append(edge) } else { grain.append(edge) }
                }
            }
        }
        return (grain, phase)
    }

    /// The outline of grain `number`: every edge between one of its points and a point that is not (the map's border included).
    package func outline(of number: Int) -> [(SIMD2<Double>, SIMD2<Double>)] { outline(of: [number]) }

    /// The outlines of several grains in one pass over the map: every edge between a point of one of them and a point of another grain
    /// or of none (two selected neighbours keep the edge between them).
    package func outline(of numbers: Set<Int>) -> [(SIMD2<Double>, SIMD2<Double>)] {
        guard !numbers.isEmpty else { return [] }
        let g = grains.segmentation.grainMap
        var out: [(SIMD2<Double>, SIMD2<Double>)] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let number = g[r * columns + c]
                guard numbers.contains(number) else { continue }
                let x = Double(c), y = Double(r)
                if c + 1 >= columns || g[r * columns + c + 1] != number { out.append((SIMD2(x + 0.5, y - 0.5), SIMD2(x + 0.5, y + 0.5))) }
                if c == 0 || g[r * columns + c - 1] != number { out.append((SIMD2(x - 0.5, y - 0.5), SIMD2(x - 0.5, y + 0.5))) }
                if r + 1 >= rows || g[(r + 1) * columns + c] != number { out.append((SIMD2(x - 0.5, y + 0.5), SIMD2(x + 0.5, y + 0.5))) }
                if r == 0 || g[(r - 1) * columns + c] != number { out.append((SIMD2(x - 0.5, y - 0.5), SIMD2(x + 0.5, y - 0.5))) }
            }
        }
        return out
    }

    // MARK: Histograms (macTEM#239)

    /// The Histogram tab's distributions: KAM per point (°), GOS per grain (°), equivalent circle diameter per grain (scan unit).
    package enum HistogramKind: String, CaseIterable, Sendable, Hashable {
        case kam = "KAM"
        case gos = "GOS"
        case grainSize = "Grain size"
    }

    /// The values a histogram counts: every finite KAM of the map, or one value per grain of the table.
    package func histogramValues(_ kind: HistogramKind) -> [Double] {
        switch kind {
        case .kam: grains.kam.filter(\.isFinite).map { $0 * 180 / Double.pi }
        case .gos: table.map(\.gosDegrees).filter(\.isFinite)
        case .grainSize: table.map(\.diameter).filter(\.isFinite)
        }
    }

    /// The value one grain contributes to a per-grain histogram (nil for KAM, which is per point).
    package func histogramValue(_ kind: HistogramKind, of row: GrainRow) -> Double? {
        switch kind {
        case .kam: nil
        case .gos: row.gosDegrees
        case .grainSize: row.diameter
        }
    }

    /// `numpy.histogram` of the values over `bins` equal bins: KAM from 0 to the KAM maximum (the values it can take), GOS and grain
    /// size from 0 to their largest value (1 when every value is 0).
    package func histogram(_ kind: HistogramKind, bins: Int = 40) -> AngleHistogram {
        let values = histogramValues(kind)
        let top: Double
        switch kind {
        case .kam: top = settings.kamMaxDegrees
        case .gos, .grainSize: top = values.max().map { $0 > 0 ? $0 : 1 } ?? 1
        }
        let n = max(bins, 1)
        let edges = (0...n).map { top * Double($0) / Double(n) }
        return AngleHistogram(values: values, edges: edges)
    }

    // MARK: Slip

    /// DefDAP's slip-system file for a phase: hexagonal → `hexagonal_withca`; cubic with space group 225 → `cubic_fcc`, 229 →
    /// `cubic_bcc`; a cubic phase whose file names no space group (EDAX's .ang) by its name: "austenite" or "fcc" → `cubic_fcc`,
    /// "ferrite", "martensite" or "bcc" → `cubic_bcc` (D-SEM-101); nil otherwise, and the inspector's Slip section picks.
    package static func defaultSlipFile(for phase: CrystalPhase) -> SlipSystemFile? {
        guard let group = phase.pointGroup, let structure = DefDAPCrystalStructure(pointGroup: group) else { return nil }
        switch structure {
        case .hexagonal: return .hexagonalWithCA
        case .cubic:
            switch phase.spaceGroup {
            case 225: return .cubicFCC
            case 229: return .cubicBCC
            case .some: return nil
            case .none:
                let name = phase.name.lowercased()
                if ["austenite", "fcc"].contains(where: { name.contains($0) }) { return .cubicFCC }
                if ["ferrite", "martensite", "bcc"].contains(where: { name.contains($0) }) { return .cubicBCC }
                return nil
            }
        }
    }

    /// The slip systems of `file` for a phase (DefDAP's, without systems whose direction leaves their plane); nil when the phase's
    /// crystal structure does not fit the file.
    package static func slipSystems(_ file: SlipSystemFile, phase: CrystalPhase) -> SlipSystemSet? {
        guard let group = phase.pointGroup, let structure = DefDAPCrystalStructure(pointGroup: group) else { return nil }
        let crystal: SlipCrystal
        switch structure {
        case .cubic:
            guard !file.isHexagonal else { return nil }
            crystal = .cubic
        case .hexagonal:
            guard file.isHexagonal else { return nil }
            let l = phase.lattice ?? []
            crystal = .hexagonal(cOverA: l.count >= 3 && l[0] > 0 ? l[2] / l[0] : 1.633)
        }
        return (try? SlipSystemSet.load(file, crystal: crystal))?.consistent
    }

    /// Every grain's slip under `load` (a sample direction), for the phases `files` gives systems.
    package func slip(load: SIMD3<Double>, files: [Int: SlipSystemFile], phases: PhaseList) -> [GrainSlip] {
        var systems: [Int: SlipSystemSet] = [:]
        for (id, file) in files {
            if let phase = phases[id: id], let set = Self.slipSystems(file, phase: phase) { systems[id] = set }
        }
        return table.compactMap { row in
            guard let id = row.phaseID, let set = systems[id] else { return nil }
            let schmid = SlipTraceAnalysis.schmidFactors(orientation: row.orientation, load: load, systems: set)
            let traces = SlipTraceAnalysis.traces(orientation: row.orientation, systems: set)
            let planes = set.groups.indices.map { k in
                GrainSlip.Plane(label: set.groups[k].first?.planeLabel ?? "", traceAngle: traces[k].angle, inclination: traces[k].inclination,
                                schmid: schmid[k].max() ?? .nan,
                                // DefDAP's `add_traces`: a trace past the colour list takes the list's last colour.
                                colour: k < set.traceColours.count ? set.traceColours[k] : (set.traceColours.last ?? "black"))
            }
            return GrainSlip(grain: row.id, planes: planes)
        }
    }
}

// MARK: - Texture

/// The texture of one phase of a map, as the Maps room's bottom pane draws it.
package nonisolated struct MapTexture: Sendable {
    package struct Figure: Sendable {
        /// "{111}", "IPF-Z", "φ₂ = 45°".
        package let title: String
        package let raster: TextureRaster
        /// The figure's largest density (multiples of a random distribution).
        package let maximum: Double
        /// A pole figure's crystal directions (the family's symmetry-equivalent poles); empty for the IPF density and an ODF section.
        package var poles: [SIMD3<Double>] = []
    }

    /// Where `orientations` (lab to crystal) put a pole figure's poles, in the figure's unit square (0, 0 the top-left corner, as its
    /// raster is drawn): each pole turned into the sample frame, folded onto the upper hemisphere (a pole is an axis) and projected as
    /// `TextureRaster.stereographic` projects the unit disk. Empty for a figure without poles.
    package static func poleMarkers(_ figure: Figure, orientations: [SIMD4<Double>]) -> [SIMD2<Double>] {
        guard !figure.poles.isEmpty else { return [] }
        var out: [SIMD2<Double>] = []
        for q in orientations {
            let inverse = Rotation(q).inverse
            for p in figure.poles {
                var v = inverse * p
                if v.z < 0 { v = -v }
                let xy = StereographicProjection.project(v, pole: -1)
                out.append(SIMD2((xy.x + 1) / 2, (1 - xy.y) / 2))
            }
        }
        return out
    }

    package let phaseID: Int
    package let phaseName: String
    package let points: Int
    /// The points the ODF sections used (every k-th point of the phase, at most `odfPointLimit`).
    package let odfPoints: Int
    package let poleFigures: [Figure]
    package let inversePoleFigure: Figure?
    package let odfSections: [Figure]

    /// The ODF sums its kernel over every orientation at every node: past this many points the sections take every k-th point.
    package static let odfPointLimit = 5000

    /// The pole families shown for a point group: {100} {110} {111} for cubic, {0001} {10-10} {11-20} for hexagonal, {100} {010}
    /// {001} otherwise.
    package static func families(for group: PointGroup) -> [(title: String, indices: [Double])] {
        switch group.system ?? "" {
        case "cubic": [("{100}", [1, 0, 0]), ("{110}", [1, 1, 0]), ("{111}", [1, 1, 1])]
        case "hexagonal": [("{0001}", [0, 0, 0, 1]), ("{10-10}", [1, 0, -1, 0]), ("{11-20}", [1, 1, -2, 0])]
        default: [("{100}", [1, 0, 0]), ("{010}", [0, 1, 0]), ("{001}", [0, 0, 1])]
        }
    }

    /// The φ₂ sections shown: 0°, 45° and 65° for cubic (the rolling-texture sections), else 0° and half the φ₂ range.
    package static func sections(for group: PointGroup) -> [Double] {
        if group.system == "cubic" { return [0, 45, 65] }
        let range = OrientationDensity.bungeRanges(for: group).phi2
        return [0, range / 2]
    }

    /// The pole figures (stereographic, upper hemisphere, 1° bins smoothed at `sigma`°), the IPF-Z density in the colour key's
    /// sector and the ODF sections of phase `phaseID`, each as a `size`-pixel raster (the ODF at its 5° nodes). A sigma of +∞, or
    /// one whose kernel passes `PoleDensityFunction.maximumKernelRadius` on either grid, is refused before any figure is made; 0,
    /// a negative sigma (−∞ too) and NaN smooth nothing, as scipy's filter skips them.
    package static func compute(_ map: CrystalMap, phaseID: Int, size: Int = 181, sigma: Double = 5,
                                odfHalfWidth: Double = OrientationDensity.defaultHalfWidthDegrees) throws -> MapTexture {
        guard let phase = map.phases[id: phaseID], let group = phase.pointGroup else {
            throw MapAnalysis.Refusal.grains("The phase has no point group: no texture.")
        }
        guard PoleDensityFunction.smoothingFits(sigma: sigma), PoleDensityFunction.smoothingFits(sigma: sigma, symmetry: group.laue) else {
            throw MapAnalysis.Refusal.grains("The texture's smoothing sigma must be a finite number of degrees, at most 512°.")
        }
        let orientations = try map.points(ofPhases: [phase.name]).orientations()
        let lattice: CrystalLattice
        if let l = phase.lattice, l.count == 6, l.allSatisfy({ $0.isFinite && $0 > 0 }) {
            lattice = CrystalLattice(a: l[0], b: l[1], c: l[2], alpha: l[3], beta: l[4], gamma: l[5])
        } else {
            lattice = CrystalLattice.defaultLattice(system: group.system)
        }
        var poles: [Figure] = []
        for family in families(for: group) {
            let vectors = try PoleFigures.poles(family: family.indices, lattice: lattice, group: group)
            let density = PoleFigures.poleFigure(orientations, poles: vectors, sigma: sigma)
            poles.append(Figure(title: family.title, raster: TextureRaster.stereographic(density, size: size), maximum: density.maximum,
                                poles: vectors))
        }
        let key = DirectionColorKeyTSL(group)
        let ipf = PoleFigures.inversePoleFigure(orientations, laue: group.laue, sigma: sigma)
        let extent = key.sector.stereographicExtent ?? (-1...1, -1...1)
        let inverse = Figure(title: "IPF-Z", raster: TextureRaster.stereographic(ipf, size: size, extent: extent), maximum: ipf.maximum)

        let stride = max(1, (orientations.count + odfPointLimit - 1) / odfPointLimit)
        let sample = stride == 1 ? orientations
            : Orientations(quaternions: Swift.stride(from: 0, to: orientations.count, by: stride).map { orientations.quaternions[$0] },
                           symmetry: orientations.symmetry)
        let odf = sections(for: group).map { phi2 -> Figure in
            let s = OrientationDensity.section(sample, phi2Degrees: phi2, halfWidthDegrees: odfHalfWidth)
            return Figure(title: "φ₂ = \(Int(phi2.rounded()))°", raster: TextureRaster.section(s), maximum: s.maximum)
        }
        return MapTexture(phaseID: phaseID, phaseName: phase.name, points: orientations.count, odfPoints: sample.count,
                          poleFigures: poles, inversePoleFigure: inverse, odfSections: odf)
    }

    /// The same off the caller's actor.
    @concurrent package static func computeAsync(_ map: CrystalMap, phaseID: Int) async throws -> MapTexture {
        try compute(map, phaseID: phaseID)
    }
}
