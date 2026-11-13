//
//  FundamentalSector.swift
//  orix 0.15.0's `orix.vector.FundamentalSector` (the inverse pole figure's sector of a point group: its vertices, its
//  centre, its edges in the stereographic projection) and `Vector3d.in_fundamental_sector` (MTEX's
//  `project2FundamentalRegion`). GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE. Parity: `tools/parity/sem` bundle
//  `m3/ipf-color-keys`, vertices and centres within 1e-10, edges within 1e-9, projected directions within 1e-7.
//

import Foundation

package nonisolated struct FundamentalSector: Sendable {
    /// The point group's name, which picks `in_fundamental_sector`'s special cases.
    package let groupName: String?
    /// The bounding normals as orix stores them (rounded to 10 decimals, not normalised).
    package let normals: [SIMD3<Double>]
    /// The vertices: the pairwise cross products of the normals inside the sector, made unique and unit.
    package let vertices: [SIMD3<Double>]
    /// The centre (not normalised), nil for a sector without normals (point group 1). orix samples the sphere for a sector
    /// with four or more vertices and no stated centre; no point group of orix's table reaches that branch (23, m-3 and 432
    /// state theirs), so it is not ported.
    package let center: SIMD3<Double>?

    package init(_ group: PointGroup) {
        self.init(groupName: group.name, normals: group.fundamentalSectorNormals, statedCenter: group.fundamentalSectorCenter)
    }

    package init(groupName: String?, normals: [SIMD3<Double>], statedCenter: SIMD3<Double>?) {
        self.groupName = groupName
        self.normals = normals
        let vertices = FundamentalSector.vertices(of: normals)
        self.vertices = vertices
        self.center = FundamentalSector.center(normals: normals, vertices: vertices, stated: statedCenter)
    }

    /// `v <= sector`: inside or on a bounding plane (every dot product with a normal above −1e-9).
    package func contains(_ v: SIMD3<Double>) -> Bool {
        normals.allSatisfy { Vector3.dot($0, v) > -1e-9 }
    }

    /// `vertices`: for each normal i and each normal j, n_j × n_i, the ones in the sector, made unique (rounded to 10
    /// decimals, zeros dropped, first appearances kept) and unit.
    private static func vertices(of normals: [SIMD3<Double>]) -> [SIMD3<Double>] {
        guard !normals.isEmpty else { return [] }
        var u: [SIMD3<Double>] = []
        let sector = { (v: SIMD3<Double>) in normals.allSatisfy { Vector3.dot($0, v) > -1e-9 } }
        for ni in normals {
            for nj in normals {
                let c = Vector3.cross(nj, ni)
                if sector(c) { u.append(c) }
            }
        }
        return Vector3.unique(u).map(Vector3.unit)
    }

    /// `center` (MTEX's `sphericalRegion.center`): one normal is its own centre; with fewer than three vertices the mean of
    /// the normals each one is furthest from; with three the mean of the vertices; with more the centre orix states.
    private static func center(normals: [SIMD3<Double>], vertices: [SIMD3<Double>], stated: SIMD3<Double>?) -> SIMD3<Double>? {
        let v = Vector3.unique(vertices)
        let n = normals.count
        if n == 0 { return nil }
        if n < 2 { return normals[0] }
        if v.count < 3 {
            var sum = SIMD3<Double>(0, 0, 0)
            for i in 0..<n {
                var best = 0
                var bestAngle = -Double.infinity
                for j in 0..<n {
                    let a = Vector3.angle(normals[j], normals[i])
                    if a > bestAngle { best = j; bestAngle = a }
                }
                sum += normals[best]
            }
            return sum / Double(n)
        }
        if v.count < 4 {
            var sum = SIMD3<Double>(0, 0, 0)
            for x in v { sum += x }
            return sum / Double(v.count)
        }
        return stated
    }

    // MARK: - Edges

    /// The points per bounding great circle (orix's `_EDGE_STEPS`).
    package static let edgeSteps = 1000

    /// `edges`: each bounding great circle (1000 points) paired with a vertex in order, the circle's points in the sector
    /// with that vertex made unique and sorted by polar then azimuthal angle, all of them then ordered counter-clockwise
    /// around the centre in the stereographic projection starting with the point nearest [001]. A sector without
    /// vertices is its first normal's whole circle.
    package var edges: [SIMD3<Double>] {
        guard !normals.isEmpty else { return [] }
        let circles = normals.map { Vector3.circle(about: $0, steps: FundamentalSector.edgeSteps) }
        guard !vertices.isEmpty else { return circles.flatMap { $0 } }
        var edges: [SIMD3<Double>] = []
        for (ci, vi) in zip(circles, vertices) {
            let keep = Vector3.unique(ci.filter(contains) + [vi])
            let order = keep.indices.sorted { a, b in
                let pa = Vector3.polar(keep[a]), pb = Vector3.polar(keep[b])
                if pa != pb { return pa < pb }
                let aa = Vector3.azimuth(keep[a]), ab = Vector3.azimuth(keep[b])
                if aa != ab { return aa < ab }
                return a < b
            }
            edges.append(contentsOf: order.map { keep[$0] })
        }
        guard let center else { return edges }
        return FundamentalSector.orderAroundCenter(edges, center: center).map { edges[$0] }
    }

    /// `_order_to_sort_around_center` (pole −1): the vectors rotated so that the centre lands on [001], sorted by azimuth,
    /// rolled so that the one with the largest z comes first.
    private static func orderAroundCenter(_ v: [SIMD3<Double>], center: SIMD3<Double>) -> [Int] {
        let vz = Vector3.z
        let angle = Vector3.angle(vz, center)
        let rotation = Rotation.fromAxisAngle(Vector3.cross(vz, center), -angle)
        let azimuths = v.map { Vector3.azimuth(rotation * $0) }
        let order1 = v.indices.sorted { azimuths[$0] != azimuths[$1] ? azimuths[$0] < azimuths[$1] : $0 < $1 }
        var first = 0
        for k in order1.indices where Vector3.dot(v[order1[k]], vz) > Vector3.dot(v[order1[first]], vz) { first = k }
        return Array(order1[first...] + order1[..<first])
    }

    /// The extent of the sector in the stereographic projection (pole −1): the minimum and maximum x and y of its edges
    /// in the upper hemisphere, each rounded to 11 decimals, as orix's key image takes them.
    package var stereographicExtent: (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
        let xy = StereographicProjection(pole: -1).vectorToXY(edges)
        guard !xy.isEmpty else { return nil }
        let xs = xy.map { Rotation.round($0.x, decimals: 11) }, ys = xy.map { Rotation.round($0.y, decimals: 11) }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        return (x0...x1, y0...y1)
    }
}

