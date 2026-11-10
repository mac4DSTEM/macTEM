//
//  OrientationMaps.swift
//  The pictures the Maps room draws of a `CrystalMap` (docs/sem/design/orientation-maps-room.md §3), as orix 0.15.0's
//  `CrystalMap.plot` draws them: per-point colours (the IPF colours of each phase with `IPFColorKeyTSL` of its point group along a
//  sample direction, or each point's phase colour) laid into the map's rows and columns by `CrystalMap.get_map_data`
//  (`CrystalMap.mapData`), a point not in data or not indexed black in an IPF map as orix leaves it (its colour array starts at
//  zero). A property (image quality, confidence index, MAD, ...) is a scalar map of its values. Also the hover's words and the
//  unit cell the orientation pane draws for a map without patterns. GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE.
//
//  Parity: `tools/parity/sem` bundle `m3/maps-room-sdss` (the IPF-X, IPF-Y, IPF-Z and phase map images of orix-data's two-phase
//  steel, atol 1e-6 for the IPF colours, exact for the phase colours), docs/parity.md.
//

import Foundation

/// A sample direction an IPF map is coloured along.
package nonisolated enum SampleDirection: String, CaseIterable, Sendable, Hashable {
    case x, y, z

    package var vector: SIMD3<Double> {
        switch self {
        case .x: Vector3.x
        case .y: Vector3.y
        case .z: Vector3.z
        }
    }
}

/// What the Maps room's map pane draws.
package nonisolated enum OrientationMapLayer: Hashable, Sendable, Identifiable {
    /// The inverse pole figure colours along a sample direction (TSL key per phase).
    case ipf(SampleDirection)
    /// Each point in its phase's colour.
    case phase
    /// A per-point property of the file (image quality, confidence index, fit, MAD, band contrast, ...), as a scalar map.
    case property(String)
    /// A map the grain analysis makes (`MapAnalysis`): KAM, GOS, GND, the grains or the Schmid factor.
    case derived(DerivedMapLayer)

    package var id: String {
        switch self {
        case .ipf(let d): "ipf-\(d.rawValue)"
        case .phase: "phase"
        case .property(let name): "property-\(name)"
        case .derived(let d): "derived-\(d.rawValue)"
        }
    }

    /// "IPF-Z", "Phase", "iq".
    package var title: String {
        switch self {
        case .ipf(let d): "IPF-\(d.rawValue.uppercased())"
        case .phase: "Phase"
        case .property(let name): name
        case .derived(let d): d.title
        }
    }

    /// Whether the layer is colours (a key or a legend explains it) rather than values (a colour bar).
    package var isColour: Bool {
        switch self {
        case .ipf, .phase, .derived(.grains): true
        case .property, .derived: false
        }
    }
}

/// One map picture: rows x columns, row-major from the top row, either RGB colours (0...1) or scalar values (NaN where a point is
/// not in data), with which grid cells hold a point.
package nonisolated struct OrientationMapRaster: Sendable, Equatable {
    package var rows: Int
    package var columns: Int
    /// The colours of a colour layer; nil for a property.
    package var rgb: [SIMD3<Double>]?
    /// The values of a property layer; nil for a colour layer.
    package var values: [Double]?
    /// Whether each cell holds a point in data.
    package var inData: [Bool]

    /// 8-bit RGBA (straight alpha), row-major from the top: a colour layer's colours, opaque where a point is in data and clear
    /// where none is. nil for a property layer.
    package var rgba8: [UInt8]? {
        guard let rgb else { return nil }
        var out = [UInt8](repeating: 0, count: rgb.count * 4)
        for (i, c) in rgb.enumerated() {
            out[4 * i] = OrientationMapRaster.byte(c.x)
            out[4 * i + 1] = OrientationMapRaster.byte(c.y)
            out[4 * i + 2] = OrientationMapRaster.byte(c.z)
            out[4 * i + 3] = inData[i] ? 255 : 0
        }
        return out
    }

    /// The finite range of a property layer's values; nil for a colour layer or when no value is finite.
    package var valueRange: ClosedRange<Double>? {
        guard let values else { return nil }
        let finite = values.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max() else { return nil }
        return lo...hi
    }

    /// A channel (0...1) to the nearest byte; NaN, the colour of a cell past the last point of a map that does not fill its grid, is 0.
    static func byte(_ v: Double) -> UInt8 { v.isNaN ? 0 : UInt8((min(max(v, 0), 1) * 255).rounded()) }
}

