//
//  OxfordBinaryReader.swift
//  Role: read Oxford Instruments' binary pattern file (`.ebsp`) as kikuchipy 0.13.1 reads it
//        (kikuchipy/io/plugins/oxford_binary/_api.py, `OxfordBinaryFileReader`, GPL-3.0-or-later; the layout was given to
//        kikuchipy by Oxford Instruments). Port, step for step:
//          * the version: the first int64, negative in versions 1 and later; version 0 has no version word;
//          * the table of pattern start positions (int64 each) after the version word (plus one byte in versions 4 and later),
//            its length guessed from the first jump larger than twenty maximal patterns (kikuchipy's heuristic, kept so the
//            two readers agree on every file);
//          * the pattern header (int32: compressed flag, rows, columns, byte count; versions 5 and later put map column and row
//            before it), the pattern bytes (uint8 when the byte count is the pixel count, else uint16), and the footer (version
//            1: beam x and y as float64; later versions: a flag byte before each, the flags of the first pattern fixing the
//            layout of all);
//          * the map shape from the first, second and last footers (the step is the second x minus the first); a file that
//            lists only its unindexed patterns (a zero in the start table) or has no footer is a 1D list in pixels;
//          * patterns in map order: record i of the file is moved to the map position its start-table entry names.
//        The result is an `EBSDDataset` whose patterns stay in the file (`EBSDPatternSource.Layout.records`, one record per
//        pattern, read by map position through `fileIndexByPosition`); kikuchipy's `original_metadata` (beam and map positions,
//        the map's 1D ids, the file order) is `metadata(data:)`. Compressed patterns are refused by name, as in kikuchipy. The
//        parity test reads kikuchipy's own `patterns.ebsp` and the layouts kikuchipy's tests write (macTEMTests/Fixtures/sem/oxford,
//        from tools/parity/sem-readers/make_oxford_fixtures.py) bit-exact. The `.ctf` map next to the file is `OxfordOpening`'s.
//

import Foundation
import FormatoCore