extension PointGroup {
    /// `fundamental_sector` as a `FundamentalSector`.
    package var fundamentalSector: FundamentalSector { FundamentalSector(self) }

    /// `Vector3d.in_fundamental_sector`: each vector moved by the symmetry element whose image of the sector centre is
    /// closest to it (dot products rounded to 12 decimals, the first of equals), unless it is already in the sector. For
    /// 321, 312, 32 and −4 a vector below the equator is first moved by the last element and only the first three elements
    /// are searched; for −3 by the fourth element, the same three searched.
    package func projectToFundamentalSector(_ vectors: [SIMD3<Double>]) -> [SIMD3<Double>] {
        projectToFundamentalSector(vectors, sector: fundamentalSector)
    }

    /// The same with the sector already built (a colour key builds it once).
    package func projectToFundamentalSector(_ vectors: [SIMD3<Double>], sector fs: FundamentalSector) -> [SIMD3<Double>] {
        guard let center = fs.center else { return vectors }
        var flip: Rotation?
        var searched = elements
        switch name ?? "" {
        case "321", "312", "32", "-4":
            flip = elements.last
            searched = Array(elements.prefix(3))
        case "-3":
            flip = elements[3]
            searched = Array(elements.prefix(3))
        default:
            break
        }
        let rotatedCenters = searched.map { $0 * center }
        let inverses = searched.map(\.inverse)
        return vectors.map { v0 in
            var v = v0
            if let flip, v.z < 0 { v = flip * v }
            if fs.contains(v) { return v }
            var best = 0
            var bestCloseness = -Double.infinity
            for (k, c) in rotatedCenters.enumerated() {
                let closeness = Rotation.round(Vector3.dot(v, c), decimals: 12)
                if closeness > bestCloseness { best = k; bestCloseness = closeness }
            }
            return inverses[best] * v
        }
    }
}
