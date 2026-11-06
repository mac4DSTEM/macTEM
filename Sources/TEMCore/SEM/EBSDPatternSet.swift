//
//  EBSDPatternSet.swift
//  Role: the patterns an EBSD or TKD file holds, as the SEM readers return them (D-SEM-1: SEM code lives in TEMCore/SEM over
//        the kits). One pattern per map point in map order, row-major over the navigation shape, each pattern row-major over
//        its detector shape; the pixel type is the file's (8- or 16-bit unsigned). The per-pattern positions the vendor wrote
//        (beam position in µm, map column and row) ride along when the file has them. The pattern browser (P1-06) and the
//        virtual images (P1-07) read this; the h5ebsd family (P1-01) returns the same shape of data.
//

import Foundation

package nonisolated struct EBSDPatternSet: Sendable, Equatable {
    /// The pixels of every pattern, flattened: pattern index, then detector row, then detector column.
    package enum Pixels: Sendable, Equatable {
        case uint8([UInt8])
        case uint16([UInt16])

        package var count: Int {
            switch self {
            case .uint8(let v): v.count
            case .uint16(let v): v.count
            }
        }

        package var bitsPerPixel: Int {
            switch self {
            case .uint8: 8
            case .uint16: 16
            }
        }
    }

    /// The map's shape in points: `[rows, columns]` for a map, `[count]` for a file that lists its patterns without a grid.
    package var navigationShape: [Int]
    /// The detector shape of every pattern: `[rows, columns]`.
    package var patternShape: [Int]
    package var pixels: Pixels
    /// One step per navigation axis, in `scanUnit`.
    package var stepSizes: [Double]
    /// "um" for a map with beam positions, "px" for a plain list of patterns.
    package var scanUnit: String
    /// For each returned pattern, its index in the file's own pattern list (the map's 1D index).
    package var map1DIDs: [Int]
    /// For each returned pattern, the record it came from in the file (0 is the first record after the header).
    package var fileOrder: [Int]
    /// Beam position per returned pattern, in µm, when the file footers carry it.
    package var beamX: [Double]?
    package var beamY: [Double]?
    /// Map column and row per returned pattern, when the file's pattern headers carry them (`.ebsp` version 5 and later).
    package var mapX: [Int]?
    package var mapY: [Int]?

    package var patternCount: Int { navigationShape.reduce(1, *) }
    package var pixelsPerPattern: Int { patternShape.reduce(1, *) }

    package init(navigationShape: [Int], patternShape: [Int], pixels: Pixels, stepSizes: [Double], scanUnit: String,
                 map1DIDs: [Int], fileOrder: [Int], beamX: [Double]? = nil, beamY: [Double]? = nil,
                 mapX: [Int]? = nil, mapY: [Int]? = nil) {
        self.navigationShape = navigationShape
        self.patternShape = patternShape
        self.pixels = pixels
        self.stepSizes = stepSizes
        self.scanUnit = scanUnit
        self.map1DIDs = map1DIDs
        self.fileOrder = fileOrder
        self.beamX = beamX
        self.beamY = beamY
        self.mapX = mapX
        self.mapY = mapY
    }

    /// One pattern's pixels as doubles (detector row-major), for a pane or a virtual image.
    package func pattern(at index: Int) -> [Double] {
        let n = pixelsPerPattern
        let start = index * n
        switch pixels {
        case .uint8(let v): return v[start..<(start + n)].map(Double.init)
        case .uint16(let v): return v[start..<(start + n)].map(Double.init)
        }
    }
}
