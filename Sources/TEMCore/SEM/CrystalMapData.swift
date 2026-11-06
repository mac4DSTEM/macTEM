//
//  CrystalMapData.swift
//  Role: an orientation map as the SEM map readers return it (D-SEM-1): one point per row of the vendor's file, with its
//        phase, its Bunge Euler angles in degrees as the file writes them, its coordinates in µm and the vendor's per-point
//        columns under the vendor's names. The shape and step sizes are orix 0.15.0's (`CrystalMap.shape`, `dx`, `dy`:
//        orix/crystal_map/crystal_map.py, `_step_size_from_coordinates`, `_data_slices_from_coordinates`), computed from the
//        coordinates, so a map read here and in orix agree on its grid. Rotations (quaternions, symmetry) are the phase 3
//        orientation core's; this type keeps what the file holds.
//

import Foundation

package nonisolated struct CrystalMapData: Sendable, Equatable {
    package struct Phase: Sendable, Equatable {
        /// The id the file's rows use (1 and up; 0 in a row means not indexed).
        package var id: Int
        package var name: String
        /// a, b, c in Å and α, β, γ in degrees.
        package var lattice: [Double]
        /// The Laue group id of the Channel Text File header (1 to 11).
        package var laueGroupID: Int
        /// The Laue group as orix names it (`-1`, `2/m`, `mmm`, `4/m`, `4/mmm`, `-3`, `-3m`, `6/m`, `6/mmm`, `m3`, `m-3m`).
        package var pointGroup: String
        /// The space group number, nil where the file writes 0 (MTEX exports).
        package var spaceGroup: Int?

        package init(id: Int, name: String, lattice: [Double], laueGroupID: Int, pointGroup: String, spaceGroup: Int?) {
            self.id = id
            self.name = name
            self.lattice = lattice
            self.laueGroupID = laueGroupID
            self.pointGroup = pointGroup
            self.spaceGroup = spaceGroup
        }
    }

    /// Who wrote the file, as orix detects it from the header; `orientationTable` is a headerless export (first line the
    /// column names, as orix-data's Ti_orientations.ctf from MTEX).
    package enum Vendor: String, Sendable {
        case oxfordOrBruker = "oxford_or_bruker"
        case emsoft
        case astar
        case mtex
        case orientationTable = "orientation_table"
    }

    package var phases: [Phase]
    /// Coordinates in `scanUnit`, one per point; empty when the file has none.
    package var x: [Double]
    package var y: [Double]
    /// One per point; -1 is not indexed (the file's 0).
    package var phaseID: [Int]
    /// Three per point: phi1, Phi, phi2 in degrees (Bunge), as the file writes them.
    package var eulerDegrees: [Double]
    /// The vendor's per-point columns beyond phase, coordinates and Euler angles, in file order.
    package var propertyNames: [String]
    package var properties: [String: [Double]]
    package var scanUnit: String
    package var vendor: Vendor
    /// The header lines above the data, verbatim.
    package var header: [String]

    package init(phases: [Phase], x: [Double], y: [Double], phaseID: [Int], eulerDegrees: [Double], propertyNames: [String],
                 properties: [String: [Double]], scanUnit: String, vendor: Vendor, header: [String]) {
        self.phases = phases
        self.x = x
        self.y = y
        self.phaseID = phaseID
        self.eulerDegrees = eulerDegrees
        self.propertyNames = propertyNames
        self.properties = properties
        self.scanUnit = scanUnit
        self.vendor = vendor
        self.header = header
    }

    package var pointCount: Int { phaseID.count }

    /// Euler angles of one point in degrees.
    package func euler(at index: Int) -> (phi1: Double, Phi: Double, phi2: Double) {
        (eulerDegrees[3 * index], eulerDegrees[3 * index + 1], eulerDegrees[3 * index + 2])
    }

    /// orix `CrystalMap.dy` and `dx`: the difference of the two smallest distinct coordinates, 0 for one value.
    package var stepSizes: [Double] { [Self.stepSize(y), Self.stepSize(x)] }

    /// orix `CrystalMap.shape`: rows then columns from the coordinate extents; an axis with one value (or none) is dropped.
    package var shape: [Int] {
        Self.dataSlices(coordinates: [y, x], steps: stepSizes).map { $0.stop - $0.start }
    }

    package static func stepSize(_ coordinates: [Double]) -> Double {
        let unique = Set(coordinates).sorted()
        return unique.count > 1 ? unique[1] - unique[0] : 0
    }

    /// orix `_data_slices_from_coordinates`: for each axis with coordinates and a non-zero step, the index extent
    /// `round(min / step) ..< round(max / step + 1)` (numpy's round half to even).
    package static func dataSlices(coordinates: [[Double]], steps: [Double]) -> [(start: Int, stop: Int)] {
        var slices: [(start: Int, stop: Int)] = []
        for (values, step) in zip(coordinates, steps) where !values.isEmpty && step != 0 {
            let low = values.min()!, high = values.max()!
            slices.append((start: Int((low / step).rounded(.toNearestOrEven)), stop: Int((high / step + 1).rounded(.toNearestOrEven))))
        }
        return slices
    }
}
