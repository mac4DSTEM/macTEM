//
//  SEMEDSMapReaderTests.swift
//  The SEM-EDS map readers (Bruker `.bcf`/`.spx`, EDAX `.spd`/`.lsd`/`.spc`, JEOL `.pts`/`.eds`/`.img`/`.asw`) against RosettaSciIO
//  0.15.0: every m7/read-* bundle of tools/parity/sem (emit.py, `_eds_bundle`) holds what rsciio returns for one of its own test
//  files, signal by signal: kind, shape, dtype, axes, the mapped metadata, and the data exact (a spectrum's counts; a spectrum
//  image's nonzero flat indices and counts by sha256, its summed spectrum, its per-pixel totals; an image's pixels by sha256). A
//  file rsciio refuses is refused here. Then the doors: a .bcf, .spd, .pts and .spx open in the EDS room with their energy axis,
//  scan image and metadata; a JEOL .img opens in the Image room; FileRouting sends each to its room.
//  Mutations each test must go red under: a channel or pixel off by one in any unpacker; the 12-bit nibble order swapped; a gain
//  dropped from a packed run; the incomplete JEOL frame kept; a float32 header value rounded; the x axis of a .bcf map given DX.
//

import CryptoKit
import Foundation
import ImagoCore
import SpectroCore
import TEMCore
import XCTest

