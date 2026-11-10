//
//  SlipSystems.swift
//  DefDAP 1.3.1's slip systems (defdap.crystal.SlipSystem, Phase; defdap.crystal_utils create_l_matrix, create_q_matrix,
//  convert_idc, pos_idc, idc_to_string) and its six slip-system files (defdap/slip_systems/*.txt, carried verbatim below).
//  Apache-2.0 (DefDAP, Copyright 2025 Mechanics of Microstructures Group at The University of Manchester), see NOTICE.
//
//  A file holds a comment line, a line of trace colours, then one slip system per line: plane normal then slip direction,
//  three Miller indices each for cubic crystals, four Miller-Bravais indices for hexagonal ones. Cubic vectors are the indices
//  normalised; hexagonal ones go through DefDAP's orthonormalisation in the Oxford (HKL) convention, x ∥ [10-10] and
//  y ∥ [-12-10] (`defaults['crystal_ortho_conv'] = 'hkl'`): planes by the reciprocal-lattice matrix Q, directions by the
//  lattice matrix L of a = b = 1, c = c/a, γ = 120°. Systems are grouped by slip plane in file order (`group_by='plane'`, the
//  default); the colours pair with the groups by position, as DefDAP's `zip` does, so a file with fewer colours than groups
//  (`cubic_bcc` has 12 for 30) leaves the last groups without one. Parity: `m5/slip-ti` and `m5/slip-sdss`, unit vectors
//  within 1e-12 (docs/parity.md).
//

import Foundation

/// One slip system: its indices as the file writes them and its unit plane normal and slip direction in the crystal's
/// orthonormal frame.
package nonisolated struct SlipSystem: Sendable, Equatable {
    package let planeIndices: [Int]
    package let directionIndices: [Int]
    package let plane: SIMD3<Double>
    package let direction: SIMD3<Double>

    /// `SlipSystem.slip_plane_label`, e.g. (1 1̅ 1) written without spaces as DefDAP does: (11̅1).
    package var planeLabel: String { "(" + SlipSystem.indexString(planeIndices) + ")" }
    /// `SlipSystem.slip_dir_label`, e.g. [01̅1].
    package var directionLabel: String { "[" + SlipSystem.indexString(directionIndices) + "]" }

    /// `idc_to_string` in its unicode form: a negative index as its magnitude with a combining overline.
    package static func indexString(_ idc: [Int]) -> String {
        idc.map { $0 < 0 ? String(-$0) + "\u{0305}" : String($0) }.joined()
    }

    /// Whether the slip direction lies in the slip plane (|n·d| below 1e-9). Twelve of the 24 {123}<111> rows of DefDAP's
    /// `cubic_bcc` file are not: their direction leaves the plane, so they are no slip system (decision in docs/decisions.md).
    package var isConsistent: Bool { abs(Vector3.dot(plane, direction)) < 1e-9 }

    /// `pos_idc`: the indices with the sign that makes the first non-zero one positive.
    package static func positive(_ idc: [Int]) -> [Int] {
        for i in idc where i != 0 { return i > 0 ? idc : idc.map { -$0 } }
        return idc
    }
}

/// The crystal structure a phase's slip systems and symmetries belong to, with the hexagonal c/a.
package nonisolated enum SlipCrystal: Sendable, Equatable {
    case cubic
    case hexagonal(cOverA: Double)

    package var structure: DefDAPCrystalStructure {
        switch self {
        case .cubic: return .cubic
        case .hexagonal: return .hexagonal
        }
    }
}

