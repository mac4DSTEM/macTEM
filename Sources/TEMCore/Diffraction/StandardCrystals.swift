//
//  StandardCrystals.swift
//  Role: the standards a ring pattern is calibrated against, named (slice 1a, R7): Au, Al and Si with the lattice constant each
//        is taken at, as DiffractoKit structures. The structures are DiffractoKit's `CrystalPresets`; this file names
//        them for the room and builds their kinematic lists. The lattice constant is the reference the room states, not a
//        measurement of the sample: Au 4.0782 Å, Al 4.0495 Å (pure aluminium at room temperature), Si 5.4309 Å.
//

import Foundation
import DiffractoCore
import DiffractoScattering

package struct StandardCrystal: Sendable, Equatable {
    /// "Au", "Al" or "Si".
    package let name: String
    package let structure: CrystalStructure
    /// The cubic lattice constant (Å) the standard is taken at.
    package var latticeConstant: Double { structure.cell.a }
}

package nonisolated enum StandardCrystals {

    /// The standards, in the order the room offers them.
    package static let all: [StandardCrystal] = [
        StandardCrystal(name: "Au", structure: CrystalPresets.gold),
        StandardCrystal(name: "Al", structure: CrystalPresets.aluminum),
        StandardCrystal(name: "Si", structure: CrystalPresets.silicon),
    ]

    package static func named(_ name: String) -> StandardCrystal? { all.first { $0.name == name } }

    /// The kinematic list of a standard to k_max (Å⁻¹): the kit's, with its default |F| cut.
    package static func list(of standard: StandardCrystal, kMax: Double) throws(KinematicError) -> KinematicReflectionList {
        try standard.structure.kinematicReflections(kMax: kMax)
    }
}
