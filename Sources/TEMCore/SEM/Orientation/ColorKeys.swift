//
//  ColorKeys.swift
//  orix 0.15.0's colour keys: `DirectionColorKeyTSL` (the EDAX TSL inverse-pole-figure key as MTEX implements it, after
//  Nolze & Hielscher, J. Appl. Cryst. 49 (2016) 1786: the direction in the Laue group's fundamental sector, its polar
//  coordinates about the sector's barycentre with MTEX's azimuth correction, HSL to HSV to RGB as matplotlib converts),
//  `IPFColorKeyTSL` (an orientation coloured by the crystal direction of a sample direction), its key image, and
//  `EulerColorKey` (Bunge angles in the Euler fundamental region of the proper subgroup over the region's maxima).
//  GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE. Parity: `tools/parity/sem` bundles `m3/ipf-color-keys`,
//  `m3/ipf-sdss-ferrite-austenite` and `m3/ipf-nickel-ebsd-large`, colours within 1e-6.
//
//  One deviation, decision D-SEM in docs/decisions.md: the key image is drawn with the exact colour of every pixel's
//  direction, where orix interpolates colours of a 2° sampling with scipy's cubic `griddata`; the two differ by up to
//  0.048 inside the sector, and the exact image is the one whose colours the map's pixels carry.
//

import Foundation

