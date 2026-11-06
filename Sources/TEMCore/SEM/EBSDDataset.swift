//
//  EBSDDataset.swift
//  Role: what an EBSD or TKD pattern file holds, the one value every pattern reader fills and the Patterns room reads: the scan
//        grid and its step, the pattern shape and element type, the detector geometry with its projection centres in the Bruker
//        convention (kikuchipy's internal one), the static background the file carries, the SEM header, the file's own crystal map
//        when it has one, and where the patterns are (`EBSDPatternSource`) so they are read by map position on demand.
//        Ported from kikuchipy 0.13.1 (`kikuchipy/io/plugins/_h5ebsd.py`, `detectors/_ebsd_detector.py`; GPL-3.0-or-later); the
//        SEM program's parity rows are in docs/parity.md.
//

import Foundation
import FormatoCore
import FormatoHDF5

/// The layouts the readers know.
package nonisolated enum EBSDFileFormat: String, Sendable, Equatable {
    case kikuchipyH5EBSD = "kikuchipy h5ebsd"
    case brukerH5EBSD = "Bruker h5ebsd"
    case edaxH5EBSD = "EDAX h5ebsd"
    case oxfordH5OINA = "Oxford H5OINA"
}

/// The detector as kikuchipy's `EBSDDetector` holds it after reading: shape, pixel size, binning, the three tilts and the sample
/// tilt in degrees, and the projection centres converted to the Bruker convention (x right, y DOWN, both as a fraction of the
/// pattern width and height, z as a fraction of the pattern height).
package nonisolated struct EBSDDetectorGeometry: Sendable, Equatable {
    package var rows: Int
    package var columns: Int
    /// Detector pixel size in µm (1 where the file states none).
    package var pixelSize: Double
    package var binning: Int
    /// Detector elevation (tilt), azimuthal and twist angles in degrees.
    package var tilt: Double
    package var azimuthal: Double
    package var twist: Double
    package var sampleTilt: Double
    /// One centre for the whole scan, or one per map position in row-major scan order.
    package var projectionCenters: [SIMD3<Double>]

    package init(rows: Int, columns: Int, pixelSize: Double = 1, binning: Int = 1, tilt: Double = 0, azimuthal: Double = 0, twist: Double = 0,
                 sampleTilt: Double = 70, projectionCenters: [SIMD3<Double>]) {
        self.rows = rows; self.columns = columns; self.pixelSize = pixelSize; self.binning = binning
        self.tilt = tilt; self.azimuthal = azimuthal; self.twist = twist; self.sampleTilt = sampleTilt
        self.projectionCenters = projectionCenters
    }

    /// Columns over rows, kikuchipy's `aspect_ratio`.
    package var aspectRatio: Double { Double(columns) / Double(rows) }

    /// The projection-centre conventions the files write, named as kikuchipy names them.
    package enum Convention: String, Sendable, Equatable { case bruker, tsl, oxford, emsoft4, emsoft5 }

    /// `pc` written in `convention`, converted to the Bruker convention (`EBSDDetector._get_pc_in_bruker_convention`).
    package func brukerCenter(_ pc: SIMD3<Double>, from convention: Convention) -> SIMD3<Double> {
        switch convention {
        case .bruker: return pc
        case .tsl: return SIMD3(pc.x, 1 - pc.y, pc.z * (Double(min(rows, columns)) / Double(rows)))
        case .oxford: return SIMD3(pc.x, 1 - pc.y * aspectRatio, pc.z * aspectRatio)
        case .emsoft4, .emsoft5:
            let pcx = convention == .emsoft4 ? -pc.x : pc.x
            let b = Double(binning)
            return SIMD3(0.5 - pcx / (Double(columns) * b), 0.5 - pc.y / (Double(rows) * b), pc.z / (Double(rows) * b * pixelSize))
        }
    }

    /// A Bruker-convention centre in `convention` (`EBSDDetector._get_pc_in_convention`).
    package func center(_ pc: SIMD3<Double>, in convention: Convention) -> SIMD3<Double> {
        switch convention {
        case .bruker: return pc
        case .tsl: return SIMD3(pc.x, 1 - pc.y, pc.z / (Double(min(rows, columns)) / Double(rows)))
        case .oxford: return SIMD3(pc.x, (1 - pc.y) / aspectRatio, pc.z / aspectRatio)
        case .emsoft4, .emsoft5:
            let b = Double(binning)
            var x = (0.5 - pc.x) * Double(columns) * b
            if convention == .emsoft4 { x = -x }
            return SIMD3(x, (0.5 - pc.y) * Double(rows) * b, pc.z * Double(rows) * b * pixelSize)
        }
    }
}