package nonisolated enum OxfordBinaryReader {
    package enum Refusal: Error, Equatable {
        case tooShort
        case noPatternTable
        case compressed
        case patternShape(rows: Int, columns: Int, bytes: Int)
        case truncated(needed: Int, have: Int)
        case startTable(record: Int, of: Int)
        case step(Double)
        case mapShape(rows: Int, columns: Int, patterns: Int)

        package var reason: String {
            switch self {
            case .tooShort: "it is shorter than an .ebsp header."
            case .noPatternTable: "its pattern table has no end; it is not an .ebsp file as kikuchipy reads one."
            case .compressed: "its patterns are compressed; only uncompressed .ebsp patterns are read (kikuchipy reads the same)."
            case .patternShape(let r, let c, let b): "its first pattern is \(r) x \(c) pixels in \(b) bytes, neither 8 nor 16 bits a pixel."
            case .truncated(let needed, let have): "its patterns need \(needed) bytes but the file has \(have)."
            case .startTable(let record, let of): "its pattern table points at record \(record) of \(of)."
            case .step(let step): "its beam positions step by \(step) µm, which gives no map."
            case .mapShape(let r, let c, let n): "its beam positions span a \(r) x \(c) map but it holds \(n) patterns."
            }
        }
    }

    /// kikuchipy's `original_metadata` of the file: per pattern in map order, the record it came from, its 1D id in the map, and
    /// the beam position (µm) and map column and row the vendor wrote, when the file carries them.
    package struct Metadata: Sendable, Equatable {
        /// For each pattern in map order, its index in the file's own pattern list (the map's 1D index).
        package var map1DIDs: [Int]
        /// For each pattern in map order, the record it came from (0 is the first record after the header).
        package var fileOrder: [Int]
        /// Beam position per pattern, in µm, when the file footers carry it.
        package var beamX: [Double]?
        package var beamY: [Double]?
        /// Map column and row per pattern, when the pattern headers carry them (version 5 and later).
        package var mapX: [Int]?
        package var mapY: [Int]?
    }

    /// The scan the file at `url` holds, its patterns left in the file. The whole file is mapped, not read: the header and the first
    /// pattern's header and footer decide the layout, the footers of the first, second and last patterns the map.
    package static func read(url: URL) throws -> EBSDDataset {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try read(data: data, url: url)
    }

    package static func read(data: Data, url: URL) throws -> EBSDDataset {
        let layout = try Layout(data: data)
        return try layout.dataset(data: data, url: url)
    }

    package static func metadata(data: Data) throws -> Metadata {
        let layout = try Layout(data: data)
        return try layout.metadata(data: data)
    }

    /// The number of patterns the header's start table names (kikuchipy's `n_patterns`), without reading a pattern.
    package static func patternCountInHeader(data: Data) throws -> Int {
        try Layout(data: data).patternsInHeader
    }

    // MARK: - Layout

    /// kikuchipy's `OxfordBinaryFileReader.__init__`: everything the header and the first pattern say about the file.
    struct Layout {
        let version: Int
        let startTablePosition: Int
        let patternsInHeader: Int
        let patternStarts: [Int64]
        let headerSize: Int
        let patternRows: Int
        let patternColumns: Int
        let patternBytes: Int
        let sixteenBit: Bool
        let footerSize: Int
        let hasBeamX: Bool
        let hasBeamY: Bool
        /// Byte offset of beam x and y inside the footer (after the flag byte in versions 2 and later).
        let beamXOffset: Int?
        let beamYOffset: Int?

        var firstPatternPosition: Int { startTablePosition + patternsInHeader * 8 }
        var bytesPerRecord: Int { headerSize + patternBytes + footerSize }
        var presentCount: Int { patternStarts.filter { $0 != 0 }.count }
        var allPresent: Bool { presentCount == patternsInHeader }

        init(data: Data) throws {
            guard data.count >= 8 else { throw Refusal.tooShort }
            let word = data.int64(at: 0)
            // Locals first: a closure below cannot read a stored constant before every one is set.
            let version = word < 0 ? Int(-word) : 0
            let tablePosition = version == 0 ? 0 : (version > 3 ? 9 : 8)
            let headerSize = version < 5 ? 16 : 24
            self.version = version
            startTablePosition = tablePosition
            self.headerSize = headerSize

            // guess_number_of_patterns: the start table ends at the first jump larger than twenty maximal patterns.
            let minimumPixels = 1600
            let maximumRecords = data.count / (minimumPixels + headerSize)
            let available = max(0, (data.count - tablePosition) / 8)
            let assumed = (0..<min(maximumRecords, available)).map { data.int64(at: tablePosition + $0 * 8) }
            let maximumPatternSize = Int64(1024 * 1344 * 2 + headerSize)
            var jump: Int?
            if assumed.count > 1 {
                for i in 0..<(assumed.count - 1) where (assumed[i + 1] &- assumed[i]).magnitude > 20 * maximumPatternSize.magnitude {
                    jump = i; break
                }
            }
            guard let jump else { throw Refusal.noPatternTable }
            let count = version < 5 ? jump + 1 : jump
            guard count > 0 else { throw Refusal.noPatternTable }
            patternsInHeader = count
            patternStarts = (0..<count).map { data.int64(at: tablePosition + $0 * 8) }

            // The first pattern's header fixes shape, pixel type and footer layout.
            let first = tablePosition + count * 8
            guard first + headerSize <= data.count else { throw Refusal.tooShort }
            let fixed = first + (version < 5 ? 0 : 8)
            let compressed = data.int32(at: fixed)
            let rows = Int(data.int32(at: fixed + 4))
            let columns = Int(data.int32(at: fixed + 8))
            let bytes = Int(data.int32(at: fixed + 12))
            if compressed != 0 { throw Refusal.compressed }
            guard rows > 0, columns > 0, bytes == rows * columns || bytes == 2 * rows * columns else {
                throw Refusal.patternShape(rows: rows, columns: columns, bytes: bytes)
            }
            patternRows = rows
            patternColumns = columns
            patternBytes = bytes
            sixteenBit = bytes != rows * columns

            // get_pattern_footer_dtype at the first pattern.
            let footer = first + headerSize + bytes
            switch version {
            case 0:
                footerSize = 0; hasBeamX = false; hasBeamY = false; beamXOffset = nil; beamYOffset = nil
            case 1:
                footerSize = 16; hasBeamX = true; hasBeamY = true; beamXOffset = 0; beamYOffset = 8
            default:
                guard footer + 1 <= data.count else { throw Refusal.tooShort }
                var size = 2
                var cursor = footer
                let flagX = data[data.startIndex + cursor] != 0
                cursor += 1
                var xOffset: Int?
                var yOffset: Int?
                if flagX {
                    xOffset = 1
                    size += 8
                    cursor += 8
                }
                guard cursor + 1 <= data.count else { throw Refusal.tooShort }
                let flagY = data[data.startIndex + cursor] != 0
                cursor += 1
                if flagY {
                    yOffset = cursor - footer
                    size += 8
                }
                footerSize = size; hasBeamX = flagX; hasBeamY = flagY; beamXOffset = xOffset; beamYOffset = yOffset
            }
        }

        /// kikuchipy's `pattern_order`: the record each start-table entry points at (float division truncated to int).
        var patternOrder: [Int] {
            patternStarts.map { Int((Double($0) - Double(firstPatternPosition)) / Double(bytesPerRecord)) }
        }

        func recordStart(_ record: Int) -> Int { firstPatternPosition + record * bytesPerRecord }

        func beamX(data: Data, record: Int) -> Double? {
            guard let beamXOffset else { return nil }
            return data.float64(at: recordStart(record) + headerSize + patternBytes + beamXOffset)
        }

        func beamY(data: Data, record: Int) -> Double? {
            guard let beamYOffset else { return nil }
            return data.float64(at: recordStart(record) + headerSize + patternBytes + beamYOffset)
        }

        /// The present patterns in map order, and the map they make (or the 1D list in pixels).
        struct Order {
            var fileOrder: [Int]
            var map1DIDs: [Int]
            var scanRows: Int
            var scanColumns: Int
            var step: Double
            var scanUnit: String
        }

        func order(data: Data) throws -> Order {
            let present = patternStarts.map { $0 != 0 }
            let n = presentCount
            let needed = firstPatternPosition + n * bytesPerRecord
            guard needed <= data.count else { throw Refusal.truncated(needed: needed, have: data.count) }
            let order = patternOrder
            // The records in map order (`original_metadata.file_order`): the start table's entries of the present patterns.
            let fileOrder = zip(order, present).filter { $0.1 }.map { $0.0 }
            for record in fileOrder where record < 0 || record >= n { throw Refusal.startTable(record: record, of: n) }
            let map1DIDs = present.enumerated().filter { $0.element }.map { $0.offset }

            // The map shape (get_navigation_shape_and_step_size) or a 1D list.
            var found = Order(fileOrder: fileOrder, map1DIDs: map1DIDs, scanRows: 1, scanColumns: n, step: 1, scanUnit: "px")
            if allPresent, footerSize > 0, hasBeamX, hasBeamY, n >= 2 {
                let firstRecord = fileOrder[0], secondRecord = fileOrder[1], lastRecord = fileOrder[n - 1]
                let firstX = beamX(data: data, record: firstRecord)!, secondX = beamX(data: data, record: secondRecord)!
                let lastX = beamX(data: data, record: lastRecord)!
                let firstY = beamY(data: data, record: firstRecord)!, lastY = beamY(data: data, record: lastRecord)!
                let step = secondX - firstX
                guard step != 0, step.isFinite else { throw Refusal.step(step) }
                let rows = Int(abs((lastY / step).rounded(.toNearestOrEven) - (firstY / step).rounded(.toNearestOrEven))) + 1
                let columns = Int(abs((lastX / step).rounded(.toNearestOrEven) - (firstX / step).rounded(.toNearestOrEven))) + 1
                guard rows * columns == n else { throw Refusal.mapShape(rows: rows, columns: columns, patterns: n) }
                found.scanRows = rows; found.scanColumns = columns; found.step = step; found.scanUnit = "um"
            }
            return found
        }

        /// The dataset: patterns in map order through `fileIndexByPosition` (nil when the records are already in map order, as
        /// kikuchipy leaves a consecutive file unsorted), kikuchipy's default detector (projection centre 0.5, 0.5, 0.5 in the
        /// Bruker convention, sample tilt 70°) and no map of its own.
        func dataset(data: Data, url: URL) throws -> EBSDDataset {
            let found = try order(data: data)
            let n = found.fileOrder.count
            let consecutive = found.fileOrder == Array(0..<n)
            let source = EBSDPatternSource(url: url, layout: .records(offset: firstPatternPosition, recordBytes: bytesPerRecord, patternOffset: headerSize),
                                           fileShape: [n, patternRows, patternColumns], dataType: sixteenBit ? .uint16 : .uint8,
                                           fileIndexByPosition: consecutive ? nil : found.fileOrder.map { Optional($0) })
            let detector = EBSDDetectorGeometry(rows: patternRows, columns: patternColumns, projectionCenters: [SIMD3(0.5, 0.5, 0.5)])
            return EBSDDataset(format: .oxfordBinary, manufacturer: "oxford instruments", version: String(version), scanGroup: "", scanGroups: [],
                               scanRows: found.scanRows, scanColumns: found.scanColumns, patternRows: patternRows, patternColumns: patternColumns,
                               dataType: source.dataType, stepY: found.step, stepX: found.step, scanUnit: found.scanUnit, detector: detector, patterns: source)
        }

        func metadata(data: Data) throws -> Metadata {
            let found = try order(data: data)
            let fileOrder = found.fileOrder
            let beamXs: [Double]? = hasBeamX ? fileOrder.map { beamX(data: data, record: $0)! } : nil
            let beamYs: [Double]? = hasBeamY ? fileOrder.map { beamY(data: data, record: $0)! } : nil
            var mapX: [Int]?
            var mapY: [Int]?
            if version >= 5 {
                mapX = fileOrder.map { Int(data.int32(at: recordStart($0))) }
                mapY = fileOrder.map { Int(data.int32(at: recordStart($0) + 4)) }
            }
            return Metadata(map1DIDs: found.map1DIDs, fileOrder: fileOrder, beamX: beamXs, beamY: beamYs, mapX: mapX, mapY: mapY)
        }
    }
}

// MARK: - Little-endian words

fileprivate extension Data {
    /// Little-endian loads at an offset from the data's start (the file's byte positions), unaligned.
    func int64(at offset: Int) -> Int64 {
        Int64(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int64.self) })
    }

    func int32(at offset: Int) -> Int32 {
        Int32(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) })
    }


    func float64(at offset: Int) -> Double {
        Double(bitPattern: UInt64(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }))
    }
}