/// The TSL colour key of crystal directions in the fundamental sector of a Laue group.
package nonisolated struct DirectionColorKeyTSL: Sendable {
    /// The Laue group of the symmetry the key was made for.
    package let symmetry: PointGroup
    package let sector: FundamentalSector
    private let unitCenter: SIMD3<Double>
    private let rx: SIMD3<Double>
    private let polarFromCenterAngle: Bool
    /// MTEX's `correctAngle` table: the corrected azimuth at numpy's `linspace(0, 2π, 1000)`; nil without vertices.
    private let azimuthTable: [Double]?

    private static let azimuthSteps = 1000

    /// A key for `symmetry`'s Laue group (a non-Laue group is replaced by its Laue group, as orix does).
    package init(_ symmetry: PointGroup) {
        let laue = symmetry.laue
        self.symmetry = laue
        let sector = laue.fundamentalSector
        self.sector = sector
        let center = Vector3.unit(sector.center ?? Vector3.z)
        unitCenter = center
        let rx = (sector.vertices.isEmpty ? Vector3.x : Vector3.z) - center
        self.rx = rx
        polarFromCenterAngle = sector.normals.allSatisfy { Vector3.dot($0, center) == 0 }
        azimuthTable = sector.vertices.isEmpty ? nil : DirectionColorKeyTSL.correctedAzimuths(sector: sector, center: center, rx: rx)
    }

    /// `direction2color`: the RGB of each crystal direction (components in [0, 1]).
    package func color(of directions: [SIMD3<Double>]) -> [SIMD3<Double>] {
        symmetry.projectToFundamentalSector(directions, sector: sector).map(colorInSector)
    }

    /// The colour of one direction already in the sector.
    private func colorInSector(_ h: SIMD3<Double>) -> SIMD3<Double> {
        let (azimuth, polar) = polarCoordinates(h)
        return DirectionColorKeyTSL.rgb(azimuth: azimuth, polar: 0.5 + polar / 2)
    }

    /// `polar_coordinates_in_sector`: the azimuth about the barycentre (from [001], or [100] for a sector without vertices,
    /// corrected so that each vertex spans a third of the hues) and the relative distance from the barycentre to the
    /// boundary along the great circle through the direction (1 at the centre, 0 on the boundary).
    private func polarCoordinates(_ direction: SIMD3<Double>) -> (azimuth: Double, polar: Double) {
        let v = Vector3.unit(direction)
        var azimuth = DirectionColorKeyTSL.azimuth(center: unitCenter, rx: rx, v: v)
        if let table = azimuthTable {
            azimuth = DirectionColorKeyTSL.interp(azimuth, xp: DirectionColorKeyTSL.azimuthGrid, fp: table)
        }
        if polarFromCenterAngle {
            return (azimuth, Vector3.angle(unitCenter, v) / Double.pi)
        }
        let vCenterNormal = Vector3.unit(Vector3.cross(v, unitCenter))
        var polar = Double.infinity
        for normal in sector.normals {
            let boundary = Vector3.unit(Vector3.cross(vCenterNormal, normal))
            var d = Vector3.angle(-v, boundary)
            d /= Vector3.angle(-unitCenter, boundary)
            if d.isNaN { d = 1 }
            polar = min(polar, d)
        }
        return (azimuth, polar)
    }

    /// `_calculate_azimuth` (MTEX's `calcAngle`): the angle of v − centre about the centre from `rx` made orthogonal to it,
    /// in [0, 2π), 0 where undefined.
    private static func azimuth(center: SIMD3<Double>, rx rx0: SIMD3<Double>, v: SIMD3<Double>) -> Double {
        let rx = Vector3.unit(rx0 - Vector3.dot(rx0, center) * center)
        let ry = Vector3.unit(Vector3.cross(center, rx))
        let d = Vector3.unit(v - center)
        let a = Vector3.pythonMod(atan2(Vector3.dot(ry, d), Vector3.dot(rx, d)), 2 * Double.pi)
        return a.isNaN ? 0 : a
    }

    private static let azimuthGrid = Vector3.linspace(0, 2 * Double.pi, azimuthSteps)

    /// `_correct_azimuth` (MTEX's `correctAngle`) as a table on `azimuthGrid`: the boundary's angular distance from the
    /// centre in 999 directions, normalised so that each of three vertices' arcs gets a third, integrated to 2π.
    private static func correctedAzimuths(sector: FundamentalSector, center: SIMD3<Double>, rx: SIMD3<Double>) -> [Double] {
        let m = azimuthSteps
        let w = Vector3.unit(Vector3.cross(rx, center))
        var polar = [Double](repeating: 0, count: m - 1)
        for k in 0..<(m - 1) {
            let normal = Rotation.fromAxisAngle(center, azimuthGrid[k]) * w
            var smallest = Double.infinity
            for n in sector.normals {
                let a = Vector3.angle(Vector3.cross(n, normal), center)
                // numpy's `min` propagates NaN.
                if a.isNaN || smallest.isNaN { smallest = .nan } else if a < smallest { smallest = a }
            }
            polar[k] = smallest
        }
        let vertices = sector.vertices
        if vertices.count == 3 {
            var cuts = vertices.map { azimuth(center: center, rx: rx, v: $0) }.sorted()
                .map { Int((Double(m) * $0 / (2 * Double.pi)).rounded(.toNearestOrEven)) }
            if cuts[0] < 10 { cuts.removeFirst() }
            for range in [0..<cuts[0], cuts[0]..<cuts[1], cuts[1]..<polar.count] where !range.isEmpty {
                let share = polar[range].reduce(0, +) / 3
                for i in range { polar[i] /= share }
            }
        }
        let total = polar.reduce(0, +)
        var table = [Double](repeating: 0, count: m)
        var running = 0.0
        for k in 0..<(m - 1) {
            running += polar[k] / total
            table[k + 1] = running
        }
        return table.map { 2 * Double.pi * $0 }
    }

    /// numpy's `interp` on an increasing grid: clamped at the ends, linear between neighbours.
    private static func interp(_ x: Double, xp: [Double], fp: [Double]) -> Double {
        let last = xp.count - 1
        if x.isNaN { return x }
        if x <= xp[0] { return fp[0] }
        if x >= xp[last] { return fp[last] }
        var lo = 0, hi = last
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xp[mid] <= x { lo = mid } else { hi = mid }
        }
        let slope = (fp[lo + 1] - fp[lo]) / (xp[lo + 1] - xp[lo])
        return slope * (x - xp[lo]) + fp[lo]
    }

    /// `rgb_from_polar_coordinates`: hue = azimuth / 2π (mod 1), saturation 1, lightness = polar, converted HSL → HSV
    /// (MTEX's `hsl2hsv`) → RGB (matplotlib's `hsv_to_rgb`).
    package static func rgb(azimuth: Double, polar lightness: Double) -> SIMD3<Double> {
        let hue = Vector3.pythonMod(azimuth / (2 * Double.pi), 1)
        let l2 = 2 * lightness
        let s2 = 1 * (l2 <= 1 ? l2 : 2 - l2)
        var saturation = (2 * s2) / (l2 + s2)
        if saturation.isNaN { saturation = 0 }
        let value = (l2 + s2) / 2
        return hsvToRGB(hue, saturation, value)
    }

    /// matplotlib's `hsv_to_rgb` for one colour.
    package static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        if s == 0 { return SIMD3(v, v, v) }
        let i = Int(h * 6.0)
        let f = (h * 6.0) - Double(i)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))
        switch i {
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        case 5: return SIMD3(v, p, q)
        default: return i % 6 == 0 ? SIMD3(v, t, p) : SIMD3(.nan, .nan, .nan)
        }
    }

    // MARK: - Key image

    /// The key as an image in the stereographic projection (pole −1): pixels `step` apart from the lower-left corner of
    /// `extent` (numpy's `mgrid` counts, ceil((max − min) / step) per axis), rows from the top (largest y) down, each
    /// pixel the colour of its direction with alpha 1 inside the sector and (1, 1, 1, 0) outside. The extent defaults to
    /// the sector's, as orix's `_create_rgba_grid` takes it.
    package func keyImage(step: Double = 0.001, extent: (x: ClosedRange<Double>, y: ClosedRange<Double>)? = nil) -> IPFKeyImage {
        let e = extent ?? sector.stereographicExtent ?? (-1...1, -1...1)
        // A step that is not a positive number, or one so fine the key would pass 16 M pixels, draws an empty key, not a trap.
        var width = CheckedConversion.int(((e.x.upperBound - e.x.lowerBound) / step).rounded(.up)) ?? 0
        var height = CheckedConversion.int(((e.y.upperBound - e.y.lowerBound) / step).rounded(.up)) ?? 0
        if width <= 0 || height <= 0 || width > IPFKeyImage.maximumSide || height > IPFKeyImage.maximumSide || width * height > IPFKeyImage.maximumPixels {
            width = 0
            height = 0
        }
        let projection = StereographicProjection(pole: -1)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let y = e.y.lowerBound + Double(height - 1 - row) * step
            for col in 0..<width {
                let x = e.x.lowerBound + Double(col) * step
                let v = projection.xyToVector(SIMD2(x, y))
                let o = (row * width + col) * 4
                if sector.contains(v) {
                    let c = color(of: [v])[0]
                    rgba[o] = Float(c.x); rgba[o + 1] = Float(c.y); rgba[o + 2] = Float(c.z); rgba[o + 3] = 1
                } else {
                    rgba[o] = 1; rgba[o + 1] = 1; rgba[o + 2] = 1; rgba[o + 3] = 0
                }
            }
        }
        return IPFKeyImage(width: width, height: height, rgba: rgba, extent: e, step: step)
    }
}

