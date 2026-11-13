//
//  KikuchiReflectors.swift
//  Role: the reflectors (Kikuchi bands) of a phase, as diffsims 0.7.0's `ReciprocalLatticeVector` makes them for kikuchipy's
//        `KikuchiPatternSimulator`: the families made symmetrically equivalent (`symmetrise`, orix's `Miller.symmetrise(unique=True)`:
//        each family through the point group's operations in orix's order, the unique vectors kept in order of appearance), every plane
//        down to a smallest spacing (`from_min_dspacing`), the lattice-centring extinctions (`allowed`), the spacings, the kinematical
//        structure factors |F| (`calculate_structure_factor` with the International Tables' X-ray parameters) and the Bragg angles at
//        a beam energy (`calculate_theta`: the refraction-corrected wavelength with Doyle and Turner's mean inner potential).
//        Ported from diffsims (`crystallography/reciprocal_lattice_vector.py`, `structure_factor/structure_factor.py`,
//        `utils/sim_utils.py`) and orix (`vector/miller.py`), both GPL-3.0-or-later (see NOTICE). Parity bundles
//        `m6/kikuchi-reflectors-{ni,ti,al2cu}` and `m6/kikuchi-scattering-tables` in tools/parity/sem, rows in docs/parity.md.
//
//  The cell's atoms come expanded (diffsims' `sanitise_phase`, which expands the asymmetric unit by the space group): the port
//  carries no space-group operations, so a caller hands the full cell, and the first asymmetric atom's orbit for the mean inner
//  potential (diffsims counts only that orbit: decision in docs/decisions.md). As diffsims, the structure factor is computed for the
//  first member of each family and copied to the rest; the phase of a member's F is then its family's, so only |F| is compared, and
//  |F| is all the simulator uses.
//

import Foundation

/// One atom of a unit cell: element by atomic number, fractional position, occupancy. (diffsims' kinematical structure factor takes no
/// Debye–Waller factor from the atoms, so none is carried.)
package nonisolated struct KikuchiAtom: Sendable, Equatable {
    package var z: Int
    package var position: SIMD3<Double>
    package var occupancy: Double

    package init(z: Int, position: SIMD3<Double>, occupancy: Double = 1) {
        self.z = z; self.position = position; self.occupancy = occupancy
    }
}

