//
//  EELSSingleSpectrumOpeningTests.swift
//  The EELS room opens a single spectrum: a GMS spectrum saved alone (an EELS object of dimensions [energy], what a spectrum picker saves) or an
//  EMSA/MSA file of signal type ELS opens as a 1 x 1 spectrum image, so the room shows its single-spectrum state, and its thickness and its fit run.
//  A line scan ([x, energy]) and a file with no EELS are refused in a sentence.
//
//  THE TRUTH: the planted low loss of `EELSRoomTests` (its pixel 0: I_0 = 2000 counts at 0 eV, t/λ = 0.5) and the planted core loss of
//  `EELSControlsTests` (its pixel 0: C K, N K and O K in the amounts 2 : 1 : 1.5 on a power law), each written as a one-dimensional GMS object
//  by the small DM4 writer below (the grammar of tools/parity/metadata-parity/dm4_writer.py: big-endian tag headers, little-endian data,
//  float32 calibrations, strings as UTF-16 arrays). The counts are stored as float32, as GMS stores a spectrum, so the truth is the planted
//  values rounded to Float.
//

import XCTest
import AppKit
import SwiftUI
import FormatoCore
import FormatoMSA
import SpectroCore
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM
import ShellEDXModel

/// A minimal DM4 writer for planted GMS files: only what an image object needs.
nonisolated enum PlantedDM4 {
    indirect enum Node {
        case group(String, [Node])
        case f32(String, Float)
        case f64(String, Double)
        case i32(String, Int32)
        case u32(String, UInt32)
        case text(String, String)
        case floats(String, [Float])
    }

    private static func be16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).bigEndian) { Data($0) } }
    private static func be32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) } }
    private static func be64(_ v: Int) -> Data { withUnsafeBytes(of: UInt64(v).bigEndian) { Data($0) } }
    private static func le<T>(_ v: T) -> Data { withUnsafeBytes(of: v) { Data($0) } }

    private static func tag(_ kind: UInt8, _ label: String, _ body: Data) -> Data {
        let name = Data(label.utf8)
        return Data([kind]) + be16(name.count) + name + be64(body.count) + body
    }

    private static func data(_ label: String, _ info: [Int], _ payload: Data) -> Data {
        tag(21, label, Data("%%%%".utf8) + be64(info.count) + info.reduce(Data()) { $0 + be64($1) } + payload)
    }

    private static func groupBody(_ children: [Node]) -> Data {
        children.reduce(Data([1, 0]) + be64(children.count)) { $0 + encode($1) }
    }

    static func encode(_ node: Node) -> Data {
        switch node {
        case .group(let label, let children): return tag(20, label, groupBody(children))
        case .f32(let label, let v): return data(label, [6], le(v.bitPattern.littleEndian))
        case .f64(let label, let v): return data(label, [7], le(v.bitPattern.littleEndian))
        case .i32(let label, let v): return data(label, [3], le(v.littleEndian))
        case .u32(let label, let v): return data(label, [5], le(v.littleEndian))
        case .text(let label, let s):
            let units = Array(s.utf16)
            return data(label, [20, 4, units.count], units.reduce(Data()) { $0 + le($1.littleEndian) })
        case .floats(let label, let values):
            return data(label, [20, 6, values.count], values.reduce(Data()) { $0 + le($1.bitPattern.littleEndian) })
        }
    }

    /// A DM4 file whose `ImageList` holds `objects` (each an unnamed group).
    static func file(_ objects: [Node]) -> Data {
        let root = groupBody([.group("ImageList", objects)])
        return be32(4) + be64(root.count) + be32(1) + root + Data(count: 8)
    }

    /// One image object: `dims` in DM order (fastest first), one (origin, scale, units) per dimension, float32 counts in file order.
    static func object(name: String, dims: [Int], calibrations: [(Float, Float, String)], counts: [Float], tags: [Node]) -> Node {
        .group("", [
            .group("ImageData", [
                .group("Calibrations", [
                    .group("Brightness", [.f32("Origin", 0), .f32("Scale", 1), .text("Units", "")]),
                    .group("Dimension", calibrations.map { .group("", [.f32("Origin", $0.0), .f32("Scale", $0.1), .text("Units", $0.2)]) }),
                ]),
                .i32("DataType", 2),
                .group("Dimensions", dims.map { .u32("", UInt32($0)) }),
                .floats("Data", counts),
                .i32("PixelDepth", 4),
            ]),
            .group("ImageTags", tags),
            .text("Name", name),
            .group("UniqueID", [.i32("", 1), .i32("", 2), .i32("", 3), .i32("", Int32(name.count))]),
        ])
    }

    /// The tags GMS writes on an EELS spectrum: the signal, the beam (volts) and the two semi-angles.
    static func eelsTags(signal: String = "EELS", volts: Double = 200_000, convergence: Double = 0, collection: Double = 10) -> [Node] {
        [
            .group("Meta Data", [.text("Signal", signal), .text("Format", "Spectrum")]),
            .group("Microscope Info", [.f64("Voltage", volts)]),
            .group("EELS", [.group("Experimental Conditions", [.f64("Convergence semi-angle (mrad)", convergence),
                                                               .f64("Collection semi-angle (mrad)", collection)])]),
        ]
    }
}

