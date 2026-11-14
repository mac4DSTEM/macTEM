//
//  PointGroup.swift
//  orix 0.15.0's `orix.quaternion.symmetry`: the 32 crystallographic point groups as orix builds them (the 38 objects of its
//  `_groups` table, with the axis settings 211/121/112, m11/1m1/11m and 321/312, plus the aliases 2, m and 32), each from orix's
//  own generator lists through `Symmetry.from_generators`, in orix's element order; subgroups, the proper subgroup, the Laue
//  group (one of 11) and its proper subgroup, the crystal system, the Euler fundamental region, the fundamental sector of
//  the inverse pole figure and the fundamental zone. GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE.
//
//  One deviation, decision D-SEM in docs/decisions.md: `axisOrders` groups rotation axes by their components rounded to
//  10 decimals where orix's `get_axis_orders` compares them exactly (`np.unique`); a 1-ulp difference in a product would
//  otherwise split a four-fold axis into two. Parity: `tools/parity/sem` bundle `m3/point-groups`, elements within 1e-10.
//

import Foundation

package nonisolated struct PointGroup: Sendable, CustomStringConvertible {
    /// orix's name ("m-3m", "6/mmm", "321", ...); nil for a group orix leaves unnamed (the Laue group of "m").
    package let name: String?
    /// The elements in orix's order; the first is the identity.
    package let elements: [Rotation]
    /// orix's `_tuples`: the set of rounded differentiators, the identity of the group as a set.
    package let tuples: Set<Rotation.Differentiators>

    package init(name: String?, elements: [Rotation]) {
        self.name = name
        self.elements = elements
        self.tuples = Set(elements.map(\.differentiators))
    }

    /// A copy under another name (orix's `C2 = Symmetry(C2z); C2.name = "2"`).
    package func renamed(_ newName: String?) -> PointGroup { PointGroup(name: newName, elements: elements) }

    package var description: String { "PointGroup \(name ?? "unnamed") (\(order))" }

    package var order: Int { elements.count }

    /// `is_proper`: no element is improper.
    package var isProper: Bool { !elements.contains { $0.improper } }

    /// `contains_inversion`.
    package var containsInversion: Bool { PointGroup.ci.tuples.isSubset(of: tuples) }

    /// orix's `Symmetry.__eq__`: the same number of elements, components equal within numpy's `allclose` defaults, the same
    /// improper flags, in order.
    package func hasSameElements(as other: PointGroup) -> Bool {
        guard order == other.order else { return false }
        for (x, y) in zip(elements, other.elements) {
            guard x.improper == y.improper else { return false }
            for i in 0..<4 where !(abs(x.q[i] - y.q[i]) <= 1e-8 + 1e-5 * abs(y.q[i])) { return false }
        }
        return true
    }

    // MARK: - Building groups

    /// `Symmetry.from_generators`: starting from the identity, the outer product with each generator (made unique), then
    /// with itself until the order stops growing (or reaches 48).
    package static func fromGenerators(_ generators: [PointGroup], name: String? = nil) -> PointGroup {
        var g = [Rotation.identity]
        for gen in generators {
            let copy = gen.elements.map { Rotation($0.q, improper: $0.improper) }
            g = Rotation.unique(Rotation.outerFlattened(g, copy)).rotations
        }
        var size = 1
        var sizeNew = g.count
        while sizeNew != size, sizeNew < 48 {
            size = sizeNew
            g = Rotation.unique(Rotation.outerFlattened(g, g)).rotations
            sizeNew = g.count
        }
        return PointGroup(name: name, elements: g)
    }

    /// A group written element by element (`Symmetry([...])`, each quaternion normalised).
    private static func listed(_ name: String?, _ qs: [SIMD4<Double>], improper: [Bool]? = nil) -> PointGroup {
        let flags = improper ?? Array(repeating: false, count: qs.count)
        return PointGroup(name: name, elements: zip(qs, flags).map { Rotation($0.0, improper: $0.1) })
    }

    private static let r2 = 0.5.squareRoot(), r3 = 0.75.squareRoot()

    // The table, generator for generator as orix.quaternion.symmetry writes it.
    package static let c1 = listed("1", [SIMD4(1, 0, 0, 0)])
    package static let ci = listed("-1", [SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0)], improper: [false, true])
    private static let mirrorXY = listed(nil, [SIMD4(1, 0, 0, 0), SIMD4(0, r3, -r3, 0)], improper: [false, true])
    private static let cubic = listed(nil, [SIMD4(1, 0, 0, 0), SIMD4(0.5, 0.5, 0.5, 0.5)])
    package static let c2x = listed("211", [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0)])
    package static let c2y = listed("121", [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0)])
    package static let c2z = listed("112", [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 0, 1)])
    package static let c2 = c2z.renamed("2")
    package static let csx = listed("m11", [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0)], improper: [false, true])
    package static let csy = listed("1m1", [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0)], improper: [false, true])
    package static let csz = listed("11m", [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 0, 1)], improper: [false, true])
    package static let cs = csz.renamed("m")
    package static let c2h = fromGenerators([c2, cs], name: "2/m")
    package static let d2 = fromGenerators([c2z, c2x, c2y], name: "222")
    package static let c2v = fromGenerators([c2z, csx], name: "mm2")
    package static let d2h = fromGenerators([csz, csx, csy], name: "mmm")
    private static let c4z = [SIMD4<Double>(1, 0, 0, 0), SIMD4(r2, 0, 0, r2), SIMD4(0, 0, 0, 1), SIMD4(-r2, 0, 0, r2)]
    package static let c4 = listed("4", c4z)
    package static let s4 = listed("-4", c4z, improper: [false, true, false, true])
    package static let c4h = fromGenerators([c4, cs], name: "4/m")
    package static let d4 = fromGenerators([c4, c2x, c2y], name: "422")
    package static let c4v = fromGenerators([c4, csx], name: "4mm")
    package static let d2d = fromGenerators([d2, mirrorXY], name: "-42m")
    package static let d4h = fromGenerators([c4h, csx, csy], name: "4/mmm")
    package static let c3 = listed("3", [SIMD4(1, 0, 0, 0), SIMD4(0.5, 0, 0, r3), SIMD4(-0.5, 0, 0, r3)])
    package static let s6 = fromGenerators([c3, ci], name: "-3")
    package static let d3x = fromGenerators([c3, c2x], name: "321")
    package static let d3y = fromGenerators([c3, c2y], name: "312")
    package static let d3 = d3x.renamed("32")
    package static let c3v = fromGenerators([c3, csx], name: "3m")
    package static let d3d = fromGenerators([s6, csx], name: "-3m")
    package static let c6 = fromGenerators([c3, c2], name: "6")
    package static let c3h = fromGenerators([c3, cs], name: "-6")
    package static let c6h = fromGenerators([c6, cs], name: "6/m")
    package static let d6 = fromGenerators([c6, c2x, c2y], name: "622")
    package static let c6v = fromGenerators([c6, csx], name: "6mm")
    package static let d3h = fromGenerators([c3, c2y, csz], name: "-6m2")
    package static let d6h = fromGenerators([d6, csz], name: "6/mmm")
    package static let t = fromGenerators([c2, cubic], name: "23")
    package static let th = fromGenerators([t, ci], name: "m-3")
    package static let o = fromGenerators([c4, cubic, c2x], name: "432")
    package static let td = fromGenerators([t, mirrorXY], name: "-43m")
    package static let oh = fromGenerators([o, ci], name: "m-3m")

    /// orix's `_groups`, in its order: the table `subgroups` searches.
    package static let groups: [PointGroup] = [c1, ci, c2x, c2y, c2z, csx, csy, csz, c2h, d2, c2v, d2h, c4, s4, c4h, d4, c4v, d2d, d4h,
                                               c3, s6, d3x, d3y, d3, c3v, d3d, c6, c3h, c6h, d6, c6v, d3h, d6h, t, th, o, td, oh]

    /// The groups and the aliases 2, m and 32, by orix name.
    package static func named(_ name: String) -> PointGroup? {
        (groups + [c2, cs]).first { $0.name == name }
    }

    // MARK: - Subgroups and Laue groups

    /// `subgroups`: every group of the table whose elements are all elements of this one.
    package var subgroups: [PointGroup] { PointGroup.groups.filter { $0.tuples.isSubset(of: tuples) } }

    /// `proper_subgroups`.
    package var properSubgroups: [PointGroup] { subgroups.filter(\.isProper) }

    /// `proper_subgroup`: the largest proper subgroup (the last of the largest order, as orix's stable sort leaves it).
    package var properSubgroup: PointGroup {
        let proper = properSubgroups
        guard var best = proper.first else { return PointGroup(name: nil, elements: elements) }
        for g in proper.dropFirst() where g.order >= best.order { best = g }
        return best
    }

    /// `laue`: the group with inversion added, under orix's Laue name.
    package var laue: PointGroup {
        PointGroup.fromGenerators([self, PointGroup.ci], name: PointGroup.laueName(name))
    }

    /// `laue_proper_subgroup`.
    package var laueProperSubgroup: PointGroup { laue.properSubgroup }

    /// The Laue class of a point group by name, for pairing and file headers: orix's `_get_laue_group_name`, plus "m" (orix's `Cs`,
    /// the 11m mirror under its short name), which orix's list leaves out although `Cs.laue` is 2/m by its elements (macEM#615).
    package static func laueClassName(_ name: String?) -> String? {
        name == "m" ? "2/m" : laueName(name)
    }

    /// `_get_laue_group_name`.
    package static func laueName(_ name: String?) -> String? {
        switch name ?? "" {
        case "1", "-1": "-1"
        case "2", "211", "121", "112", "m11", "1m1", "11m", "2/m": "2/m"
        case "222", "mm2", "mmm": "mmm"
        case "4", "-4", "4/m": "4/m"
        case "422", "4mm", "-42m", "4/mmm": "4/mmm"
        case "3", "-3": "-3"
        case "321", "312", "32", "3m", "-3m": "-3m"
        case "6", "-6", "6/m": "6/m"
        case "6mm", "-6m2", "6/mmm", "622": "6/mmm"
        case "23", "m-3": "m-3"
        case "432", "-43m", "m-3m": "m-3m"
        default: nil
        }
    }

    /// `__and__`: the group generated by the table's groups that are subgroups of both.
    package static func & (lhs: PointGroup, rhs: PointGroup) -> PointGroup {
        let generators = lhs.subgroups.filter { $0.tuples.isSubset(of: rhs.tuples) }
        return fromGenerators(generators)
    }

    /// `_get_unique_symmetry_elements(sym1, sym2)`: `sym1` when the two are equal, else their outer product made unique.
    package static func uniqueElements(_ s1: PointGroup, _ s2: PointGroup) -> [Rotation] {
        if s1.hasSameElements(as: s2) { return s1.elements }
        return Rotation.unique(Rotation.outerFlattened(s1.elements, s2.elements)).rotations
    }

    // MARK: - Tables

    /// `system`.
    package var system: String? {
        switch name ?? "" {
        case "1", "-1": "triclinic"
        case "211", "121", "112", "2", "m11", "1m1", "11m", "m", "2/m": "monoclinic"
        case "222", "mm2", "mmm": "orthorhombic"
        case "4", "-4", "4/m", "422", "4mm", "-42m", "4/mmm": "tetragonal"
        case "3", "-3", "321", "312", "32", "3m", "-3m": "trigonal"
        case "6", "-6", "6/m", "622", "6mm", "-6m2", "6/mmm": "hexagonal"
        case "23", "m-3", "432", "-43m", "m-3m": "cubic"
        default: nil
        }
    }

    /// `euler_fundamental_region`: the maximal (φ1, Φ, φ2) in degrees of the proper subgroup.
    package var eulerFundamentalRegion: [Int] {
        let angles: [String: [Int]] = ["1": [360, 180, 360], "211": [360, 90, 360], "121": [360, 90, 360], "112": [360, 180, 180],
                                       "222": [360, 90, 180], "4": [360, 180, 90], "422": [360, 90, 90], "3": [360, 180, 120],
                                       "312": [360, 90, 120], "32": [360, 90, 120], "6": [360, 180, 60], "622": [360, 90, 60],
                                       "23": [360, 90, 180], "432": [360, 90, 90]]
        return properSubgroup.name.flatMap { angles[$0] } ?? [360, 180, 360]   // angles["1"], the triclinic sector
    }

    /// `_primary_axis_order`.
    package var primaryAxisOrder: Int? {
        switch properSubgroup.name ?? "" {
        case "1", "211", "121": 1
        case "112", "222", "23": 2
        case "3", "312", "32": 3
        case "4", "422", "432": 4
        case "6", "622": 6
        default: nil
        }
    }

    // MARK: - Axes

    /// `get_axis_orders` of a set of rotations: the axes of the non-identity elements, each with its order (count + 1),
    /// in numpy's sorted order of the axes. Axes are grouped by their components rounded to 10 decimals (orix compares
    /// them exactly; see the file header).
    package static func axisOrders(_ rotations: [Rotation]) -> [(axis: SIMD3<Double>, order: Int)] {
        var counts: [Rotation.Differentiators: (axis: SIMD3<Double>, count: Int)] = [:]
        for r in rotations where r.angle > 0 {
            let a = r.axis
            let k = Vector3.key(a)
            if let e = counts[k] { counts[k] = (e.axis, e.count + 1) } else { counts[k] = (a, 1) }
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.value.axis, $0.value.count + 1) }
    }

    /// `get_highest_order_axis`: the axes of the highest order (z and nil when there is no axis).
    package static func highestOrderAxes(_ rotations: [Rotation]) -> (axes: [SIMD3<Double>], order: Int?) {
        let orders = axisOrders(rotations)
        guard let highest = orders.map(\.order).max() else { return ([Vector3.z], nil) }
        return (orders.filter { $0.order == highest }.map(\.axis), highest)
    }

    /// `diads`: the axes of order 2.
    package static func diads(_ rotations: [Rotation]) -> [SIMD3<Double>] {
        axisOrders(rotations).filter { $0.order == 2 }.map(\.axis)
    }

    // MARK: - Fundamental sector (inverse pole figure)

    /// `fundamental_sector`: the normals of the great circles bounding the inverse pole figure's sector, as orix stores them
    /// (rounded to 10 decimals, not normalised).
    package var fundamentalSectorNormals: [SIMD3<Double>] {
        let vz = Vector3.z, vx = Vector3.x, vy = Vector3.y
        var n: [SIMD3<Double>] = []
        if elements.contains(where: { Vector3.angle(vz, $0 * vz) > Double.pi / 2 }) { n = [vz] }
        if order > 1 + n.count {
            let angle = 2 * Double.pi * Double(1 + n.count) / Double(order)
            n.append(Vector3.fromPolar(azimuth: Double.pi / 2, polar: Double.pi / 2))
            n.append(Vector3.fromPolar(azimuth: angle - Double.pi / 2, polar: Double.pi / 2))
        }
        switch name ?? "" {
        case "-1":
            n = [vz]
        case "m11", "1m1", "11m":
            var idx = 0
            for (i, e) in elements.enumerated() where e.angle < elements[idx].angle { idx = i }
            n = [name == "m11" ? -elements[idx].axis : elements[idx].axis]
        case "mm2":
            n = elements.filter(\.improper).map(\.axis).map { Vector3.angle($0, -vy) < Double.pi / 4 ? -$0 : $0 }
        case "321", "312", "3m", "-3m", "6m2":   // "6m2" as orix spells it (so "-6m2" is not rotated there either)
            n = n.map { Vector3.rotate($0, angle: -Double.pi / 6) }
        case "-42m":
            n = n.map { Vector3.rotate($0, angle: -Double.pi / 4) }
        case "23":
            n = [SIMD3(1, 1, 0), SIMD3(1, -1, 0), SIMD3(0, -1, 1), SIMD3(0, 1, 1)]
        case "m-3", "432":
            n = [vx, SIMD3(0, -1, 1), SIMD3(-1, 0, 1), vy, vz]
        case "-43m":
            n = [SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 0, 1)]
        case "m-3m":
            n = [SIMD3(1, -1, 0), SIMD3(-1, 0, 1), vy]
        default:
            break
        }
        return Vector3.unique(n)
    }

    /// The sector centre orix states for 23, m-3 and 432 (`FundamentalSector._center`); nil for the others.
    package var fundamentalSectorCenter: SIMD3<Double>? {
        switch name ?? "" {
        case "23": SIMD3(0.707558, -0.000403, 0.706655)
        case "m-3", "432": SIMD3(0.349928, 0.348069, 0.869711)
        default: nil
        }
    }

    // MARK: - Fundamental zone (orientation space)

    /// `fundamental_zone`: the normals of the spherical region that bounds the rotation axes of the zone, empty for a group
    /// with no axis of order 6 or less.
    package func fundamentalZoneNormals() -> [SIMD3<Double>] {
        let symmetry = (elements + elements.map(\.antipode)).filter { $0.angle > 0 }
        let (axes, orderOrNil) = PointGroup.highestOrderAxes(symmetry)
        guard let order = orderOrNil, order <= 6 else { return [] }
        guard let axis = Vector3.nearest(to: Vector3.z, among: axes, inclusive: true) else { return [] }
        var r = Rotation.fromAxisAngle(axis, 2 * Double.pi / Double(order))
        let diads = PointGroup.diads(symmetry)
        let nearestDiad = Vector3.nearest(to: axis, among: diads, inclusive: false) ?? Vector3.perpendicular(axis)
        var n1 = Vector3.unit(Vector3.cross(axis, nearestDiad))
        var n2 = -(r * n1)
        let nextDiad = r * nearestDiad
        let n = [n1, n2]
        let sr = Vector3.unique(n)
        let inside = symmetry.filter { e in sr.allSatisfy { Vector3.dot($0, e.axis) > 1e-9 } }
        if inside.isEmpty { return sr }
        let (axes2, order2OrNil) = PointGroup.highestOrderAxes(inside)
        guard let order2 = order2OrNil, let axis2 = Vector3.nearest(to: axis, among: axes2, inclusive: false) else { return sr }
        r = Rotation.fromAxisAngle(axis2, 2 * Double.pi / Double(order2))
        n1 = Vector3.unit(Vector3.cross(axis2, nextDiad))
        n2 = -(r * n1)
        return Vector3.unique(n + [n1, n2])
    }
}