/// The reflectors of a phase in a lattice frame (orix's re-aligned one, `CrystalLattice`).
package nonisolated struct KikuchiReflectors: Sendable, Equatable {
    package let lattice: CrystalLattice
    /// The planes hkl (as doubles: a symmetrised plane carries orix's rounding of its Cartesian vector).
    package let hkl: [SIMD3<Double>]
    /// For each plane, the index of the family it came from (`symmetrised`), or its own index.
    package let family: [Int]

    package init(lattice: CrystalLattice, hkl: [SIMD3<Double>], family: [Int]? = nil) {
        self.lattice = lattice
        self.hkl = hkl
        self.family = family ?? Array(hkl.indices)
    }

    package var count: Int { hkl.count }

    /// The highest index `minDSpacing` takes along an axis: (2 · 50 + 1)³ ≈ 1 M index triplets at most.
    package static let maximumIndex = 50

    /// The families' symmetrically equivalent planes (diffsims' `symmetrise`), family by family, each in order of appearance through
    /// the point group's elements (orix's `outer`, an improper element negating the vector), rounded and made unique as orix's
    /// `Vector3d.unique`, then written back as hkl. `multiplicity` is each family's count.
    package static func symmetrised(_ families: [SIMD3<Double>], lattice: CrystalLattice, pointGroup: PointGroup) -> (reflectors: KikuchiReflectors, multiplicity: [Int]) {
        var hkl: [SIMD3<Double>] = [], family: [Int] = [], multiplicity: [Int] = []
        for (i, f) in families.enumerated() {
            let g = lattice.cartesian(hkl: f)
            let equivalent = Vector3.unique(pointGroup.elements.map { $0 * g })
            multiplicity.append(equivalent.count)
            for v in equivalent {
                hkl.append(lattice.hkl(cartesian: v))
                family.append(i)
            }
        }
        return (KikuchiReflectors(lattice: lattice, hkl: hkl, family: family), multiplicity)
    }

    /// Every plane with a spacing of at least `minDSpacing` (diffsims' `from_min_dspacing`): the highest index along each axis whose
    /// spacing is still above the bound (orix's `_get_highest_hkl`), every index triplet within them in reversed product order with
    /// (000) left out (`_get_indices_from_highest`), then those with d ≥ the bound.
    /// A bound that is not a positive number, or one that would walk an axis past `maximumIndex` (a bound far below the cell, or a
    /// degenerate lattice whose spacing never falls), gives no plane instead of a loop that never ends.
    package static func minDSpacing(_ minDSpacing: Double, lattice: CrystalLattice) -> KikuchiReflectors {
        let none = KikuchiReflectors(lattice: lattice, hkl: [])
        guard minDSpacing > 0, minDSpacing.isFinite else { return none }
        var highest = [1, 1, 1]
        for axis in 0..<3 {
            var index = SIMD3<Double>(0, 0, 0)
            index[axis] = 1
            var d = 1 / lattice.rnorm(index)
            while d > minDSpacing {
                index[axis] += 1
                guard index[axis] <= Double(maximumIndex) else { return none }
                d = 1 / lattice.rnorm(index)
            }
            highest[axis] = Int(index[axis]) - 1
        }
        var all: [SIMD3<Double>] = []
        for h in -highest[0]...highest[0] {
            for k in -highest[1]...highest[1] {
                for l in -highest[2]...highest[2] where !(h == 0 && k == 0 && l == 0) {
                    all.append(SIMD3(Double(h), Double(k), Double(l)))
                }
            }
        }
        let kept = all.reversed().filter { 1 / lattice.rnorm($0) >= minDSpacing }
        return KikuchiReflectors(lattice: lattice, hkl: kept)
    }

    /// The planes the lattice centring allows (diffsims' `allowed`, from the first letter of the space group's short name: A, B, C, F, I,
    /// R or H, P). Nil for a primitive hexagonal lattice (diffsims raises there) or an unknown centring.
    package func allowed(centering: Character) -> [Bool]? {
        let ints = hkl.map { v in (h: Int(v.x.rounded(.toNearestOrEven)), k: Int(v.y.rounded(.toNearestOrEven)), l: Int(v.z.rounded(.toNearestOrEven))) }
        func mod(_ x: Int, _ n: Int) -> Int { ((x % n) + n) % n }
        switch centering {
        case "A": return ints.map { mod($0.k + $0.l, 2) == 0 }
        case "B": return ints.map { mod($0.h + $0.l, 2) == 0 }
        case "C": return ints.map { mod($0.h + $0.k, 2) == 0 }
        case "F": return ints.map { let s = mod($0.h, 2) + mod($0.k, 2) + mod($0.l, 2); return s != 1 && s != 2 }
        case "I": return ints.map { mod($0.h + $0.k + $0.l, 2) == 0 }
        case "R", "H": return ints.map { mod(-$0.h + $0.k + $0.l, 3) == 0 }
        case "P": return Self.isHexagonal(lattice) ? nil : Array(repeating: true, count: hkl.count)
        default: return nil
        }
    }

    /// diffsims' `has_hexagonal_lattice` (orix's `Phase.is_hexagonal`): α, β, γ close to 90°, 90°, 120° (numpy's `allclose`).
    static func isHexagonal(_ lattice: CrystalLattice) -> Bool {
        func close(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= 1e-8 + 1e-5 * abs(y) }
        return close(lattice.alpha, 90) && close(lattice.beta, 90) && close(lattice.gamma, 120)
    }

    /// d = 1 / |g| of each plane.
    package var dSpacing: [Double] { hkl.map { lattice.dSpacing($0) } }

    // MARK: Structure factors and Bragg angles

    /// |F| of each plane (diffsims' `calculate_structure_factor`, scattering parameters "xtables", no Debye–Waller factor): F = Σ f(|g|)
    /// occ exp(2πi hkl·r) over the cell's atoms, f(|g|) = Σ aᵢ exp(−bᵢ |g|² / 4) from the International Tables' X-ray parameters, |g| in
    /// 1/Å (so the lattice must be in Å). An element the table lacks scatters nothing, as diffsims' zero default. As diffsims does,
    /// the positions are first taken into the frame of the Miller indices (r · (stdbase · recbase)⁻¹, the identity unless the lattice
    /// was re-aligned from diffpy's standard frame, as orix re-aligns a hexagonal one), and F is computed for the first plane of each
    /// family and given to the rest of it.
    package func structureFactors(cell: [KikuchiAtom]) -> [Double] {
        let l = lattice
        let std = CrystalLattice.standardBase(a: l.a, b: l.b, c: l.c, alpha: l.alpha, beta: l.beta, gamma: l.gamma)
        let product = std.map { r in r.x * l.recbase[0] + r.y * l.recbase[1] + r.z * l.recbase[2] }
        let toMiller = CrystalLattice.inverse(product)
        let positions = cell.map { a in a.position.x * toMiller[0] + a.position.y * toMiller[1] + a.position.z * toMiller[2] }
        var firstOfFamily: [Int: Int] = [:]
        for (i, f) in family.enumerated() where firstOfFamily[f] == nil { firstOfFamily[f] = i }
        var memo: [Int: Double] = [:]
        return family.map { f in
            let i = firstOfFamily[f, default: 0]   // every family was entered above
            if let known = memo[i] { return known }
            let v = hkl[i]
            let g = l.rnorm(v)
            let g2 = g * g
            var re = 0.0, im = 0.0
            for (atom, r) in zip(cell, positions) {
                let weight = Self.xrayScatteringFactor(z: atom.z, gSquared: g2) * atom.occupancy
                let phase = 2 * Double.pi * Vector3.dot(v, r)
                re += weight * cos(phase)
                im += weight * sin(phase)
            }
            let value = (re * re + im * im).squareRoot()
            memo[i] = value
            return value
        }
    }

    /// The Bragg angle θ = arcsin(λ |g| / 2) of each plane, λ in Å (`wavelength` in nm × 10) and |g| in 1/Å (diffsims' `calculate_theta`).
    package func braggAngles(wavelengthNM: Double) -> [Double] {
        let lambda = 10 * wavelengthNM
        return hkl.map { asin(0.5 * lambda * lattice.rnorm($0)) }
    }

    /// The X-ray atomic scattering factor Σ aᵢ exp(−bᵢ g² / 4) (diffsims' `get_atomic_scattering_factors`, "xtables"); 0 for an element
    /// the table does not hold.
    static func xrayScatteringFactor(z: Int, gSquared g2: Double) -> Double {
        guard z >= 1, z <= KikuchiScatteringTables.xray.count else { return 0 }
        let p = KikuchiScatteringTables.xray[z - 1]
        var f = 0.0
        for i in 0..<5 { f += p[2 * i] * exp(-0.25 * g2 * p[2 * i + 1]) }
        return f
    }
}

