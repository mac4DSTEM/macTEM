//
//  EBSDMeanPassTests.swift
//  A file without a static background is read once at open (`VirtualBSEImaging.imagesAndPatternSum`,
//  `PatternPipeline.meanBackground(sum:of:)`, TEMCore; `EBSDSession`): the map's pass sums the patterns for the scan's mean as it reads
//  them, in the mean pass's own order, so the mean that lands with the map is that pass's mean byte for byte. The mean shows as busy,
//  and Stop ends it, in the map's pass or in its own.
//  Red before the change: binding the demo read the scan twice (the map's pass and a second pass for the mean), `isBusy` left the mean
//  out, and Stop never ended it.
//

import XCTest
import Synchronization
import FormatoCore
import TEMCore
import TEMSession

nonisolated final class EBSDMeanPassTests: XCTestCase {

    private func appended(_ values: [UInt16]) -> Data {
        var data = Data()
        for v in values { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func assertSameArray(_ a: FormatoArray, _ b: FormatoArray, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.dataType, b.dataType, message, file: file, line: line)
        XCTAssertEqual(a.shape, b.shape, message, file: file, line: line)
        XCTAssertEqual(a.bytes, b.bytes, message, file: file, line: line)
    }

    /// The pass's pattern sum on a planted uint16 scan: its mean is `meanBackground`'s byte for byte, the images are `images`', no sum
    /// is made unless asked, and a sum of the wrong length is refused.
    func testThePassSumsThePatternsAsTheMeanPassDoes() throws {
        let rows = 5, columns = 7, side = 6
        let raw = (0..<(rows * columns * side * side)).map { UInt16(truncatingIfNeeded: ($0 * 7919 + ($0 / 36) * 977) % 65536) }
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: rows,
                                  scanColumns: columns, patternRows: side, patternColumns: side, dataType: .uint16, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: []),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                              fileShape: [rows, columns, side, side], dataType: .uint16))
        let access = try EBSDMemoryPatterns(dataset: dataset, bytes: appended(raw))
        let rects = [DetectorRect(top: 0, bottom: side, left: 0, right: side)] + VirtualBSEGrid(3).rects(patternRows: side, patternColumns: side)

        let pass = try XCTUnwrap(VirtualBSEImaging.imagesAndPatternSum(access, rects: rects, sumsPatterns: true))
        XCTAssertEqual(pass.images, try VirtualBSEImaging.images(access, rects: rects), "the images do not move")
        let sum = try XCTUnwrap(pass.patternSum)
        XCTAssertEqual(sum.count, side * side)
        let reference = try XCTUnwrap(PatternPipeline.meanBackground(access))
        let mean = try PatternPipeline.meanBackground(sum: sum, of: dataset)
        assertSameArray(mean, reference, "the pass's mean is the mean pass's")

        XCTAssertNil(try XCTUnwrap(VirtualBSEImaging.imagesAndPatternSum(access, rects: rects, sumsPatterns: false)).patternSum)
        XCTAssertThrowsError(try PatternPipeline.meanBackground(sum: Array(sum.dropLast()), of: dataset))
    }

    /// The demo carries no static background: opened, it is read once for the map and the mean together, and the mean that lands is the
    /// mean pass's, byte for byte.
    @MainActor func testAFileWithoutABackgroundIsReadOnceAtOpen() async throws {
        let demo = try DemoDocuments.ebsd()
        XCTAssertNil(demo.dataset.staticBackground)
        let counted = RowCountingPatterns(base: demo.access)
        let session = EBSDSession()
        let firstPattern = session.bind(EBSDSession.Document(fileName: demo.fileName, url: nil, dataset: demo.dataset, access: counted))
        XCTAssertTrue(session.isComputingMean)
        XCTAssertTrue(session.isBusy)
        await firstPattern.value
        for _ in 0..<6000 where session.isMapping || session.isComputingMean { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(session.isBusy)
        XCTAssertNotNil(session.meanIntensities)
        XCTAssertEqual(counted.rowReads, demo.dataset.scanRows, "one pass over the scan for the map and the mean")

        let mean = try XCTUnwrap(session.scanMeanBackground)
        let reference = try XCTUnwrap(PatternPipeline.meanBackground(demo.access))
        assertSameArray(mean, reference, "the mean that landed with the map")
        XCTAssertNil(session.processingRefusal)
        XCTAssertTrue(session.canProcess)
    }

    /// Stop while the mean rides on the map's pass: the room is idle at once, the pass reads no row after Stop and the mean stays
    /// unmade (Process says so). An edited stage sums it in its own pass, busy too, which Stop also ends without a failure; the next edit
    /// sums it again and it lands.
    @MainActor func testStopEndsTheMeanPass() async throws {
        let demo = try DemoDocuments.ebsd()
        let gated = RowCountingPatterns(base: demo.access)
        defer { gated.release() }
        let session = EBSDSession()
        var events: [String] = []
        session.onEvent = { events.append($0) }

        // In the map's pass: held inside its first row, stopped.
        gated.hold()
        let firstPattern = session.bind(EBSDSession.Document(fileName: demo.fileName, url: nil, dataset: demo.dataset, access: gated))
        for _ in 0..<2000 where gated.rowReads == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gated.rowReads, 1, "the map's pass is inside its first row, and nothing else reads the scan")
        XCTAssertTrue(session.isComputingMean)
        session.stop()
        XCTAssertFalse(session.isComputingMean)
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(events.last, "Stopped the scan's mean pattern")
        XCTAssertEqual(session.processingRefusal?.sentence, "The scan's mean is not computed yet.")
        gated.release()
        await firstPattern.value

        // In its own pass: started by an edited stage, held inside its first row, stopped.
        let before = gated.rowReads
        gated.hold()
        session.editPipeline { $0.dynamicStage.std = 12 }
        XCTAssertTrue(session.isComputingMean)
        XCTAssertTrue(session.isBusy, "the mean's own pass is busy")
        for _ in 0..<2000 where gated.rowReads == before { try await Task.sleep(for: .milliseconds(5)) }
        session.stop()
        XCTAssertFalse(session.isComputingMean)
        XCTAssertFalse(session.isBusy)
        gated.release()

        // The next edit sums it again; it lands, the stopped passes having read no row after Stop.
        session.editPipeline { $0.dynamicStage.std = 10 }
        XCTAssertTrue(session.isComputingMean)
        for _ in 0..<6000 where session.isComputingMean { try await Task.sleep(for: .milliseconds(5)) }
        let mean = try XCTUnwrap(session.scanMeanBackground)
        let reference = try XCTUnwrap(PatternPipeline.meanBackground(demo.access))
        assertSameArray(mean, reference, "the mean summed after Stop")
        XCTAssertEqual(gated.rowReads, 2 + demo.dataset.scanRows, "one row for each stopped pass, then the whole scan once")
        XCTAssertFalse(events.contains { $0.hasPrefix("The scan's mean pattern could not be computed") }, "\(events)")
        XCTAssertNil(session.processingRefusal)
    }

    /// Float32 patterns cannot be summed into a mean background: the mean's own pass says so with the reason, not only that it could
    /// not be computed. Red before: the reason was dropped and the line read "The scan's mean pattern could not be computed."
    @MainActor func testAMeanThatCannotBeComputedSaysWhy() async throws {
        let rows = 2, columns = 3, side = 10
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: rows,
                                  scanColumns: columns, patternRows: side, patternColumns: side, dataType: .float32, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: []),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                              fileShape: [rows, columns, side, side], dataType: .float32))
        let access = try EBSDMemoryPatterns(dataset: dataset, bytes: Data(count: rows * columns * side * side * 4))
        let session = EBSDSession()
        var events: [String] = []
        session.onEvent = { events.append($0) }
        let firstPattern = session.bind(EBSDSession.Document(fileName: "planted.h5", url: nil, dataset: dataset, access: access))
        await firstPattern.value
        for _ in 0..<6000 where session.isMapping || session.isComputingMean { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(session.isComputingMean)
        XCTAssertNil(session.scanMeanBackground)
        let line = events.first { $0.hasPrefix("The scan's mean pattern could not be computed") }
        XCTAssertEqual(line, "The scan's mean pattern could not be computed: Processing reads 8 and 16 bit unsigned patterns; these are float32.",
                       "\(events)")
    }
}