/// DefDAP's lattice matrices (`create_l_matrix`, `create_q_matrix`), row-major 3 x 3.
package nonisolated enum DefDAPLattice {
    /// `create_l_matrix(a, b, c, alpha, beta, gamma, 'hkl')`: Randle and Engler's L, with the Oxford swap of the first two
    /// rows' first two entries and entries below 1e-10 set to 0.
    package static func lMatrix(a: Double, b: Double, c: Double, alpha: Double, beta: Double, gamma: Double) -> [Double] {
        let ca = cos(alpha), cb = cos(beta), cg = cos(gamma), sg = sin(gamma)
        var l = [Double](repeating: 0, count: 9)
        l[0] = a
        l[1] = b * cg
        l[2] = c * cb
        l[4] = b * sg
        l[5] = c * (ca - cb * cg) / sg
        l[8] = c * (1 + 2 * ca * cb * cg - ca * ca - cb * cb - cg * cg).squareRoot() / sg
        // OI/HKL: swap 00 with 11 and 01 with 10.
        let t1 = l[0], t2 = l[3]
        l[0] = l[4]
        l[3] = l[1]
        l[4] = t1
        l[1] = t2
        return l.map { abs($0) < 1e-10 ? 0 : $0 }
    }

    /// `create_q_matrix`: the reciprocal basis a*, b*, c* of L's columns, as columns.
    package static func qMatrix(_ l: [Double]) -> [Double] {
        let a = SIMD3(l[0], l[3], l[6]), b = SIMD3(l[1], l[4], l[7]), c = SIMD3(l[2], l[5], l[8])
        let bc = Vector3.cross(b, c), ca = Vector3.cross(c, a), ab = Vector3.cross(a, b)
        let volume = abs(Vector3.dot(a, bc))
        let aStar = bc / volume, bStar = ca / volume, cStar = ab / volume
        return [aStar.x, bStar.x, cStar.x, aStar.y, bStar.y, cStar.y, aStar.z, bStar.z, cStar.z]
    }

    package static func apply(_ m: [Double], _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z, m[6] * v.x + m[7] * v.y + m[8] * v.z)
    }

    /// L and Q of DefDAP's hexagonal slip systems: a = b = 1, c = c/a, α = β = 90°, γ = 120°.
    package static func hexagonal(cOverA: Double) -> (l: [Double], q: [Double]) {
        let l = lMatrix(a: 1, b: 1, c: cOverA, alpha: Double.pi / 2, beta: Double.pi / 2, gamma: Double.pi * 2 / 3)
        return (l, qMatrix(l))
    }
}

/// A phase's slip systems grouped by plane, with the trace colours of the file.
package nonisolated struct SlipSystemSet: Sendable, Equatable {
    package let groups: [[SlipSystem]]
    package let traceColours: [String]

    /// Every system in group order (the order of DefDAP's per-grain Schmid-factor lists, flattened).
    package var flattened: [SlipSystem] { groups.flatMap { $0 } }

    /// The systems whose direction lies in their plane, groups left empty dropped and each kept group with its colour. Equal to
    /// the set for every DefDAP file but `cubic_bcc`, which loses its twelve inconsistent {123} rows; the app analyses this set,
    /// the parity tests the file as DefDAP reads it.
    package var consistent: SlipSystemSet {
        var kept: [[SlipSystem]] = []
        var colours: [String] = []
        for (i, group) in groups.enumerated() {
            let g = group.filter(\.isConsistent)
            guard !g.isEmpty else { continue }
            kept.append(g)
            if i < traceColours.count { colours.append(traceColours[i]) }
        }
        return SlipSystemSet(groups: kept, traceColours: colours)
    }

    package enum LoadError: Error, Equatable, Sendable {
        /// DefDAP's `IOError("Slip system file not valid")`: a row without 6 (cubic) or 8 (hexagonal) integers.
        case notValid(line: Int)
    }

    /// `SlipSystem.load(name, crystal_structure, c_over_a)`: one of DefDAP's files.
    package static func load(_ file: SlipSystemFile, crystal: SlipCrystal) throws -> SlipSystemSet {
        try parse(file.text, crystal: crystal)
    }

    /// `SlipSystem.load` on a file's text: skip the comment, read the colours, one system per non-empty line, group by plane.
    package static func parse(_ text: String, crystal: SlipCrystal) throws -> SlipSystemSet {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let colours = lines.count > 1
            ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            : []
        let size: Int
        let hex: (l: [Double], q: [Double])?
        switch crystal {
        case .cubic:
            size = 3
            hex = nil
        case .hexagonal(let cOverA):
            size = 4
            hex = DefDAPLattice.hexagonal(cOverA: cOverA)
        }
        var systems: [SlipSystem] = []
        for (n, line) in lines.enumerated().dropFirst(2) {
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.allSatisfy(\.isEmpty) { continue }
            let ints = fields.compactMap { Int($0) }
            guard ints.count == fields.count, ints.count == 2 * size else { throw LoadError.notValid(line: n + 1) }
            let p = Array(ints[0..<size]), d = Array(ints[size..<(2 * size)])
            systems.append(makeSystem(plane: p, direction: d, hex: hex))
        }
        return SlipSystemSet(groups: groupByPlane(systems), traceColours: colours)
    }

    /// `SlipSystem.__init__`: the unit vectors in the orthonormal crystal frame.
    static func makeSystem(plane p: [Int], direction d: [Int], hex: (l: [Double], q: [Double])?) -> SlipSystem {
        let planeVector: SIMD3<Double>, directionVector: SIMD3<Double>
        if let hex {
            // convert_idc('mb'): plane (h k i l) -> (h k l); direction [u v t w] -> [u - t, v - t, w].
            let pm = SIMD3(Double(p[0]), Double(p[1]), Double(p[3]))
            let dm = SIMD3(Double(d[0] - d[2]), Double(d[1] - d[2]), Double(d[3]))
            planeVector = DefDAPLattice.apply(hex.q, pm)
            directionVector = DefDAPLattice.apply(hex.l, dm)
        } else {
            planeVector = SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
            directionVector = SIMD3(Double(d[0]), Double(d[1]), Double(d[2]))
        }
        return SlipSystem(planeIndices: p, directionIndices: d,
                          plane: planeVector / Vector3.dot(planeVector, planeVector).squareRoot(),
                          direction: directionVector / Vector3.dot(directionVector, directionVector).squareRoot())
    }

    /// `SlipSystem.group(slip_systems, 'plane')`: a system joins the first group whose plane has the same positive indices.
    static func groupByPlane(_ systems: [SlipSystem]) -> [[SlipSystem]] {
        var groups: [[SlipSystem]] = []
        var keys: [[Int]] = []
        for s in systems {
            let k = SlipSystem.positive(s.planeIndices)
            if let i = keys.firstIndex(of: k) {
                groups[i].append(s)
            } else {
                keys.append(k)
                groups.append([s])
            }
        }
        return groups
    }
}

