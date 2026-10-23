//
//  VeloxImageReaderTests.swift
//  The Velox image reader (archive: roadmap-registrations-2026-10-15.md V1-3a) on small Velox-shaped files whose truth is the numbers planted by
//  tools/parity/velox-image-parity/make_fixture.py (Fixtures/velox-*.emd, each under 64 KiB; velox.truth.json carries their
//  sha256). The parity against RosettaSciIO and h5py is tools/parity/velox-image-parity; these pin the reader's own rules
//  without Python — the object rule, the calibration, the frame, the refusals — and that the XCTest host finds the
//  HDF5 library the app embeds. The files are opened through the app's own entry point, `ImageOpening.openNow`.
//

import ImagoCore
import CryptoKit
import MachO
import XCTest
import FormatoHDF5
import TEMCore

nonisolated final class VeloxImageReaderTests: XCTestCase {

    // MARK: Fixtures

    /// A planted file: from the test bundle (the app host copies Fixtures/ flat into its Resources), else from Fixtures/
    /// beside this source, which is where a bare `swift test` finds it.
    private func fixture(_ name: String, _ ext: String = "emd") throws -> String {
        if let url = Bundle(for: VeloxImageReaderTests.self).url(forResource: name, withExtension: ext) { return url.path }
        let beside = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).\(ext)")
        return try XCTUnwrap(FileManager.default.fileExists(atPath: beside.path) ? beside.path : nil,
                             "\(name).\(ext) is in neither the test bundle nor Fixtures/")
    }

    private func grid(_ rows: Int, _ columns: Int, _ value: (Int, Int) -> Int) -> [Float] {
        (0..<rows).flatMap { r in (0..<columns).map { c in Float(value(r, c)) } }
    }

    private func refusal(_ name: String) throws -> ImageOpening.Refusal {
        let path = try fixture(name)
        do {
            let image = try ImageOpening.openNow(path: path)
            XCTFail("\(name) opened as \(image.source); it must be refused")
        } catch let refusal as ImageOpening.Refusal {
            return refusal
        }
        struct OpenedNotRefused: Error {}
        throw OpenedNotRefused()
    }

    // MARK: The object rule

    /// velox-haadf-last holds, in key order: an EDX map and a second one (float32, no DetectorIndex), a DF4 image, then the
    /// HAADF. The first two are not candidates; the DF4 is, and comes before the HAADF, which still opens.
    func testTheHAADFOpensThoughItIsLastInKeyOrder() throws {
        let image = try ImageOpening.openNow(path: try fixture("velox-haadf-last"))
        XCTAssertEqual(image.source, "Data/Image/33d40123456789abcdef0123456789ab · HAADF")
        XCTAssertEqual([image.width, image.height], [6, 4], "6 columns, 4 rows")
        XCTAssertEqual(image.pixels, grid(4, 6) { r, c in 100 * r + c }, "the HAADF's pixels, not the DF4's (7000 + …)")
        XCTAssertEqual(image.x, AxisCalibration(scale: 1e-9, unit: "m", origin: 0))
        XCTAssertEqual([image.x?.origin.sign, image.y?.origin.sign], [.plus, .plus],
                       "no Offset: the origin is +0; −0 would print “origin -0 px” in the Info tab")
        XCTAssertEqual(image.voltage, 200_000)
        XCTAssertEqual(image.notes, [], "one frame: no frame label")
        XCTAssertEqual(image.fileName, "velox-haadf-last.emd")
    }

    /// velox-maps-only holds two EDX maps: one without a DetectorIndex, one whose index names an AnalyticalDetector.
    /// Neither is an image: the file is refused, naming what it holds.
    func testAFileOfOnlyEDXMapsIsRefusedAsNoImage() throws {
        let refused = try refusal("velox-maps-only")
        XCTAssertEqual(refused, .velox(file: "velox-maps-only.emd",
                                       .noImage("SuperXG1 5 × 3, no detector index; SuperXG2 5 × 3, an EDS map")))
        XCTAssertTrue(refused.localizedDescription.hasPrefix("velox-maps-only.emd is not read: it holds no image macTEM opens ("),
                      refused.localizedDescription)
    }

    // MARK: Calibration

    /// velox-aniso: 5 columns by 3 rows, PixelSize 2e-10 × 8e-10, PixelUnitX "m" and PixelUnitY "1/m", Offset (-1e-9, 1.6e-9).
    /// Each axis keeps its own size, unit and origin = -Offset / PixelSize (5 and -2 pixels): a swapped size, a swapped
    /// offset, a flipped sign, an offset not divided by the size, or a y unit read from X each change one of them.
    func testAnisotropicCalibrationIsReadPerAxisAndTheOriginIsMinusOffsetOverSize() throws {
        let image = try ImageOpening.openNow(path: try fixture("velox-aniso"))
        XCTAssertEqual([image.width, image.height], [5, 3])
        XCTAssertEqual(image.pixels, grid(3, 5) { r, c in 10 * r + c + 1 })
        let x = try XCTUnwrap(image.x), y = try XCTUnwrap(image.y)
        XCTAssertEqual(x.scale, 2e-10)
        XCTAssertEqual(y.scale, 8e-10)
        XCTAssertEqual(x.unit, "m")
        XCTAssertEqual(y.unit, "1/m", "the y unit is PixelUnitY's (the DEVIATION from RosettaSciIO, which reads X's for both)")
        XCTAssertEqual(x.origin, 5, accuracy: 1e-9)
        XCTAssertEqual(y.origin, -2, accuracy: 1e-9)
        XCTAssertEqual(image.voltage, 300_000)
    }

    // MARK: The frame

    /// velox-frames: 3 frames, every pixel different in each. A stack opens its first frame labelled "frame 1 of 3" (never
    /// a sum); `read(path:frame:)`, the seam V1-3c-ii uses, reads the others, each labelled; a frame beyond the stack is
    /// refused by name; a single-frame file carries no label.
    func testAStackOpensFrameOneOfNAndASingleFrameCarriesNoLabel() throws {
        func frame(_ f: Int) -> [Float] { grid(3, 4) { r, c in 1000 * f + 10 * r + c + 1 } }
        let path = try fixture("velox-frames")
        let image = try ImageOpening.openNow(path: path)
        XCTAssertEqual(image.notes, ["frame 1 of 3"])
        XCTAssertEqual(image.pixels, frame(0))
        for f in 0..<3 {
            let read = try VeloxImageReader.read(path: path, frame: f)
            XCTAssertEqual(read.pixels, frame(f), "frame \(f + 1)")
            XCTAssertEqual(read.notes, ["frame \(f + 1) of 3"])
            XCTAssertEqual(read.x, image.x, "a frame carries the stack's calibration")
        }
        for beyond in [3, -1] {
            XCTAssertThrowsError(try VeloxImageReader.read(path: path, frame: beyond), "frame \(beyond) of 3") { error in
                guard case .unreadable = error as? VeloxImageReader.Refusal else { return XCTFail("refused as \(error)") }
            }
        }
        XCTAssertEqual(try ImageOpening.openNow(path: try fixture("velox-haadf-last")).notes, [])
    }

    // MARK: Stored types

    /// velox-int16-negative: two int16 frames holding -32768, -1, 32767 and other values that only the right sign gives.
    func testInt16NegativeValuesAreExact() throws {
        let f0: [Float] = [-1, -32768, 32767, 300, 0, 17, -300, 42, -7, 1000, -12345, 256, -256, 5, -99]
        let f1: [Float] = [2, 32767, -32768, -300, 123, -18, 301, -43, 8, -1000, 12346, -257, 257, -6, 100]
        let path = try fixture("velox-int16-negative")
        let image = try ImageOpening.openNow(path: path)
        XCTAssertEqual([image.width, image.height], [5, 3])
        XCTAssertEqual(image.pixels, f0)
        XCTAssertEqual(try VeloxImageReader.read(path: path, frame: 1).pixels, f1)
        XCTAssertEqual(image.notes, ["frame 1 of 2"], "int16 is exact in Float32: no rounding note")
        XCTAssertEqual(image.x?.origin ?? .nan, -2.8, accuracy: 1e-9, "Offset 7e-9 over a 2.5e-9 pixel")
        XCTAssertEqual(image.y?.origin ?? .nan, 0.75, accuracy: 1e-9, "Offset -3e-9 over a 4e-9 pixel")
    }

    // MARK: Refusal

    /// velox-berkeley is a Berkeley (NCEM) EMD, which shares the `.emd` extension: HDF5 without a Velox `Version`.
    func testANonVeloxHDF5IsRefusedAsNotVelox() throws {
        guard case .velox(let file, .notVelox) = try refusal("velox-berkeley") else {
            return XCTFail("a Berkeley EMD must be refused as not Velox")
        }
        XCTAssertEqual(file, "velox-berkeley.emd")
    }

    /// velox-bad-metadata: an image whose Metadata column is not JSON. A damaged file is refused by name, as `unreadable`:
    /// a raw JSON error is not a refusal the app can word.
    func testADamagedMetadataColumnIsRefusedAsUnreadable() throws {
        let path = try fixture("velox-bad-metadata")
        XCTAssertThrowsError(try ImageOpening.openNow(path: path)) { error in
            guard case .velox(let file, .unreadable)? = error as? ImageOpening.Refusal else {
                return XCTFail("refused as \(type(of: error)): \(error)")
            }
            XCTAssertEqual(file, "velox-bad-metadata.emd")
        }
    }

    // MARK: The library

    /// The XCTest host is the app, so `Bundle.main` is macTEM.app. The app embeds no libhdf5 of its own (ADR 026): the one
    /// it carries is FormatoKit's, the FormatoLibHDF5 framework in `Contents/Frameworks` (FormatoKit 0.4.0). With no override the
    /// reader's own lookup must load THAT one: the file opens, and the one libhdf5 the process has loaded is the framework's.
    /// A bare `swift test` has no such host and cannot run this.
    func testTheTestHostFindsTheAppsBundledHDF5Library() throws {
        XCTAssertNil(getenv("FORMATO_HDF5_PATH"), "the variable overrides the lookup this test is about: run without it")
        let bundled = try XCTUnwrap(FormatoHDF5Library.bundledLibraryPath, "the host does not carry FormatoKit's FormatoLibHDF5 framework")
        let image = try ImageOpening.openNow(path: try fixture("velox-haadf-last"))
        XCTAssertEqual(image.width, 6)
        let loaded = (0..<_dyld_image_count()).compactMap { index in _dyld_get_image_name(index).map { String(cString: $0) } }
            .filter { $0.hasSuffix("/FormatoLibHDF5") }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(loaded, [URL(fileURLWithPath: bundled).resolvingSymlinksInPath().path],
                       "the libhdf5 the process loaded is not the host's bundled copy")
        let all = (0..<_dyld_image_count()).compactMap { index in _dyld_get_image_name(index).map { String(cString: $0) } }
        XCTAssertFalse(all.contains { $0.hasSuffix("/libhdf5.dylib") }, "a bare libhdf5.dylib is loaded: the lookup did not stop at the framework")
    }

    // MARK: The files

    /// The fixtures are the bytes the truth was written from: a regenerated file that moved a number fails here even when
    /// the tests above were edited to follow it (`tools/parity/velox-image-parity/run.sh --make-fixture`).
    func testTheFixturesAreTheOnesTheTruthWasWrittenFrom() throws {
        struct Truth: Decodable {
            struct Case: Decodable {
                let file: String
                let sha256: String
                let bytes: Int
            }
            let cases: [Case]
        }
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: URL(fileURLWithPath: try fixture("velox.truth", "json"))))
        XCTAssertEqual(truth.cases.map(\.file).sorted(),
                       ["velox-aniso.emd", "velox-bad-metadata.emd", "velox-berkeley.emd", "velox-frames.emd",
                        "velox-haadf-last.emd", "velox-int16-negative.emd", "velox-maps-only.emd"])
        for c in truth.cases {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: try fixture(String(c.file.dropLast(4)))))
            XCTAssertEqual(bytes.count, c.bytes, c.file)
            XCTAssertLessThan(bytes.count, 64 * 1024, "\(c.file) is over 64 KiB")
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), c.sha256,
                           "\(c.file) changed without velox.truth.json being regenerated")
        }
    }
}
