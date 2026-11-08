//
//  EBSDDataset.swift
//  Role: what an EBSD or TKD pattern file holds, the one value every pattern reader fills and the Patterns room reads: the scan
//        grid and its step, the pattern shape and element type, the detector geometry with its projection centres in the Bruker
//        convention (kikuchipy's internal one), the static background the file carries, the SEM header, the file's own crystal map
//        when it has one, and where the patterns are (`EBSDPatternSource`: an HDF5 dataset or fixed-size records of a vendor's binary
//        file) so they are read by map position on demand. The header numbers a reader sizes and indexes by pass `ReaderNumber`,
//        and every dataset passes `EBSDDataset.validated()` at the open, so a broken or hostile header is refused in words.
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
    /// Oxford Instruments' binary pattern file (`.ebsp`), with the `.ctf` map next to it when there is one.
    case oxfordBinary = "Oxford ebsp"
    /// EDAX TSL's binary pattern file (`.up1`, `.up2`), with the `.ang` map next to it when there is one.
    case edaxBinary = "EDAX up1/up2"
    /// NORDIF `Pattern.dat` with `Setting.txt` beside it (`NORDIFOpening`).
    case nordif = "NORDIF"
    /// The generated demo dataset (`DemoDocuments.ebsd`): not data, never read from a file.
    case generated = "generated demo (not data)"
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
    /// How the file lays its patterns out.
    package enum Layout: Sendable, Equatable {
        /// An HDF5 dataset of shape `fileShape`.
        case hdf5(datasetPath: String)
        /// Fixed-size records from byte `offset`, `recordBytes` each, the pattern's pixels (little-endian, row-major) `patternOffset`
        /// bytes into its record: EDAX `.up1`/`.up2` (records are bare patterns) and Oxford `.ebsp` (a header and a footer around each).
        case records(offset: Int, recordBytes: Int, patternOffset: Int)
    }

    package var url: URL
    package var layout: Layout
    /// The dataset's shape as stored: (n, rows, columns) or (scanRows, scanColumns, rows, columns).
    package var fileShape: [Int]
    package var dataType: FormatoDataType
    package var fileIndexByPosition: [Int?]?

    package init(url: URL, layout: Layout, fileShape: [Int], dataType: FormatoDataType, fileIndexByPosition: [Int?]? = nil) {
        self.url = url; self.layout = layout; self.fileShape = fileShape; self.dataType = dataType; self.fileIndexByPosition = fileIndexByPosition
    }

    /// An HDF5 dataset at `datasetPath`.
    package init(url: URL, datasetPath: String, fileShape: [Int], dataType: FormatoDataType, fileIndexByPosition: [Int?]? = nil) {
        self.init(url: url, layout: .hdf5(datasetPath: datasetPath), fileShape: fileShape, dataType: dataType, fileIndexByPosition: fileIndexByPosition)
    }

    /// The HDF5 dataset's path; empty for a record file.
    package var datasetPath: String {
        if case .hdf5(let path) = layout { return path }
        return ""
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
    package var crystalMap: CrystalMap?
    package var patterns: EBSDPatternSource
    /// What the reader left out and why (a companion map that did not fit, a vendor warning), one sentence each, for the Open Files row.
    package var notes: [String]

    package init(format: EBSDFileFormat, manufacturer: String, version: String, scanGroup: String, scanGroups: [String], scanRows: Int, scanColumns: Int,
                 patternRows: Int, patternColumns: Int, dataType: FormatoDataType, stepY: Double, stepX: Double, scanUnit: String = "um",
                 detector: EBSDDetectorGeometry, staticBackground: FormatoArray? = nil, sem: EBSDSEMHeader = EBSDSEMHeader(),
                 crystalMap: CrystalMap? = nil, patterns: EBSDPatternSource, notes: [String] = []) {
        self.format = format; self.manufacturer = manufacturer; self.version = version; self.scanGroup = scanGroup; self.scanGroups = scanGroups
        self.scanRows = scanRows; self.scanColumns = scanColumns; self.patternRows = patternRows; self.patternColumns = patternColumns
        self.dataType = dataType; self.stepY = stepY; self.stepX = stepX; self.scanUnit = scanUnit; self.detector = detector
        self.staticBackground = staticBackground; self.sem = sem; self.crystalMap = crystalMap; self.patterns = patterns; self.notes = notes
    }

    package var patternCount: Int { scanRows * scanColumns }
    package var patternPixels: Int { patternRows * patternColumns }

    /// Why a scan of `scanRows` x `scanColumns` positions of `patternRows` x `patternColumns` patterns of `byteSize` bytes a pixel
    /// cannot be read, in one sentence; nil when it can: every side at least 1 and the whole scan's bytes countable in an Int, so
    /// no count or offset sized by them traps.
    package static func sizeRefusal(scanRows: Int, scanColumns: Int, patternRows: Int, patternColumns: Int, byteSize: Int) -> String? {
        guard scanRows >= 1, scanColumns >= 1 else {
            return "its scan is \(scanRows) x \(scanColumns) positions; a scan needs at least one row and one column."
        }
        guard patternRows >= 1, patternColumns >= 1 else {
            return "its patterns are \(patternRows) x \(patternColumns) pixels; a pattern needs at least one row and one column."
        }
        guard ReaderNumber.product([scanRows, scanColumns, patternRows, patternColumns, byteSize]) != nil else {
            return "its \(scanRows) x \(scanColumns) scan of \(patternRows) x \(patternColumns) patterns is more bytes than can be counted."
        }
        return nil
    }

    /// This dataset when its scan and pattern sizes can be read (`sizeRefusal`), else a refusal that names the file. `EBSDOpening.open`
    /// passes every reader's dataset through here before a pattern reader or a map is sized by it.
    package func validated() throws -> EBSDDataset {
        if let refusal = Self.sizeRefusal(scanRows: scanRows, scanColumns: scanColumns, patternRows: patternRows, patternColumns: patternColumns,
                                          byteSize: dataType.byteSize) {
            throw EBSDReadError(text: "\(patterns.url.lastPathComponent): \(refusal)")
        }
        return self
    }

    /// Every pattern in map order as one array of shape (scanRows, scanColumns, patternRows, patternColumns), zero where the file has
    /// none. One slab read of the dataset, then the reorder.
    package func allPatterns() throws -> FormatoArray {
        let reader = try EBSDPatternReader(self)
        return try reader.allPatterns()
    }
}

