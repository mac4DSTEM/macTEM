//
//  HoughCrystalMap.swift
//  A Hough-indexed scan as a crystal map, as kikuchipy 0.13.1's `xmap_from_hough_indexing_data` builds it from
//  pyEBSDindex's result (the best solution per point): the indexer's phases as the phase list (name, space group, its
//  point group, lattice; Tableau colours in order), phase -1 where not indexed (`not_indexed` added), the identity rotation
//  there, the properties fit, cm, pq and nmatch, and x and y on the scan grid from the step sizes (kikuchipy's
//  `create_coordinate_arrays`). Parity: `m4/hough-indexing-nickel-large` (its `xmap` values and arrays).
//

import Foundation

extension HoughIndexer {
    /// The indexed scan as orix's `CrystalMap` (D-SEM-81). `steps` are the scan's row and column steps in `scanUnit`.
    package func crystalMap(_ map: Map, steps: (dy: Double, dx: Double) = (1, 1), scanUnit: String = "px") throws -> CrystalMap {
        guard map.solutions.count == map.scanRows * map.scanColumns else { throw Error.shape }
        let phaseList = PhaseList(ids: Array(phases.indices), phases: phases.map { lib in
            CrystalPhase(name: lib.name, spaceGroup: lib.spaceGroup,
                         pointGroup: SpaceGroupPointGroup.pointGroup(ofSpaceGroup: lib.spaceGroup)?.name, lattice: lib.lattice)
        }, assignColors: true)
        let (x, y) = CrystalMap.coordinates(shape: (map.scanRows, map.scanColumns), steps: steps)
        let s = map.solutions
        return try CrystalMap(
            rotations: map.rotations.map(\.q), phaseIDs: s.map { $0.phase < 0 ? PhaseList.notIndexedID : $0.phase },
            x: x, y: y, phaseList: phaseList,
            properties: ["fit": s.map(\.fit), "cm": s.map(\.confidence), "pq": s.map(\.patternQuality),
                         "nmatch": s.map { Double($0.matchedBands) }],
            scanUnit: scanUnit)
    }
}