/// A colour key drawn in the stereographic projection: RGBA in [0, 1], row-major from the top row.
package nonisolated struct IPFKeyImage: Sendable {
    /// The largest key `keyImage` draws: 16 M pixels, 16 384 a side.
    package static let maximumPixels = 1 << 24
    package static let maximumSide = 1 << 14
    package let width: Int
    package let height: Int
    package let rgba: [Float]
    package let extent: (x: ClosedRange<Double>, y: ClosedRange<Double>)
    package let step: Double

    /// The pixel at (row, column) from the top left.
    package func pixel(row: Int, column: Int) -> SIMD4<Float> {
        let o = (row * width + column) * 4
        return SIMD4(rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3])
    }

    /// 8-bit RGBA, premultiplied by alpha, for a bitmap context.
    package var premultipliedRGBA8: [UInt8] {
        var out = [UInt8](repeating: 0, count: rgba.count)
        for p in stride(from: 0, to: rgba.count, by: 4) {
            let a = rgba[p + 3]
            for c in 0..<3 { out[p + c] = CheckedConversion.unitByte(rgba[p + c] * a) }
            out[p + 3] = CheckedConversion.unitByte(a)
        }
        return out
    }
}

/// The TSL inverse-pole-figure key of orientations: the crystal direction of a sample direction, coloured by
/// `DirectionColorKeyTSL` of the symmetry's Laue group.
package nonisolated struct IPFColorKeyTSL: Sendable {
    package let directionKey: DirectionColorKeyTSL
    /// The sample direction (z, the IPF-Z map, by default).
    package let direction: SIMD3<Double>

    package init(_ symmetry: PointGroup, direction: SIMD3<Double> = Vector3.z) {
        directionKey = DirectionColorKeyTSL(symmetry)
        self.direction = direction
    }

    /// `orientation2color`: for each orientation O (unit quaternion, sample to crystal), the colour of O · direction.
    package func color(of quaternions: [SIMD4<Double>]) -> [SIMD3<Double>] {
        directionKey.color(of: quaternions.map { Rotation(unit: $0) * direction })
    }
}