/// A phase of the file's crystal map.
package nonisolated struct EBSDPhase: Sendable, Equatable {
    package var name: String
    package var spaceGroup: Int?
    package var pointGroup: String?
    /// a, b, c (the file's unit), alpha, beta, gamma (degrees).
    package var lattice: [Double]?

    package init(name: String, spaceGroup: Int? = nil, pointGroup: String? = nil, lattice: [Double]? = nil) {
        self.name = name; self.spaceGroup = spaceGroup; self.pointGroup = pointGroup; self.lattice = lattice
    }
}

/// The indexing results a file carries, one entry per map position in row-major scan order (orix's `CrystalMap` fields).
package nonisolated struct EBSDCrystalMapData: Sendable, Equatable {
    /// Bunge Euler angles (phi1, Phi, phi2) in radians.
    package var euler: [SIMD3<Double>]
    package var phaseIDs: [Int]
    package var phases: [EBSDPhase]
    /// Every other per-point column (scores, fit, confidence, ...), by its name in the file.
    package var properties: [String: [Double]]

    package init(euler: [SIMD3<Double>], phaseIDs: [Int], phases: [EBSDPhase], properties: [String: [Double]] = [:]) {
        self.euler = euler; self.phaseIDs = phaseIDs; self.phases = phases; self.properties = properties
    }
}

/// The SEM header the file carries beside the patterns.
package nonisolated struct EBSDSEMHeader: Sendable, Equatable {
    package var beamEnergyKeV: Double?
    package var magnification: Double?
    package var workingDistanceMM: Double?
    package var microscope: String?

    package init(beamEnergyKeV: Double? = nil, magnification: Double? = nil, workingDistanceMM: Double? = nil, microscope: String? = nil) {
        self.beamEnergyKeV = beamEnergyKeV; self.magnification = magnification; self.workingDistanceMM = workingDistanceMM; self.microscope = microscope
    }
}

/// Where a scan's patterns are in the file, and the order they are read in: `fileIndexByPosition[k]` is the index in the dataset of
/// the pattern at map position k (row-major), nil for a missing pattern (a file shorter than its scan is zero-padded, as
/// kikuchipy pads it); nil as a whole means the file order is the map order.
package nonisolated struct EBSDPatternSource: Sendable, Equatable {
    package var url: URL
    package var datasetPath: String
    /// The dataset's shape as stored: (n, rows, columns) or (scanRows, scanColumns, rows, columns).
    package var fileShape: [Int]
    package var dataType: FormatoDataType
    package var fileIndexByPosition: [Int?]?

    package init(url: URL, datasetPath: String, fileShape: [Int], dataType: FormatoDataType, fileIndexByPosition: [Int?]? = nil) {
        self.url = url; self.datasetPath = datasetPath; self.fileShape = fileShape; self.dataType = dataType; self.fileIndexByPosition = fileIndexByPosition
    }

    /// Patterns the dataset holds.
    package var fileCount: Int { fileShape.count == 4 ? fileShape[0] * fileShape[1] : fileShape[0] }
}

/// One scan of an EBSD or TKD pattern file.
package nonisolated struct EBSDDataset: Sendable, Equatable {
    package var format: EBSDFileFormat
    /// The file's own words, lowercased as kikuchipy keeps them (`manufacturer`, `version` of the top group).
    package var manufacturer: String
    package var version: String
    /// The scan group read, and every scan group the file holds.
    package var scanGroup: String
    package var scanGroups: [String]
    package var scanRows: Int
    package var scanColumns: Int
    package var patternRows: Int
    package var patternColumns: Int
    package var dataType: FormatoDataType
    /// Scan step along y (rows) and x (columns), in `scanUnit` (µm in every layout; 1 where the file states none).
    package var stepY: Double
    package var stepX: Double
    package var scanUnit: String
    package var detector: EBSDDetectorGeometry
    /// The static background pattern, as stored (uint8 or uint16, `patternRows` x `patternColumns`), when the file carries one.
    package var staticBackground: FormatoArray?
    package var sem: EBSDSEMHeader
    package var crystalMap: EBSDCrystalMapData?
    package var patterns: EBSDPatternSource

    package init(format: EBSDFileFormat, manufacturer: String, version: String, scanGroup: String, scanGroups: [String], scanRows: Int, scanColumns: Int,
                 patternRows: Int, patternColumns: Int, dataType: FormatoDataType, stepY: Double, stepX: Double, scanUnit: String = "um",
                 detector: EBSDDetectorGeometry, staticBackground: FormatoArray? = nil, sem: EBSDSEMHeader = EBSDSEMHeader(),
                 crystalMap: EBSDCrystalMapData? = nil, patterns: EBSDPatternSource) {
        self.format = format; self.manufacturer = manufacturer; self.version = version; self.scanGroup = scanGroup; self.scanGroups = scanGroups
        self.scanRows = scanRows; self.scanColumns = scanColumns; self.patternRows = patternRows; self.patternColumns = patternColumns
        self.dataType = dataType; self.stepY = stepY; self.stepX = stepX; self.scanUnit = scanUnit; self.detector = detector
        self.staticBackground = staticBackground; self.sem = sem; self.crystalMap = crystalMap; self.patterns = patterns
    }

    package var patternCount: Int { scanRows * scanColumns }
    package var patternPixels: Int { patternRows * patternColumns }

    /// Every pattern in map order as one array of shape (scanRows, scanColumns, patternRows, patternColumns), zero where the file has
    /// none. One slab read of the dataset, then the reorder.
    package func allPatterns() throws -> FormatoArray {
        let reader = try EBSDPatternReader(self)
        return try reader.allPatterns()
    }
}