nonisolated final class EELSSingleSpectrumOpeningTests: XCTestCase {

    /// The planted low loss's pixel 0 (256 channels of 0.5 eV from -5 eV: origin 10) and core loss's pixel 0 (700 channels of 1 eV from 200 eV: origin -200).
    static func lowSpectrum() throws -> [Float] { try EELSRoomTests.image().counts.prefix(EELSRoomTests.channels).map { Float($0) } }
    static func coreSpectrum() throws -> [Float] { let core = try EELSControlsTests.core(); return core.counts.prefix(core.channels).map { Float($0) } }

    static func lowObject(convergence: Double = 0, collection: Double = 10) throws -> PlantedDM4.Node {
        let low = try lowSpectrum()
        return PlantedDM4.object(name: "EELS Spectrum", dims: [low.count], calibrations: [(10, 0.5, "eV")], counts: low,
                                 tags: PlantedDM4.eelsTags(convergence: convergence, collection: collection))
    }

    static func coreObject() throws -> PlantedDM4.Node {
        let core = try coreSpectrum()
        return PlantedDM4.object(name: "EELS Spectrum core", dims: [core.count], calibrations: [(-200, 1, "eV")], counts: core, tags: PlantedDM4.eelsTags())
    }

    static func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eels-single-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: Opening

    /// A GMS spectrum saved alone ([energy]) opens as a 1 x 1 spectrum image with the file's axis, counts, beam and angles, and an Open lands in the
    /// EELS room. Red under: the kit's "an EELS spectrum image is [x, y, energy]" refusal reaching the person.
    func testAGMSSingleSpectrumOpensAsOneByOne() throws {
        let url = try Self.temp("point.dm4", PlantedDM4.file([try Self.lowObject(convergence: 12.5, collection: 25)]))
        let loaded = try EELSOpening.open(url: url)
        XCTAssertEqual([loaded.image.nx, loaded.image.ny, loaded.image.channels], [1, 1, EELSRoomTests.channels])
        XCTAssertEqual(loaded.image.energyOffsetEV, -5, accuracy: 1e-12)
        XCTAssertEqual(loaded.image.energyScaleEV, 0.5, accuracy: 1e-12)
        XCTAssertEqual(loaded.image.counts, try Self.lowSpectrum().map { Double($0) }, "the counts as stored")
        XCTAssertEqual(loaded.beamEnergyKeV, 200); XCTAssertEqual(loaded.convergenceMrad, 12.5); XCTAssertEqual(loaded.collectionMrad, 25)
        XCTAssertEqual(loaded.origin, "GMS DM4 object 1 (EELS spectrum)")
        XCTAssertNil(loaded.coreLoss)
        XCTAssertNil(loaded.scanPixelSize, "one spectrum has no scan")

        let inventory = FileRouting.inventory(path: url.path)
        XCTAssertEqual(inventory, FileInventory(eelsSpectrumImage: true))
        XCTAssertEqual(inventory.landing, .eels)
    }

    /// A low-loss and a core-loss spectrum in one file pair as a Dual-EELS spectrum image does: the window holding 0 eV is the low loss whatever the
    /// order of the objects. Red under: the first object taken as the low loss; the core loss dropped.
    func testALowLossAndACoreLossSpectrumPair() throws {
        let url = try Self.temp("dual-point.dm4", PlantedDM4.file([try Self.coreObject(), try Self.lowObject()]))
        let loaded = try EELSOpening.open(url: url)
        XCTAssertEqual([loaded.image.nx, loaded.image.ny], [1, 1])
        XCTAssertEqual(loaded.image.energyOffsetEV, -5, accuracy: 1e-12)
        XCTAssertEqual(loaded.origin, "GMS DM4 object 2 (EELS spectrum)")
        let core = try XCTUnwrap(loaded.coreLoss, "the core loss rides along")
        XCTAssertEqual([core.nx, core.ny, core.channels], [1, 1, 700])
        XCTAssertEqual(core.energyOffsetEV, 200, accuracy: 1e-12)
        XCTAssertEqual(core.energyScaleEV, 1, accuracy: 1e-12)
        XCTAssertEqual(core.counts, try Self.coreSpectrum().map { Double($0) })
        XCTAssertEqual(loaded.coreLossOrigin, "GMS DM4 object 1 (EELS spectrum)")
    }

    /// The room opened on the file is in its single-spectrum state, and its thickness and its fit run: t/λ is the planted 0.5 and the fit finds the
    /// planted composition (C 44.4, N 22.2, O 33.3 at%). Red under: the file refused; a 1 x 1 file not in the single-spectrum state.
    @MainActor func testThicknessAndTheFitRunOnASingleSpectrum() async throws {
        let session = try await Self.room()
        XCTAssertTrue(session.isSingleSpectrum)
        XCTAssertEqual(session.plot?.regionName, "Spectrum")
        let map = try XCTUnwrap(session.map, session.failure ?? "no thickness")
        XCTAssertEqual(try XCTUnwrap(map.pixels.first?.tOverLambda), EELSRoomTests.planted(0), accuracy: 1e-6)

        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        await session.fit()?.value
        await session.settled()
        XCTAssertNotNil(session.model, session.failure ?? session.fitRefusal ?? "no fit")
        XCTAssertEqual(session.fittingState, .current)
        let total = EELSControlsTests.amounts.map(\.amount).reduce(0, +)
        let rows = session.regionRows
        XCTAssertEqual(rows.count, EELSControlsTests.amounts.count)
        for (edge, amount) in EELSControlsTests.amounts {
            let row = try XCTUnwrap(rows.first { $0.title.hasPrefix(edge.element) }, "\(edge.element): \(rows.map(\.title))")
            XCTAssertEqual(try XCTUnwrap(row.atomicPercent), 100 * amount / total, accuracy: 0.5, edge.element)
        }
    }

    @MainActor static func room() async throws -> EELSSession {
        let url = try temp("dual-point.dm4", PlantedDM4.file([try lowObject(), try coreObject()]))
        let session = EELSSession()
        await session.bind(try EELSOpening.open(url: url)).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        return session
    }

    /// An EMSA/MSA spectrum of signal type ELS (the room's own MSA export writes one) opens in the EELS room as a 1 x 1 spectrum image, not in the
    /// EDS room; an EDS `.msa` still goes to the EDS room. Red under: every `.msa` sent to the EDS room as X-ray counts.
    func testAnEELSMSAOpensInTheEELSRoom() throws {
        let low = try Self.lowSpectrum().map { Double($0) }
        var bytes = Data(capacity: low.count * 8)
        for c in low { withUnsafeBytes(of: c.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        func entry(_ key: String, _ v: Double, _ units: String) -> FormatoMetadataEntry {
            FormatoMetadataEntry(key: key, value: .number(v), units: units, provenance: FormatoProvenance(file: "", source: "test", rule: "planted"))
        }
        let signal = FormatoSignal(title: "planted", signalType: "EELS",
                                   axes: [FormatoAxis(name: "Energy loss", size: low.count, scale: 0.5, offset: -5, units: "eV", navigate: false)],
                                   metadata: FormatoMetadata([entry("Acquisition_instrument.TEM.beam_energy", 200, "kV"),
                                                              entry("Acquisition_instrument.TEM.convergence_angle", 12.5, "mrad"),
                                                              entry("Acquisition_instrument.TEM.Detector.EELS.collection_angle", 25, "mrad")]),
                                   data: try FormatoArray(dataType: .float64, shape: [low.count], bytes: bytes))
        let url = try Self.temp("point.msa", try MSAWriter.encode(signal, creator: "test"))

        let inventory = FileRouting.inventory(path: url.path)
        XCTAssertEqual(inventory, FileInventory(eelsSpectrumImage: true))
        XCTAssertFalse(FileRouting.isSingleSpectrum(path: url.path), "not an EDS spectrum")
        let loaded = try EELSOpening.open(url: url)
        XCTAssertEqual([loaded.image.nx, loaded.image.ny, loaded.image.channels], [1, 1, low.count])
        XCTAssertEqual(loaded.image.energyOffsetEV, -5, accuracy: 1e-12)
        XCTAssertEqual(loaded.image.energyScaleEV, 0.5, accuracy: 1e-12)
        XCTAssertEqual(loaded.image.counts.count, low.count)
        for (read, planted) in zip(loaded.image.counts, low) { XCTAssertEqual(read, planted, accuracy: 5e-7, "the MSA prints counts with %f") }
        XCTAssertEqual(loaded.beamEnergyKeV, 200); XCTAssertEqual(loaded.convergenceMrad, 12.5); XCTAssertEqual(loaded.collectionMrad, 25)
        XCTAssertEqual(loaded.origin, "EMSA/MSA spectrum (EELS)")

        let eds = try Self.temp("eds.msa", try EDXExports.msa(counts: [1, 2, 3], axis: EnergyAxis(offset: 0, scale: 0.01, size: 3), title: "x",
                                                            beamEnergyKeV: 200, host: .macTEM))
        XCTAssertEqual(FileRouting.inventory(path: eds.path), FileInventory(singleSpectrum: true))
        XCTAssertThrowsError(try EELSOpening.open(url: eds)) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "eds.msa holds no EELS spectrum or spectrum image.")
        }
    }

    // MARK: Refusals

    /// A line scan ([x, energy]) and a file with no EELS are refused in a sentence that says what the room opens. Red under: the kit's
    /// "has dimensions [4, 256]" shown as it is.
    func testALineScanAndAFileWithoutEELSAreRefusedInASentence() throws {
        let low = try Self.lowSpectrum()
        let line = PlantedDM4.object(name: "EELS Line", dims: [4, low.count], calibrations: [(0, 2, "nm"), (10, 0.5, "eV")],
                                     counts: (0..<4).flatMap { _ in low }, tags: PlantedDM4.eelsTags())
        let lineURL = try Self.temp("line.dm4", PlantedDM4.file([line]))
        XCTAssertThrowsError(try EELSOpening.open(url: lineURL)) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "line.dm4 holds an EELS line scan (4 positions of 256 channels): the EELS room opens a spectrum image [x, y, energy] or a single spectrum.")
        }

        let notInEV = PlantedDM4.object(name: "EELS Spectrum", dims: [low.count], calibrations: [(10, 0.5, "nm")], counts: low, tags: PlantedDM4.eelsTags())
        XCTAssertThrowsError(try EELSOpening.open(url: try Self.temp("nm.dm4", PlantedDM4.file([notInEV])))) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "nm.dm4: the energy axis of the EELS spectrum is in \"nm\", not eV.")
        }

        let xray = PlantedDM4.object(name: "Spectrum", dims: [low.count], calibrations: [(0, 0.01, "keV")], counts: low,
                                     tags: PlantedDM4.eelsTags(signal: "X-ray"))
        let xrayURL = try Self.temp("xray.dm4", PlantedDM4.file([xray]))
        XCTAssertFalse(FileRouting.inventory(path: xrayURL.path).eelsSpectrumImage)
        XCTAssertThrowsError(try EELSOpening.open(url: xrayURL)) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "xray.dm4 holds no EELS spectrum or spectrum image.")
        }
    }

    // MARK: The picture

    /// The room on the opened single spectrum after a fit: the spectrum and its results beside Processing and Fitting, rendered offscreen. Writes
    /// `macTEM-98fix2.png` when MACEM_SHOT_DIR is set (TEST_RUNNER_MACEM_SHOT_DIR); otherwise only checks that it renders.
    @MainActor func testTheOpenedSingleSpectrumRendersOffscreen() async throws {
        let session = try await Self.room()
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        await session.fit()?.value
        await session.settled()
        let state = EELSRoomState()
        let view = HStack(alignment: .top, spacing: 0) {
            EELSLowerPane(session: session, state: state).frame(width: 760, height: 560)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    EELSMapsSection(session: session, state: state)
                    EELSToolsSection(session: session, state: state)
                    EELSProcessingSection(session: session)
                    EELSFittingSection(session: session)
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 320, height: 560)
        }
        let canvas = NSSize(width: 1081, height: 560)
        let host = NSHostingView(rootView: view.frame(width: canvas.width, height: canvas.height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-98fix2.png"))
    }
}