/// DefDAP's `Phase`: a name, its Laue group (9 hexagonal, 11 cubic), space group and lattice (Å, radians), and the slip
/// systems DefDAP picks for it (`defaults['slip_system_file']`: hexagonal → `hexagonal_withca`, space group 225 →
/// `cubic_fcc`, 229 → `cubic_bcc`, any other cubic → none).
package nonisolated struct SlipPhase: Sendable, Equatable {
    package let name: String
    package let laueGroup: Int
    package let spaceGroup: Int?
    /// a, b, c in Å; α, β, γ in radians.
    package let lattice: [Double]
    package let crystal: SlipCrystal
    package let slipSystemFile: SlipSystemFile?
    package let slipSystems: SlipSystemSet?

    package enum Error: Swift.Error, Equatable, Sendable {
        /// `ValueError("Unknown Laue group key")`.
        case unknownLaueGroup(Int)
    }

    package init(name: String, laueGroup: Int, spaceGroup: Int?, lattice: [Double]) throws {
        self.name = name
        self.laueGroup = laueGroup
        self.spaceGroup = spaceGroup
        self.lattice = lattice
        let crystal: SlipCrystal
        let file: SlipSystemFile?
        switch laueGroup {
        case 9:
            crystal = .hexagonal(cOverA: lattice[2] / lattice[0])
            file = .hexagonalWithCA
        case 11:
            crystal = .cubic
            switch spaceGroup {
            case 225: file = .cubicFCC
            case 229: file = .cubicBCC
            default: file = nil
            }
        default:
            throw Error.unknownLaueGroup(laueGroup)
        }
        self.crystal = crystal
        slipSystemFile = file
        if let file {
            slipSystems = try SlipSystemSet.load(file, crystal: crystal)
        } else {
            slipSystems = nil
        }
    }

    /// `Phase.c_over_a`: c / a for a hexagonal phase, nil otherwise.
    package var cOverA: Double? {
        if case .hexagonal(let r) = crystal { return r }
        return nil
    }
}