/// The electron wavelength in the crystal (diffsims' `get_refraction_corrected_wavelength`), in nm.
package nonisolated enum KikuchiWavelength {
    /// The CODATA 2022 constants scipy 1.16 hands diffsims: c (m/s), e (C), h (J s) and the electron mass ("atomic unit of mass", kg).
    package static let c = 299_792_458.0
    package static let e = 1.602176634e-19
    package static let h = 6.62607015e-34
    package static let electronMass = 9.1093837139e-31

    /// λ = h / √(2 m e Ψ̂) in nm with Ψ̂ = V (1 + e V / 2 m c²) + |V₀| γ: the relativistic accelerating potential plus the mean inner
    /// potential V₀ = Σ 47.87801 / V_cell Σᵢ aᵢ over the first asymmetric atom's orbit (Doyle–Turner, at s = 0), scaled by the relativistic
    /// γ = 1 + e V / m c² (diffsims' `get_doyleturner_structure_factor` at hkl = 0). `orbit` is that atom's positions in the cell; only
    /// its element and occupancy count (all at s = 0). `cellVolume` in Å³; `voltage` in V.
    package static func refractionCorrected(voltage: Double, orbit: [KikuchiAtom], cellVolume: Double) -> Double {
        let temp1 = 1e9 * h / (2 * electronMass * e).squareRoot()
        let temp2 = e * 0.5 * voltage / electronMass / (c * c)
        var psiHat = voltage * (1 + temp2)
        var re = 0.0
        for atom in orbit {
            guard atom.z >= 1, atom.z <= KikuchiScatteringTables.doyleTurner.count else { continue }
            let row = KikuchiScatteringTables.doyleTurner[atom.z - 1]
            let f = 47.87801 / cellVolume * (row[0] + row[1] + row[2] + row[3]) * atom.occupancy
            re += f
        }
        let gamma = 1 + 2 * e * 0.5 * voltage / electronMass / (c * c)
        psiHat += abs(re) * gamma
        return temp1 / psiHat.squareRoot()
    }
}

/// The lattice centring of each space group (the first letter of diffpy's short name, 1 to 230).
package nonisolated enum SpaceGroupCentering {
    private static let letters = Array("PPPPCPPCCPPCPPCPPPPCCFIIPPPPPPPPPPCCCAAAAFFIIIPPPPPPPPPPPPPPPPCCCCCCFFIIIIPPPPIIPIPPPPIIPPPPPPPPIIPPPPPPPPIIIIPPPPPPPPIIIIPPPPPPPPPPPPPPPPIIIIPPPHPHPPPPPPHPPPPHHPPPPHHPPPPPPPPPPPPPPPPPPPPPPPPPPPPFIPIPPFFIPIPPFFIPPIPFIPFIPPPPFFFFII")

    /// The centring letter of space group `number`, nil outside 1...230.
    package static func letter(_ number: Int) -> Character? {
        (1...230).contains(number) ? letters[number - 1] : nil
    }
}