/// orix's `EulerColorKey`: (φ1, Φ, φ2) in the Euler fundamental region of the proper subgroup, each over its maximum,
/// clipped to [0, 1].
package nonisolated struct EulerColorKey: Sendable {
    package let symmetry: PointGroup
    private let special: [Rotation]
    private let maxima: SIMD3<Double>
    private let gammaPeriod: Double

    package init(_ symmetry: PointGroup) {
        self.symmetry = symmetry
        let pg = symmetry.properSubgroup
        special = EulerColorKey.specialRotations(pg)
        let region = pg.eulerFundamentalRegion.map { Double($0) * (Double.pi / 180) }
        maxima = SIMD3(region[0], region[1], region[2])
        gammaPeriod = 2 * Double.pi / Double(pg.primaryAxisOrder ?? 1)
    }

    /// `Symmetry._special_rotation` (MTEX's `rotation_special`) of a proper group: the operations that are not rotations
    /// about the c-axis.
    private static func specialRotations(_ pg: PointGroup) -> [Rotation] {
        func axis(_ v: SIMD3<Double>, _ n: Int) -> [Rotation] {
            (0..<n).map { Rotation.fromAxisAngle(v, Double($0) * (2 * Double.pi / Double(n))) }
        }
        switch pg.properSubgroup.name ?? "" {
        case "1", "211", "121": return pg.elements.filter { !$0.improper }
        case "112", "3", "4", "6": return [pg.elements[0]]
        case "222", "422", "622", "32": return axis(-Vector3.x, 2)
        case "312": return axis(-SIMD3(1, -1, 0), 2)
        // orix's `outer(...).flatten()` runs the first operand's index fastest.
        case "23": return Rotation.outerFlattened(axis(-SIMD3(1, 1, 1), 3), axis(-Vector3.x, 2))
        case "432": return Rotation.outerFlattened(axis(-SIMD3(1, 1, 1), 3), axis(-SIMD3(1, 1, 0), 2))
        default: return [Rotation.identity]
        }
    }

    /// `Orientation.in_euler_fundamental_region` (MTEX's `project2EulerFR`): of the special operations times the
    /// orientation, the first whose Bunge angles (φ2 modulo 2π over the primary axis order) are in the region, else the
    /// first.
    package func eulerInFundamentalRegion(_ q: SIMD4<Double>) -> SIMD3<Double> {
        let o = Rotation(q)
        var first: SIMD3<Double>?
        for s in special {
            var e = (s * o).euler
            e.z = Vector3.pythonMod(e.z, gammaPeriod)
            if first == nil { first = e }
            if e.x <= maxima.x, e.y <= maxima.y, e.z <= maxima.z { return e }
        }
        return first ?? o.euler
    }

    /// `orientation2color`.
    package func color(of quaternions: [SIMD4<Double>]) -> [SIMD3<Double>] {
        quaternions.map { q in
            let e = eulerInFundamentalRegion(q) / maxima
            return SIMD3(min(max(e.x, 0), 1), min(max(e.y, 0), 1), min(max(e.z, 0), 1))
        }
    }
}