/// Reads patterns of one dataset by map position; holds the HDF5 dataset open (or the record file mapped) between calls (the live
/// pattern pane asks per cursor move).
package nonisolated final class EBSDPatternReader: @unchecked Sendable {
    package let dataset: EBSDDataset

    private enum Store {
        case hdf5(HDF5SlabReader)
        case records(Data, offset: Int, recordBytes: Int, patternOffset: Int)
    }
    private let store: Store

    package init(_ dataset: EBSDDataset) throws {
        self.dataset = dataset
        let source = dataset.patterns
        switch source.layout {
        case .hdf5(let path):
            do { store = .hdf5(try HDF5SlabReader(url: source.url, path: path)) } catch { throw EBSDReadError.wrap(error, file: source.url) }
        case .records(let offset, let recordBytes, let patternOffset):
            let data: Data
            do { data = try Data(contentsOf: source.url, options: .alwaysMapped) } catch {
                throw EBSDReadError(text: "\(source.url.lastPathComponent) could not be read: \((error as NSError).localizedDescription)")
            }
            let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
            guard recordBytes >= patternOffset + bytesPerPattern, offset + source.fileCount * recordBytes <= data.count else {
                throw EBSDReadError(text: "\(source.url.lastPathComponent) is shorter than its \(source.fileCount) patterns need (\(data.count) bytes).")
            }
            store = .records(data, offset: offset, recordBytes: recordBytes, patternOffset: patternOffset)
        }
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
        return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: bytes(fileIndex: index))
    }

    /// See `EBSDDataset.allPatterns`.
    package func allPatterns() throws -> FormatoArray {
        let source = dataset.patterns
        let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
        let total = dataset.patternCount
        let shape = [dataset.scanRows, dataset.scanColumns, dataset.patternRows, dataset.patternColumns]
        let fileCount = source.fileCount
        let whole: Data
        switch store {
        case .hdf5(let slabs):
            do { whole = try slabs.read(start: [Int](repeating: 0, count: source.fileShape.count), count: source.fileShape).bytes }
            catch { throw EBSDReadError.wrap(error, file: source.url) }
        case .records(_, _, let recordBytes, _):
            if recordBytes == bytesPerPattern, source.fileIndexByPosition == nil, fileCount == total {
                return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: bytes(fileIndex: 0, count: total))
            }
            var out = Data(count: total * bytesPerPattern)
            for position in 0..<total {
                let index: Int?
                if let order = source.fileIndexByPosition { index = position < order.count ? order[position] : nil }
                else { index = position < fileCount ? position : nil }
                guard let index, index < fileCount else { continue }
                out.replaceSubrange((position * bytesPerPattern)..<((position + 1) * bytesPerPattern), with: try bytes(fileIndex: index))
            }
            return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: out)
        }
        if source.fileIndexByPosition == nil, fileCount == total {
            return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: whole)
        }
        var out = Data(count: total * bytesPerPattern)
        whole.withUnsafeBytes { src in
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
        return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: out)
    }

    /// One scan row as the file stores it (the file order is the map order: `row(_:)` checks that), as one slab read (one slice of the
    /// mapped file for bare-pattern records, record by record otherwise).
    func rowSlab(row: Int) throws -> FormatoArray {
        let columns = dataset.scanColumns
        let shape = [columns, dataset.patternRows, dataset.patternColumns]
        switch store {
        case .hdf5(let slabs):
            let fileShape = dataset.patterns.fileShape
            let start: [Int], count: [Int]
            if fileShape.count == 4 {
                start = [row, 0, 0, 0]; count = [1, columns, fileShape[2], fileShape[3]]
            } else {
                start = [row * columns, 0, 0]; count = [columns, fileShape[1], fileShape[2]]
            }
            do { return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: try slabs.read(start: start, count: count).bytes) }
            catch { throw EBSDReadError.wrap(error, file: dataset.patterns.url) }
        case .records(_, _, let recordBytes, _):
            let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
            if recordBytes == bytesPerPattern {
                return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: bytes(fileIndex: row * columns, count: columns))
            }
            var out = Data()
            out.reserveCapacity(columns * bytesPerPattern)
            for column in 0..<columns { out.append(try bytes(fileIndex: row * columns + column)) }
            return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: out)
        }
    }

    /// The stored bytes of `count` patterns from file index `fileIndex` on: one slab for HDF5, the record's pixels for a record file
    /// (`count` records in one slice when the records are bare patterns).
    private func bytes(fileIndex: Int, count: Int = 1) throws -> Data {
        let bytesPerPattern = dataset.patternPixels * dataset.dataType.byteSize
        switch store {
        case .hdf5(let slabs):
            let fileShape = dataset.patterns.fileShape
            let start: [Int], extent: [Int]
            if fileShape.count == 4 {
                start = [fileIndex / fileShape[1], fileIndex % fileShape[1], 0, 0]; extent = [1, count, fileShape[2], fileShape[3]]
            } else {
                start = [fileIndex, 0, 0]; extent = [count, fileShape[1], fileShape[2]]
            }
            do { return try slabs.read(start: start, count: extent).bytes } catch { throw EBSDReadError.wrap(error, file: dataset.patterns.url) }
        case .records(let data, let offset, let recordBytes, let patternOffset):
            let first = data.startIndex + offset + fileIndex * recordBytes + patternOffset
            let length = recordBytes == bytesPerPattern ? count * bytesPerPattern : bytesPerPattern
            return data.subdata(in: first..<(first + length))
        }
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

/// The numbers a reader takes from a file's header, checked before anything is counted, sized or indexed by them: where Swift's
/// `Int(_:)` or `*` would trap on a broken or hostile header, these answer nil and the reader refuses the file in words.
package nonisolated enum ReaderNumber {
    /// A count or index the file stores as a float, as the whole number Python's `int()` makes of it (truncated toward zero), so a
    /// value that converts gives the same number as before; nil for NaN and infinity (where `int()` raises) and for a value beyond
    /// Int's range (where `Int(_:)` traps).
    package static func int(_ value: Double) -> Int? {
        Int(exactly: value.rounded(.towardZero))
    }

    /// The product of `factors` (1 for none), nil when it overflows an Int.
    package static func product(_ factors: [Int]) -> Int? {
        var total = 1
        for factor in factors {
            let (next, overflow) = total.multipliedReportingOverflow(by: factor)
            if overflow { return nil }
            total = next
        }
        return total
    }
}