/// Reads patterns of one dataset by map position; holds the HDF5 dataset open between calls (the live pattern pane asks per cursor move).
package nonisolated final class EBSDPatternReader: @unchecked Sendable {
    package let dataset: EBSDDataset
    private let slabs: HDF5SlabReader

    package init(_ dataset: EBSDDataset) throws {
        self.dataset = dataset
        do {
            slabs = try HDF5SlabReader(url: dataset.patterns.url, path: dataset.patterns.datasetPath)
        } catch { throw EBSDReadError.wrap(error, file: dataset.patterns.url) }
    }

    /// The pattern at map position (row, column), shape (patternRows, patternColumns), as stored; zero where the file has none.
    package func pattern(row: Int, column: Int) throws -> FormatoArray {
        guard row >= 0, row < dataset.scanRows, column >= 0, column < dataset.scanColumns else {
            throw EBSDReadError(text: "Position (\(row), \(column)) is outside the \(dataset.scanRows) x \(dataset.scanColumns) scan.")
        }
        let position = row * dataset.scanColumns + column
        let index: Int?
        if let order = dataset.patterns.fileIndexByPosition { index = position < order.count ? order[position] : nil }
        else { index = position < dataset.patterns.fileCount ? position : nil }
        let shape = [dataset.patternRows, dataset.patternColumns]
        guard let index else {
            return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: Data(count: dataset.patternPixels * dataset.dataType.byteSize))
        }
        let (start, count) = slab(fileIndex: index)
        let read: FormatoArray
        do { read = try slabs.read(start: start, count: count) } catch { throw EBSDReadError.wrap(error, file: dataset.patterns.url) }
        return try FormatoArray(dataType: read.dataType, shape: shape, bytes: read.bytes)
    }

    /// See `EBSDDataset.allPatterns`.
    package func allPatterns() throws -> FormatoArray {
        let source = dataset.patterns
        let whole: FormatoArray
        do { whole = try slabs.read(start: [Int](repeating: 0, count: source.fileShape.count), count: source.fileShape) }
        catch { throw EBSDReadError.wrap(error, file: source.url) }
        let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
        let total = dataset.patternCount
        let shape = [dataset.scanRows, dataset.scanColumns, dataset.patternRows, dataset.patternColumns]
        let fileCount = source.fileCount
        if source.fileIndexByPosition == nil, fileCount == total {
            return try FormatoArray(dataType: whole.dataType, shape: shape, bytes: whole.bytes)
        }
        var out = Data(count: total * bytesPerPattern)
        whole.bytes.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for position in 0..<total {
                    let index: Int?
                    if let order = source.fileIndexByPosition { index = position < order.count ? order[position] : nil }
                    else { index = position < fileCount ? position : nil }
                    guard let index, index < fileCount else { continue }
                    let from = src.baseAddress!.advanced(by: index * bytesPerPattern)
                    dst.baseAddress!.advanced(by: position * bytesPerPattern).copyMemory(from: from, byteCount: bytesPerPattern)
                }
            }
        }
        return try FormatoArray(dataType: whole.dataType, shape: shape, bytes: out)
    }

    private func slab(fileIndex: Int) -> (start: [Int], count: [Int]) {
        let shape = dataset.patterns.fileShape
        if shape.count == 4 {
            return ([fileIndex / shape[1], fileIndex % shape[1], 0, 0], [1, 1, shape[2], shape[3]])
        }
        return ([fileIndex, 0, 0], [1, shape[1], shape[2]])
    }
}

/// What a reader says when a file is not what it claims, in one sentence for the Open Files row.
package nonisolated struct EBSDReadError: Error, LocalizedError, Equatable {
    package var text: String
    package var errorDescription: String? { text }

    package init(text: String) { self.text = text }

    package static func wrap(_ error: Error, file: URL) -> EBSDReadError {
        if let already = error as? EBSDReadError { return already }
        let words = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return EBSDReadError(text: "\(file.lastPathComponent): \(words)")
    }
}