package nonisolated enum OrientationMaps {
    /// The map's picture size: rows then columns of the points in data (orix's `shape`); a 1D map is one row.
    package static func gridShape(_ map: CrystalMap) -> (rows: Int, columns: Int) {
        let shape = map.shape
        switch shape.count {
        case 2: return (shape[0], shape[1])
        case 1: return (1, shape[0])
        default: return (0, 0)
        }
    }

    /// The layers a map offers, in the Maps control's order: IPF-Z, IPF-X, IPF-Y, Phase, then the file's properties by name.
    package static func layers(of map: CrystalMap) -> [OrientationMapLayer] {
        [.ipf(.z), .ipf(.x), .ipf(.y), .phase] + map.propertyNames.filter { $0 != "phase_id" }.map { .property($0) }
    }

    /// orix's IPF colours of every point in data, in data order: each phase with `IPFColorKeyTSL(point_group, direction)`, a point
    /// not indexed or of a phase without a point group black (0, 0, 0), as orix's plot leaves it.
    package static func ipfColors(_ map: CrystalMap, direction: SIMD3<Double>) -> [SIMD3<Double>] {
        let ids = map.phaseIDs
        let rotations = map.rotationsInData
        var rgb = [SIMD3<Double>](repeating: .zero, count: ids.count)
        for (id, phase) in map.phases.entries where id != PhaseList.notIndexedID {
            guard let group = phase.pointGroup else { continue }
            let rows = ids.indices.filter { ids[$0] == id }
            guard !rows.isEmpty else { continue }
            let colours = IPFColorKeyTSL(group, direction: direction).color(of: rows.map { rotations[$0] })
            for (r, c) in zip(rows, colours) { rgb[r] = c }
        }
        return rgb
    }

    /// Each point in data in its phase's colour (orix's `Phase.color_rgb`; the not-indexed phase white), black for a colour
    /// matplotlib's Tableau list does not name.
    package static func phaseColors(_ map: CrystalMap) -> [SIMD3<Double>] {
        var byID: [Int: SIMD3<Double>] = [:]
        for (id, phase) in map.phases.entries { byID[id] = phase.colorRGB ?? .zero }
        return map.phaseIDs.map { byID[$0] ?? .zero }
    }

    /// Per-point colours (in data order) laid into the map's rows and columns (`CrystalMap.mapData` per channel), black where no
    /// point is in data.
    package static func image(_ colours: [SIMD3<Double>], of map: CrystalMap) -> [SIMD3<Double>] {
        let r = map.mapData(colours.map(\.x), fill: 0), g = map.mapData(colours.map(\.y), fill: 0), b = map.mapData(colours.map(\.z), fill: 0)
        return r.indices.map { SIMD3(r[$0], g[$0], b[$0]) }
    }

    /// The index into the map's per-point arrays (`euler`, `allPhaseIDs`, `properties`) of every grid cell, row-major, −1 where no
    /// point is in data. A map whose points stop short of its grid (a scan stopped mid-row) has no point in the cells past its last
    /// one: `mapData` leaves them NaN, and they read −1 too.
    package static func pointIndexGrid(_ map: CrystalMap) -> [Int] {
        map.mapData(map.ids.map(Double.init), fill: -1).map { $0.isFinite ? Int($0) : -1 }
    }

    /// The picture of `layer`: an IPF or phase map as orix's plot draws it, or a property's values (NaN where no point is in data).
    package static func raster(_ layer: OrientationMapLayer, of map: CrystalMap) -> OrientationMapRaster {
        let (rows, columns) = gridShape(map)
        let inData = pointIndexGrid(map).map { $0 >= 0 }
        switch layer {
        case .ipf(let direction):
            return OrientationMapRaster(rows: rows, columns: columns, rgb: image(ipfColors(map, direction: direction.vector), of: map), values: nil, inData: inData)
        case .phase:
            return OrientationMapRaster(rows: rows, columns: columns, rgb: image(phaseColors(map), of: map), values: nil, inData: inData)
        case .property(let name):
            let values = map.mapData(named: name, fill: .nan) ?? [Double](repeating: .nan, count: rows * columns)
            return OrientationMapRaster(rows: rows, columns: columns, rgb: nil, values: values, inData: inData)
        case .derived(let d):
            // The analysis at its default settings; the Maps room draws its own run's (`MapAnalysis.raster`).
            if let analysis = try? MapAnalysis.run(map) { return analysis.raster(d) }
            return OrientationMapRaster(rows: rows, columns: columns, rgb: nil, values: [Double](repeating: .nan, count: rows * columns), inData: inData)
        }
    }

    // MARK: The hover

    /// The status line over the map (design §3): "row 12 · col 40 · austenite · φ₁ 12,3° Φ 44,0° φ₂ 271,5° · iq 24,4 · ci 0,799";
    /// "· not indexed" for a point without a phase; nil off the map or where no point is. `shape` is the map's `gridShape` where the
    /// caller holds it (the hover asks on every move); nil works it out from the coordinates.
    package static func readout(_ map: CrystalMap, grid: [Int], row: Int, column: Int, shape: (rows: Int, columns: Int)? = nil,
                                locale: Locale = .autoupdatingCurrent) -> String? {
        let (rows, columns) = shape ?? gridShape(map)
        guard row >= 0, row < rows, column >= 0, column < columns, grid.count == rows * columns else { return nil }
        let i = grid[row * columns + column]
        guard i >= 0 else { return nil }
        var text = "row \(row) · col \(column)"
        let id = map.allPhaseIDs[i]
        if id == PhaseList.notIndexedID {
            text += " · not indexed"
        } else {
            let name = map.phases[id: id]?.name ?? ""
            text += " · " + (name.isEmpty ? "phase \(id)" : name)
            let e = map.euler[i] * (180 / Double.pi)
            text += " · φ₁ \(degrees(e.x, locale)) Φ \(degrees(e.y, locale)) φ₂ \(degrees(e.z, locale))"
        }
        for name in map.propertyNames where name != "phase_id" {
            guard let value = map.properties[name]?[i], value.isFinite else { continue }
            text += " · \(name) \(UnitDisplay.number(value, digits: 4, locale: locale))"
        }
        return text
    }

    /// One decimal and the degree sign, as the design's status line writes an angle.
    static func degrees(_ value: Double, _ locale: Locale) -> String {
        value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(1))) + "°"
    }

    // MARK: The colour key

    /// A corner of the key's sector and its crystal direction, at its place in the key image (pixels from the top left).
    package nonisolated struct KeyLabel: Sendable, Equatable {
        package var text: String
        package var column: Double
        package var row: Double
    }

    /// The pixels across the key image's longer side.
    package static let keySide = 240

    /// The TSL key of `group`'s Laue group as an image of `keySide` pixels across its sector's extent (`DirectionColorKeyTSL.keyImage`,
    /// the exact colour of every pixel, D-SEM-40), and the sector's corners labelled with their directions for the cubic groups, whose
    /// Cartesian axes are the crystal's (`[001]`, `[101]`, `[111]` for m-3m); other groups' corners are left unlabelled (their
    /// directions need the lattice).
    package static func keyImage(for group: PointGroup) -> (IPFKeyImage, [KeyLabel]) {
        let key = DirectionColorKeyTSL(group)
        let extent = key.sector.stereographicExtent ?? (-1...1, -1...1)
        let side = max(extent.x.upperBound - extent.x.lowerBound, extent.y.upperBound - extent.y.lowerBound)
        let image = key.keyImage(step: side / Double(keySide), extent: extent)
        guard key.symmetry.system == "cubic" else { return (image, []) }
        let projection = StereographicProjection(pole: -1)
        var labels: [KeyLabel] = []
        for vertex in key.sector.vertices {
            guard let text = directionLabel(vertex), let xy = projection.vectorToXY([vertex]).first else { continue }
            labels.append(KeyLabel(text: text, column: (xy.x - extent.x.lowerBound) / image.step,
                                   row: Double(image.height - 1) - (xy.y - extent.y.lowerBound) / image.step))
        }
        return (image, labels)
    }

    /// "[101]" for a direction whose components are small whole multiples of its smallest non-zero one (a bar over a negative index
    /// is written as a minus); nil otherwise.
    package static func directionLabel(_ v: SIMD3<Double>) -> String? {
        let parts = [v.x, v.y, v.z]
        guard let smallest = parts.map(abs).filter({ $0 > 1e-9 }).min() else { return nil }
        var digits: [String] = []
        for p in parts {
            let n = p / smallest
            guard abs(n - n.rounded()) < 1e-6, abs(n) < 10 else { return nil }
            digits.append(String(Int(n.rounded())))
        }
        return "[" + digits.joined() + "]"
    }

    // MARK: The unit cell

    /// The twelve edges of the unit cell of `phase` (its lattice, else orix's default lattice of its crystal system) in the sample
    /// frame of the orientation `q` (sample to crystal, as the map's rotations): each crystal vector v drawn at q⁻¹ v, centred on
    /// the origin and scaled so the farthest corner lies at distance 1. The orientation pane draws them seen down the sample's z.
    package static func unitCellEdges(phase: CrystalPhase, rotation q: SIMD4<Double>) -> [(SIMD3<Double>, SIMD3<Double>)] {
        let lattice: CrystalLattice
        if let l = phase.lattice, l.count == 6, l.allSatisfy({ $0.isFinite && $0 > 0 }) {
            lattice = CrystalLattice(a: l[0], b: l[1], c: l[2], alpha: l[3], beta: l[4], gamma: l[5])
        } else {
            lattice = CrystalLattice.defaultLattice(system: phase.pointGroup?.system)
        }
        let a = lattice.base[0], b = lattice.base[1], c = lattice.base[2]
        let centre = (a + b + c) / 2
        let inverse = Rotation(q).inverse
        func corner(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Double> {
            inverse * (Double(i) * a + Double(j) * b + Double(k) * c - centre)
        }
        var edges: [(SIMD3<Double>, SIMD3<Double>)] = []
        for j in 0...1 { for k in 0...1 { edges.append((corner(0, j, k), corner(1, j, k))) } }
        for i in 0...1 { for k in 0...1 { edges.append((corner(i, 0, k), corner(i, 1, k))) } }
        for i in 0...1 { for j in 0...1 { edges.append((corner(i, j, 0), corner(i, j, 1))) } }
        let reach = edges.flatMap { [$0.0, $0.1] }.map { ($0 * $0).sum().squareRoot() }.max() ?? 1
        guard reach > 0 else { return edges }
        return edges.map { ($0.0 / reach, $0.1 / reach) }
    }
}