/// The demo's patterns with every scan-row read counted; the first row read after `hold()` waits until `release()`, so a pass stays
/// inside that row. Its state is behind the mutex and the semaphore, hence unchecked.
private nonisolated final class RowCountingPatterns: EBSDPatternAccess, @unchecked Sendable {
    private let base: any EBSDPatternAccess
    private let state: Mutex<(armed: Bool, reads: Int)>
    private let gate: DispatchSemaphore

    init(base: any EBSDPatternAccess) {
        self.base = base
        state = Mutex((armed: false, reads: 0))
        gate = DispatchSemaphore(value: 0)
    }

    var dataset: EBSDDataset { base.dataset }

    func pattern(row: Int, column: Int) throws -> FormatoArray { try base.pattern(row: row, column: column) }

    func row(_ row: Int) throws -> FormatoArray {
        let waits = state.withLock { s -> Bool in
            s.reads += 1
            let armed = s.armed
            s.armed = false
            return armed
        }
        if waits { gate.wait() }
        return try base.row(row)
    }

    /// Arms the gate for the next row read.
    func hold() {
        state.withLock { $0.armed = true }
    }

    /// Lets a held read go on (a spare release is harmless: nothing waits once the gate is disarmed).
    func release() {
        _ = gate.signal()
    }

    var rowReads: Int { state.withLock { $0.reads } }
}