/// DefDAP's slip-system files (defdap/slip_systems), by DefDAP's name.
package nonisolated enum SlipSystemFile: String, Sendable, CaseIterable {
    case cubicFCC = "cubic_fcc"
    case cubicBCC = "cubic_bcc"
    case cubicBCC110Only = "cubic_bcc_110only"
    case cubicFCCDamask = "cubic_fcc_damask"
    case hexagonalWithCA = "hexagonal_withca"
    case hexagonalNoCA = "hexagonal_noca"

    /// The crystal the file's indices are written for (three or four indices per vector).
    package var isHexagonal: Bool { self == .hexagonalWithCA || self == .hexagonalNoCA }

    package var text: String {
        switch self {
        case .cubicFCC: return Self.cubicFCCText
        case .cubicBCC: return Self.cubicBCCText
        case .cubicBCC110Only: return Self.cubicBCC110OnlyText
        case .cubicFCCDamask: return Self.cubicFCCDamaskText
        case .hexagonalWithCA: return Self.hexagonalWithCAText
        case .hexagonalNoCA: return Self.hexagonalNoCAText
        }
    }

    /// `cubic_fcc.txt`, verbatim (tabs written as \t).
    private static let cubicFCCText = """
        # Plane normal then slip direction
        blue,green,red,white
        1\t1\t1\t0\t1\t-1
        1\t1\t1\t-1\t0\t1
        1\t1\t1\t1\t-1\t0
        1\t1\t-1\t0\t1\t1
        1\t1\t-1\t-1\t0\t-1
        1\t1\t-1\t1\t-1\t0
        -1\t1\t1\t0\t1\t-1
        -1\t1\t1\t1\t0\t1
        -1\t1\t1\t-1\t-1\t0
        1\t-1\t1\t0\t-1\t-1
        1\t-1\t1\t-1\t0\t1
        1\t-1\t1\t1\t1\t0
        """

    /// `cubic_bcc.txt`, verbatim (tabs written as \t).
    private static let cubicBCCText = """
        # Plane normal then slip direction
        green,green,green,green,red,red,red,red,blue,blue,blue,blue
        0\t1\t-1\t1\t1\t1
        -1\t0\t1\t1\t1\t1
        1\t-1\t0\t1\t1\t1
        0\t1\t1\t1\t1\t-1
        -1\t0\t-1\t1\t1\t-1
        1\t-1\t0\t1\t1\t-1
        0\t1\t-1\t-1\t1\t1
        1\t0\t1\t-1\t1\t1
        -1\t-1\t0\t-1\t1\t1
        0\t-1\t-1\t1\t-1\t1
        -1\t0\t1\t1\t-1\t1
        1\t1\t0\t1\t-1\t1
        -2\t1\t1\t1\t1\t1
        1\t-2\t1\t1\t1\t1
        1\t1\t-2\t1\t1\t1
        2\t-1\t1\t-1\t-1\t1
        -1\t2\t1\t-1\t-1\t1
        1\t1\t2\t-1\t-1\t1
        2\t1\t-1\t1\t-1\t1
        1\t2\t1\t1\t-1\t1
        -1\t1\t2\t1\t-1\t1
        2\t1\t1\t-1\t1\t1
        1\t2\t-1\t-1\t1\t1
        1\t-1\t2\t-1\t1\t1
        1\t2\t3\t1\t1\t-1
        2\t1\t3\t1\t1\t-1
        3\t2\t1\t1\t1\t-1
        2\t3\t1\t1\t1\t-1
        -1\t3\t2\t1\t1\t-1
        3\t-1\t2\t1\t1\t-1
        1\t3\t2\t1\t-1\t1
        2\t3\t1\t1\t-1\t1
        3\t1\t2\t1\t-1\t1
        2\t1\t3\t1\t-1\t1
        -1\t2\t3\t1\t-1\t1
        3\t2\t-1\t1\t-1\t1
        3\t1\t2\t-1\t1\t1
        3\t2\t1\t-1\t1\t1
        1 \t2 \t3\t-1\t1\t1
        1\t3\t2\t-1\t1\t1
        2\t-1\t3\t-1\t1\t1
        2\t3\t-1\t-1\t1\t1
        1\t2\t3\t1\t1\t1
        1\t3\t2\t1\t1\t1
        3\t1\t2\t1\t1\t1
        2\t1\t3\t1\t1 \t1
        2\t3\t1 \t1\t1\t1
        3\t1\t2\t1\t1\t1
        """

    /// `cubic_bcc_110only.txt`, verbatim (tabs written as \t).
    private static let cubicBCC110OnlyText = """
        # Plane normal then slip direction
        green,green,green,green
        0\t1\t-1\t1\t1\t1
        -1\t0\t1\t1\t1\t1
        1\t-1\t0\t1\t1\t1
        0\t1\t1\t1\t1\t-1
        -1\t0\t-1\t1\t1\t-1
        1\t-1\t0\t1\t1\t-1
        0\t1\t-1\t-1\t1\t1
        1\t0\t1\t-1\t1\t1
        -1\t-1\t0\t-1\t1\t1
        0\t-1\t-1\t1\t-1\t1
        -1\t0\t1\t1\t-1\t1
        1\t1\t0\t1\t-1\t1
        """

    /// `cubic_fcc_damask.txt`, verbatim (tabs written as \t).
    private static let cubicFCCDamaskText = """
        # Plane normal then slip direction
        blue,green,red,black
         1\t 1\t 1\t 0\t 1\t-1
         1\t 1\t 1\t-1\t 0\t 1
         1\t 1\t 1\t 1\t-1\t 0
        -1\t-1\t 1\t 0\t-1\t-1
        -1\t-1\t 1\t 1\t 0\t 1
        -1\t-1\t 1\t-1\t 1\t 0
         1\t-1\t-1\t 0\t-1\t 1
         1\t-1\t-1\t-1\t 0\t-1
         1\t-1\t-1\t 1\t 1\t 0
        -1\t 1\t-1\t 0\t 1\t 1
        -1\t 1\t-1\t 1\t 0\t-1
        -1\t 1\t-1\t-1\t-1\t 0
        """

    /// `hexagonal_withca.txt`, verbatim (tabs written as \t).
    private static let hexagonalWithCAText = """
        # Plane normal then slip direction (3 x basal in red), (3 x prism in blue), (6 x py <a> in green), (12 x py <c+a> in green)
        red,blue,blue,blue,green,green,green,green,green,green
        0\t0\t0\t1\t1\t1\t-2\t0
        0\t0\t0\t1\t1\t-2\t1\t0
        0\t0\t0\t1\t-2\t1\t1\t0
        1\t0\t-1\t0\t1\t-2\t1\t0
        0\t1\t-1\t0\t-2\t1\t1\t0
        1\t-1\t0\t0\t1\t1\t-2\t0
        1\t-1\t0\t1\t1\t1\t-2\t0
        1\t-1\t0\t-1\t1\t1\t-2\t0
        1\t0\t-1\t1\t1\t-2\t1\t0
        1\t0\t-1\t-1\t1\t-2\t1\t0
        0\t-1\t1\t1\t-2\t1\t1\t0
        0\t-1\t1\t-1\t-2\t1\t1\t0
        1\t0\t-1\t-1\t1\t1\t-2\t3
        1\t0\t-1\t-1\t2\t-1\t-1\t3
        1\t0\t-1\t1\t-1\t-1\t2\t3
        1\t0\t-1\t1\t-2\t1\t1\t3
        1\t-1\t0\t1\t-2\t1\t1\t3
        1\t-1\t0\t1\t-1\t2\t-1\t3
        1\t-1\t0\t-1\t1\t-2\t1\t3
        1\t-1\t0\t-1\t2\t-1\t-1\t3
        0\t-1\t1\t1\t1\t1\t-2\t3
        0\t-1\t1\t1\t-1\t2\t-1\t3
        0\t-1\t1\t-1\t-1\t-1\t2\t3
        0\t-1\t1\t-1\t1\t-2\t1\t3
        """

    /// `hexagonal_noca.txt`, verbatim (tabs written as \t).
    private static let hexagonalNoCAText = """
        # Plane normal then slip direction (3 x basal in red), (3 x prism in blue), (6 x py <a> in green)
        red,blue,blue,blue,green,green,green,green,green,green
        0\t0\t0\t1\t1\t1\t-2\t0
        0\t0\t0\t1\t1\t-2\t1\t0
        0\t0\t0\t1\t-2\t1\t1\t0
        1\t0\t-1\t0\t1\t-2\t1\t0
        0\t1\t-1\t0\t-2\t1\t1\t0
        1\t-1\t0\t0\t1\t1\t-2\t0
        1\t-1\t0\t1\t1\t1\t-2\t0
        1\t-1\t0\t-1\t1\t1\t-2\t0
        1\t0\t-1\t1\t1\t-2\t1\t0
        1\t0\t-1\t-1\t1\t-2\t1\t0
        0\t-1\t1\t1\t-2\t1\t1\t0
        0\t-1\t1\t-1\t-2\t1\t1\t0
        """
}
