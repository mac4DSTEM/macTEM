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
//        Compressed patterns are refused by name, as in kikuchipy. The parity test reads kikuchipy's own `patterns.ebsp` and
//        the layouts kikuchipy's tests write (macTEMTests/Fixtures/sem/oxford, from tools/parity/sem-readers/make_oxford_fixtures.py)
//        bit-exact.
//

import Foundation

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

    package static func read(path: String) throws -> EBSDPatternSet {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        return try read(data: data)
    }

    package static func read(data: Data) throws -> EBSDPatternSet {
        let layout = try Layout(data: data)
        return try layout.patterns(data: data)
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
            version = word < 0 ? Int(-word) : 0
            startTablePosition = version == 0 ? 0 : (version > 3 ? 9 : 8)
            headerSize = version < 5 ? 16 : 24

            // guess_number_of_patterns: the start table ends at the first jump larger than twenty maximal patterns.
            let minimumPixels = 1600
            let maximumRecords = data.count / (minimumPixels + headerSize)
            let available = max(0, (data.count - startTablePosition) / 8)
            let assumed = (0..<min(maximumRecords, available)).map { data.int64(at: startTablePosition + $0 * 8) }
            let maximumPatternSize = Int64(1024 * 1344 * 2 + headerSize)
            var jump: Int?
            if assumed.count > 1 {
                for i in 0..<(assumed.count - 1) where (assumed[i + 1] &- assumed[i]).magnitude > 20 * maximumPatternSize.magnitude {
                    jump = i; break
                }
            }
            guard let jump else { throw Refusal.noPatternTable }
            patternsInHeader = version < 5 ? jump + 1 : jump
            guard patternsInHeader > 0 else { throw Refusal.noPatternTable }
            patternStarts = (0..<patternsInHeader).map { data.int64(at: startTablePosition + $0 * 8) }

            // The first pattern's header fixes shape, pixel type and footer layout.
            let first = startTablePosition + patternsInHeader * 8
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

        func patterns(data: Data) throws -> EBSDPatternSet {
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
            var navigationShape = [n]
            var stepSizes = [1.0]
            var scanUnit = "px"
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
                navigationShape = [rows, columns]
                stepSizes = [step, step]
                scanUnit = "um"
            }

            // The pixels, record by record in map order (kikuchipy sorts the memmap by pattern_order when it is not already
            // consecutive and every pattern is present; a partial file keeps file order, which is what fileOrder lists too).
            let pixelCount = patternRows * patternColumns
            let pixels: EBSDPatternSet.Pixels
            if sixteenBit {
                var out = [UInt16]()
                out.reserveCapacity(n * pixelCount)
                for record in fileOrder {
                    let start = recordStart(record) + headerSize
                    for p in 0..<pixelCount { out.append(data.uint16(at: start + 2 * p)) }
                }
                pixels = .uint16(out)
            } else {
                var out = [UInt8]()
                out.reserveCapacity(n * pixelCount)
                for record in fileOrder {
                    let start = data.startIndex + recordStart(record) + headerSize
                    out.append(contentsOf: data[start..<(start + pixelCount)])
                }
                pixels = .uint8(out)
            }

            let beamXs: [Double]? = hasBeamX ? fileOrder.map { beamX(data: data, record: $0)! } : nil
            let beamYs: [Double]? = hasBeamY ? fileOrder.map { beamY(data: data, record: $0)! } : nil
            var mapX: [Int]?
            var mapY: [Int]?
            if version >= 5 {
                mapX = fileOrder.map { Int(data.int32(at: recordStart($0))) }
                mapY = fileOrder.map { Int(data.int32(at: recordStart($0) + 4)) }
            }
            return EBSDPatternSet(navigationShape: navigationShape, patternShape: [patternRows, patternColumns], pixels: pixels,
                                  stepSizes: stepSizes, scanUnit: scanUnit, map1DIDs: map1DIDs, fileOrder: fileOrder,
                                  beamX: beamXs, beamY: beamYs, mapX: mapX, mapY: mapY)
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

    func uint16(at offset: Int) -> UInt16 {
        UInt16(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) })
    }

    func float64(at offset: Int) -> Double {
        Double(bitPattern: UInt64(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }))
    }
}