nonisolated final class SEMEDSMapReaderTests: XCTestCase {

    static func cases() throws -> [String] {
        try SEMParityReference.allCases().filter { $0.hasPrefix("m7/read-") }
    }

    static func sha256(int64 values: some Sequence<Int64>) -> String {
        var h = SHA256()
        var buffer: [UInt8] = []
        buffer.reserveCapacity(1 << 16)
        for v in values {
            let le = UInt64(bitPattern: v).littleEndian
            withUnsafeBytes(of: le) { buffer.append(contentsOf: $0) }
            if buffer.count >= 1 << 16 { h.update(data: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        h.update(data: buffer)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(pixels: [UInt32], dtype: String) throws -> String {
        var bytes: [UInt8] = []
        switch dtype {
        case "uint8": bytes = pixels.map { UInt8(truncatingIfNeeded: $0) }
        case "uint16": for p in pixels { bytes.append(UInt8(p & 0xFF)); bytes.append(UInt8(p >> 8 & 0xFF)) }
        case "uint32": for p in pixels { withUnsafeBytes(of: p.littleEndian) { bytes.append(contentsOf: $0) } }
        default: throw SEMParityReference.Failure("image dtype \(dtype)")
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The reference axes decoded by `JSONDecoder`, which parses each float to the nearest Double; `JSONSerialization` rounds some
    /// 17-digit floats (0.014235896058380604, a float32 pixel size widened) one unit in the last place off.
    nonisolated struct Axis: Decodable, Equatable { let name: String; let size: Int; let scale: Double; let offset: Double; let units: String? }
    nonisolated struct AxesManifest: Decodable {
        nonisolated struct Values: Decodable { nonisolated struct Signal: Decodable { let axes: [Axis] }; let signals: [Signal]? }
        let values: Values
    }

    static func referenceAxes(_ name: String) throws -> [[Axis]] {
        let url = SEMParityReference.referencesRoot.appendingPathComponent(name).appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(AxesManifest.self, from: Data(contentsOf: url)).values.signals?.map(\.axes) ?? []
    }

    /// Every committed m7 reader bundle, read by the Swift port and compared field by field.
    func testEveryReaderBundleReadsAsRosettaSciIOReadsIt() throws {
        let names = try Self.cases()
        XCTAssertGreaterThanOrEqual(names.count, 25, "the m7 reader bundles are committed")
        var compared = 0
        for name in names {
            let ref = try SEMParityReference.load(name)
            let url = try XCTUnwrap(ref.inputURL(), name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }   // a sem-data input not fetched
            compared += 1
            let signals = ref.values["signals"] as? [[String: Any]] ?? []
            if let refusal = ref.values["refusal"] as? String {
                XCTAssertThrowsError(try SEMEDSOpening.read(url: url), "\(name): rsciio refuses it (\(refusal))") { error in
                    XCTAssertFalse((error as? SEMEDSReadError)?.text.isEmpty ?? true, "\(name): a sentence")
                }
                continue
            }
            let file: SEMEDSFile
            do { file = try SEMEDSOpening.read(url: url) } catch {
                XCTFail("\(name): \(error.localizedDescription)"); continue
            }
            XCTAssertEqual(file.signals.count, signals.count, "\(name): signal count")
            for (i, (signal, expected)) in zip(file.signals, signals).enumerated() {
                try check(signal, expected, index: i, ref: ref, name: name)
            }
        }
        XCTAssertGreaterThanOrEqual(compared, 23, "the committed fixtures cover every reader")
    }

    func check(_ signal: SEMEDSSignal, _ e: [String: Any], index i: Int, ref: SEMParityReference, name: String) throws {
        let label = "\(name) signal \(i)"
        let kind: String, shape: [Int], dtype: String, axes: [SEMEDSAxis], md: SEMEDSMetadata
        switch signal {
        case .spectrumImage(let s): kind = "spectrum_image"; shape = s.shape; dtype = s.dtype; axes = s.axes; md = s.metadata
        case .spectrum(let s): kind = "spectrum"; shape = [s.counts.count]; dtype = s.dtype; axes = [s.axis]; md = s.metadata
        case .image(let s): kind = "image"; shape = [s.height, s.width]; dtype = s.dtype; axes = s.axes; md = s.metadata
        }
        XCTAssertEqual(kind, e["kind"] as? String, "\(label): kind")
        XCTAssertEqual(shape, e["shape"] as? [Int], "\(label): shape")
        XCTAssertEqual(dtype, e["dtype"] as? String, "\(label): dtype")
        let expectedAxes = try Self.referenceAxes(name)
        XCTAssertEqual(axes.map { Axis(name: $0.name, size: $0.size, scale: $0.scale, offset: $0.offset, units: $0.units) },
                       expectedAxes.indices.contains(i) ? expectedAxes[i] : [], "\(label): axes")
        XCTAssertEqual(NSDictionary(dictionary: md.flattened), NSDictionary(dictionary: e["metadata"] as? [String: Any] ?? [:]),
                       "\(label): metadata")
        switch signal {
        case .spectrum(let s):
            SEMAssertParity(s.counts.map(Double.init), try ref.array("signal\(i)_counts"))
        case .spectrumImage(let s):
            let cube = s.cube
            let nz = try XCTUnwrap(ref.values["signal\(i)_nonzero"] as? [String: Any], label)
            XCTAssertEqual(cube.counts.count, nz["count"] as? Int, "\(label): nonzero count")
            var flat: [Int64] = []
            flat.reserveCapacity(cube.counts.count)
            for p in 0..<(cube.ny * cube.nx) {
                for k in cube.rowOffsets[p]..<cube.rowOffsets[p + 1] { flat.append(Int64(p * cube.channels + Int(cube.channelIndex[k]))) }
            }
            XCTAssertEqual(Self.sha256(int64: flat), nz["index_sha256"] as? String, "\(label): where the counts are")
            XCTAssertEqual(Self.sha256(int64: cube.counts.map { Int64($0) }), nz["value_sha256"] as? String, "\(label): the counts")
            SEMAssertParity(cube.sum(mask: nil).map { Double($0) }, try ref.array("signal\(i)_sum_spectrum"))
            let totals = try XCTUnwrap(ref.values["signal\(i)_pixel_totals"] as? [String: Any], label)
            XCTAssertEqual(Self.sha256(int64: cube.pixelTotals()), totals["sha256"] as? String, "\(label): per-pixel totals")
        case .image(let s):
            let fp = try XCTUnwrap(ref.values["signal\(i)_pixels"] as? [String: Any], label)
            XCTAssertEqual(try Self.sha256(pixels: s.pixels, dtype: s.dtype), fp["sha256"] as? String, "\(label): pixels")
            SEMAssertParity(s.pixels.reduce(0.0) { $0 + Double($1) }, ref, scalar: "signal\(i)_pixel_sum")
        }
    }

    // MARK: - The doors

    static func fixture(_ path: String) -> URL { SEMParityReference.fixturesRoot.appendingPathComponent("rsciio/" + path) }

    /// A .bcf opens in the EDS room as its 2048-channel map with the image recorded on its grid as the scan image, keV axis in eV,
    /// pixel size in µm, the beam energy and the detector. Mutation: the scan image left out; the energy offset not scaled to eV.
    func testABrukerMapOpensInTheEDSRoomWithItsScanImage() throws {
        let url = Self.fixture("bruker/P45_the_default_job.bcf")
        let loaded = try EDXOpening.open(url: url)
        XCTAssertEqual(loaded.nx, 100); XCTAssertEqual(loaded.ny, 75); XCTAssertEqual(loaded.channels, 2048)
        XCTAssertEqual(loaded.metadata.energyOffsetEV, -0.472397235 * 1000, accuracy: 1e-9)
        XCTAssertEqual(loaded.metadata.energyDispersionEV, 0.010001 * 1000, accuracy: 1e-12)
        XCTAssertEqual(loaded.metadata.beamEnergyKeV, 20)
        XCTAssertEqual(loaded.metadata.scanPixelUnit, "µm")
        XCTAssertEqual(loaded.metadata.detectors.first?.name, "XFlash 6|10")
        XCTAssertEqual(loaded.scanImage?.count, 7500, "the BSE image on the scan grid")
        XCTAssertEqual(loaded.sum(mask: nil).reduce(0, +), 165_941, "every count of rsciio's map")
        XCTAssertEqual(FileRouting.inventory(path: url.path).landing, .eds)
    }

    /// An EDAX map opens with the .spc's calibration; without the .spc beside it the room refuses it in words.
    func testAnEDAXMapOpensWithItsSPCAndIsRefusedWithoutIt() throws {
        let url = Self.fixture("edax/spd_map_crop8.spd")
        let loaded = try EDXOpening.open(url: url)
        XCTAssertEqual(loaded.channels, 2500)
        XCTAssertEqual(loaded.metadata.energyDispersionEV, 5, accuracy: 1e-12)
        XCTAssertEqual(loaded.metadata.beamEnergyKeV, 22)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let alone = folder.appendingPathComponent("alone.spd")
        try FileManager.default.copyItem(at: url, to: alone)
        XCTAssertThrowsError(try EDXOpening.open(url: alone)) { error in
            XCTAssertTrue((error as? SEMEDSReadError)?.text.contains(".spc") ?? false, "\(error)")
        }
    }

    /// `names` from the committed EDAX fixtures, copied into a fresh temporary folder that is removed after the test.
    private func copyEDAX(_ names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for name in names { try FileManager.default.copyItem(at: Self.fixture("edax/" + name), to: folder.appendingPathComponent(name)) }
        return folder
    }

    /// `url` made mode 000 until the test ends: this process may not read it, as the sandboxed app may not read a companion it
    /// was not given.
    private func makeUnreadable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: url.path), "root reads a mode-000 file; run this as a user")
    }

    /// An .ipr beside an EDAX map that is there but cannot be read is left out as a missing one is, with a note: the map opens
    /// with the same counts and the .spc's energy axis, its pixels not calibrated, and the EDS room shows it in pixels. Red
    /// before: the .ipr's read failure failed the whole open.
    func testAnEDAXMapWhoseIPRCannotBeReadOpensWithoutItsPixelSize() throws {
        let folder = try copyEDAX(["spd_map_crop8.spd", "spd_map_crop8.spc", "Live Map 2_Img.ipr"])
        let map = folder.appendingPathComponent("spd_map_crop8.spd")
        let whole = try EDAXEDSReader.read(url: map)
        XCTAssertEqual(whole.notes, [])
        let calibrated = try XCTUnwrap(whole.spectrumImages.first)
        XCTAssertEqual(calibrated.axes.map(\.units), ["\u{B5}m", "\u{B5}m", "keV"])
        try makeUnreadable(folder.appendingPathComponent("Live Map 2_Img.ipr"))
        let file = try EDAXEDSReader.read(url: map)
        XCTAssertEqual(file.notes, ["Live Map 2_Img.ipr beside spd_map_crop8.spd could not be read: the map has no pixel size."])
        let uncalibrated = try XCTUnwrap(file.spectrumImages.first)
        XCTAssertEqual(uncalibrated.axes.map(\.units), [nil, nil, "keV"])
        XCTAssertEqual([uncalibrated.axes[0].scale, uncalibrated.axes[1].scale], [1, 1])
        XCTAssertEqual(uncalibrated.energyAxis, calibrated.energyAxis, "the .spc's energy axis")
        XCTAssertEqual(uncalibrated.cube, calibrated.cube, "the same counts")
        let loaded = try EDXOpening.open(url: map)
        XCTAssertNil(loaded.metadata.scanPixelUnit)
        XCTAssertEqual(loaded.metadata.energyDispersionEV, 5, accuracy: 1e-12)
    }

    /// The same for a line scan's .csv: it opens with the same counts and energy axis, its x axis in steps of one instead of
    /// the distances. Red before: the .csv's read failure failed the whole open.
    func testAnEDAXLineScanWhoseCSVCannotBeReadOpensWithoutItsDistances() throws {
        let folder = try copyEDAX(["line_scan_crop.lsd", "line_scan_crop.spc", "line_scan_crop.csv"])
        let line = folder.appendingPathComponent("line_scan_crop.lsd")
        let whole = try EDAXEDSReader.read(url: line)
        XCTAssertEqual(whole.notes, [])
        let measured = try XCTUnwrap(whole.spectrumImages.first)
        XCTAssertEqual(measured.axes[0].units, "nm")
        XCTAssertEqual(measured.axes[0].scale, 212)
        try makeUnreadable(folder.appendingPathComponent("line_scan_crop.csv"))
        let file = try EDAXEDSReader.read(url: line)
        XCTAssertEqual(file.notes, ["line_scan_crop.csv beside line_scan_crop.lsd could not be read: the line scan has no distances."])
        let unmeasured = try XCTUnwrap(file.spectrumImages.first)
        XCTAssertEqual(unmeasured.axes[0], SEMEDSAxis(name: "x", size: measured.axes[0].size, scale: 1, offset: 0, units: nil))
        XCTAssertEqual(unmeasured.energyAxis, measured.energyAxis)
        XCTAssertEqual(unmeasured.cube, measured.cube, "the same counts")
    }

    /// A JEOL .pts opens as its 512 x 512 x 4096 map, held sparse; the S(T)EM image of a stream that has one is the scan image.
    func testAJEOLMapOpensSparseWithItsSTEMImage() throws {
        let loaded = try EDXOpening.open(url: Self.fixture("jeol/View000_0000006_4frames.pts"))
        XCTAssertEqual(loaded.nx, 512); XCTAssertEqual(loaded.channels, 4096)
        XCTAssertNil(loaded.scanImage, "this stream holds no image")
        let cube = try XCTUnwrap(loaded.image as? CSRSpectrumImage)
        XCTAssertLessThan(cube.counts.count, 100_000, "only the recorded X-rays are held")
        let withImage = try EDXOpening.open(url: Self.fixture("jeol/InvalidFrame/Dummy-Data_0000015.pts"))
        XCTAssertEqual(withImage.scanImage?.count, 64 * 64)
    }

    /// Single spectra open as one pixel: a Bruker .spx, an EDAX .spc, a JEOL .eds.
    func testSingleSpectraOpenAsOnePixel() throws {
        for (path, channels) in [("bruker/bruker_nano.spx", 4096), ("edax/single_spect.spc", 4096), ("jeol/met03.EDS", 2048)] {
            let url = Self.fixture(path)
            XCTAssertTrue(FileRouting.inventory(path: url.path).singleSpectrum, path)
            let loaded = try EDXOpening.open(url: url)
            XCTAssertEqual(loaded.nx * loaded.ny, 1, path)
            XCTAssertEqual(loaded.channels, channels, path)
        }
    }

    /// A JEOL image opens in the Image room with its µm per pixel.
    func testAJEOLImageOpensInTheImageRoom() throws {
        let url = Self.fixture("jeol/InvalidFrame/Dummy-Data_0000000.img")
        XCTAssertEqual(FileRouting.inventory(path: url.path).landing, .image)
        let image = try ImageOpening.openNow(path: url.path)
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.x?.unit, "µm")
    }

    /// The CSR store sums as a dense cube does: a mask, windows. Mutation: a window's upper bound made inclusive.
    func testTheSparseStoreSumsExactly() throws {
        let cube = try CSRSpectrumImage(ny: 1, nx: 3, channels: 4, rowOffsets: [0, 2, 2, 4], channelIndex: [0, 3, 1, 2], counts: [5, 7, 1, 2])
        XCTAssertEqual(cube.sum(mask: nil), [5, 1, 2, 7])
        XCTAssertEqual(cube.sum(mask: [false, true, true]), [0, 1, 2, 0])
        XCTAssertEqual(cube.windowSums([0..<2, 2..<4]), [[5, 0, 1], [7, 0, 2]])
        XCTAssertEqual(cube.spectrum(pixel: 2), [0, 1, 2, 0])
    }
}
