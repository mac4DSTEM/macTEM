//
//  EELSExportInfoTests.swift
//  The EELS room's Export and Info, as the EDS room has them: the shown spectrum as an EMSA/MAS file (FormatoKit's `MSAWriter`), the method JSON with
//  its SHA-256 and for a file with no thickness map, and the Info rows (the tilts and the instrument where the file states them, and where the beam
//  energy came from).
//
//  THE TRUTH: the planted low loss of `EELSRoomTests` and the planted core loss of `EELSControlsTests`. The MSA file is read back with FormatoKit's
//  `MSAReader` (RosettaSciIO's reader): its axis, keywords and counts are the room's, the counts as RosettaSciIO's writer prints them (`%f`). The
//  hash is SHA-256 over the method record's compact sorted-keys JSON, recomputed here from the file. Nothing here makes a number.
//

import XCTest
import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import FormatoCore
import FormatoMSA
import ShellSpectroscopy
import SpectroCore
import SpectroEELS
import TEMCore
import TEMSession
import ShellEDXModel
@testable import macTEM

nonisolated final class EELSExportInfoTests: XCTestCase {

    @MainActor private func dualRoom(alpha: Double? = nil) async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "dual.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "planted core",
                                alphaTiltDegrees: alpha, betaTiltDegrees: nil, instrument: nil)
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        XCTAssertNotNil(session.plot)
        return session
    }

    @MainActor private func coreOnlyRoom() async throws -> EELSSession {
        let counts = [Double](repeating: 100, count: 2 * 2 * 64)
        let image = try LowLossSpectrumImage(nx: 2, ny: 2, channels: 64, counts: counts, energyOffsetEV: 800, energyScaleEV: 1)
        let session = EELSSession()
        await session.bind(LoadedEELS(fileName: "core.dm4", image: image, beamEnergyKeV: nil, convergenceMrad: nil, collectionMrad: nil, origin: "planted")).value
        await session.settled()
        XCTAssertTrue(session.onlyCoreLoss)
        return session
    }

    private func value(_ spectrum: MSASpectrum, _ key: String) -> MSAValue? {
        spectrum.parameters.first { $0.key == key }?.value
    }

    // MARK: Spectrum MSA

    /// A Dual-EELS file writes the shown core loss: FormatoKit's reader gets back its energy axis in eV, the EELS signal type, the beam energy and the
    /// two angles the room uses, the stage tilt the file states, and every channel's summed counts as RosettaSciIO's writer prints them. Red under:
    /// no MSA export; the low loss written for a Dual-EELS file; the axis in keV; the microscope left out.
    @MainActor func testSpectrumMSAIsTheShownCoreLossReadBackByFormatoKit() async throws {
        let session = try await dualRoom(alpha: 12.5)
        let plot = try XCTUnwrap(session.plot)
        let core = try XCTUnwrap(plot.core)
        let bytes = try XCTUnwrap(try session.spectrumMSA())
        let spectrum = try MSAReader.parse(bytes: bytes, fileName: "dual spectrum.msa")
        let axis = try XCTUnwrap(spectrum.signal.axes.first)
        XCTAssertEqual(axis.size, core.counts.count)
        XCTAssertEqual(axis.offset, core.origin)
        XCTAssertEqual(axis.scale, core.step)
        XCTAssertEqual(axis.units, "eV")
        XCTAssertEqual(spectrum.signal.signalType, "EELS")
        XCTAssertEqual(value(spectrum, "SIGNALTYPE"), .text("ELS"))
        XCTAssertEqual(value(spectrum, "XLABEL"), .text("Energy loss"))
        XCTAssertEqual(value(spectrum, "BEAMKV"), .number(200))
        XCTAssertEqual(value(spectrum, "CONVANGLE"), .number(0))
        XCTAssertEqual(value(spectrum, "COLLANGLE"), .number(10))
        XCTAssertEqual(value(spectrum, "XTILTSTGE"), .number(12.5))
        XCTAssertEqual(value(spectrum, "TITLE"), .text("dual.dm4 Whole map core loss"))
        XCTAssertEqual(value(spectrum, "COMMENT"), .text("File created by macEM"))
        // RosettaSciIO's Y format: each count as C's %f, then the separator, CR LF.
        XCTAssertEqual(spectrum.signal.data.doubles(), core.counts.map { Double(String(format: "%f", $0))! })
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("#SPECTRUM    : Spectral Data Starts Here\r\n" + String(format: "%f", core.counts[0]) + ", \r\n"), text)
        XCTAssertTrue(text.hasSuffix("#ENDOFDATA   : End Of Data and File"))
    }

    /// A file with only a low loss writes the low loss; with no beam energy stated, no BEAMKV line. Red under: nothing written without a core loss.
    @MainActor func testSpectrumMSAOfALowLossOnlyFileIsTheLowLoss() async throws {
        let session = EELSSession()
        await session.bind(LoadedEELS(fileName: "low.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: nil, convergenceMrad: nil, collectionMrad: nil,
                                      origin: "planted")).value
        await session.settled()
        let plot = try XCTUnwrap(session.plot)
        let spectrum = try MSAReader.parse(bytes: try XCTUnwrap(try session.spectrumMSA()), fileName: "low spectrum.msa")
        XCTAssertEqual(spectrum.signal.axes.first?.offset, -5)
        XCTAssertEqual(spectrum.signal.axes.first?.scale, 0.5)
        XCTAssertEqual(spectrum.signal.data.doubles(), plot.low.counts.map { Double(String(format: "%f", $0))! })
        XCTAssertEqual(value(spectrum, "TITLE"), .text("low.dm4 Whole map low loss"))
        XCTAssertNil(spectrum.parameters.first { $0.key == "BEAMKV" })
        XCTAssertNil(spectrum.parameters.first { $0.key == "COLLANGLE" })
    }

    /// The export kind sits beside Spectrum CSV, writes `.msa`, and keeps the spectrum's file name. Red under: no kind; the CSV type.
    @MainActor func testTheMSAExportKindWritesAnMSAFile() throws {
        XCTAssertEqual(EELSExportKind.spectrumMSA.title, "Spectrum MSA…")
        XCTAssertEqual(EELSExportKind.spectrumMSA.suffix, " spectrum")
        XCTAssertEqual(EELSExportKind.spectrumMSA.contentType.preferredFilenameExtension, "msa")
        let order = EELSExportKind.allCases
        XCTAssertEqual(order.firstIndex(of: .spectrumMSA), try XCTUnwrap(order.firstIndex(of: .spectrum)) + 1)
    }

    /// The export writes the session's bytes into the journeys' export folder. Red under: the MSA case not wired.
    @MainActor func testTheMSAExportWritesTheSessionsBytes() async throws {
        let session = try await dualRoom()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eels-msa-\(UUID().uuidString)")
        var said = ""
        EELSRoomState().export(.spectrumMSA, from: session, maps: [], directory: dir) { said = $0 }
        XCTAssertEqual(said, "Exported dual spectrum.msa")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("dual spectrum.msa")), try session.spectrumMSA())
        try? FileManager.default.removeItem(at: dir)
    }

    /// A journey's export onto a folder of the file's name says why in `ExportFile`'s words and leaves the folder as it was, with what it
    /// held. Red under: the bytes written past `ExportFile.write` (the system's own sentence, not the refusal by name).
    @MainActor func testAJourneyExportOntoAFolderSaysWhyAndKeepsIt() async throws {
        let session = try await dualRoom()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eels-msa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("dual spectrum.msa", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        var said = ""
        EELSRoomState().export(.spectrumMSA, from: session, maps: [], directory: dir) { said = $0 }
        XCTAssertEqual(said, "Export failed: The file could not be written. \u{201C}dual spectrum.msa\u{201D} is a folder.")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("inside.txt"), encoding: .utf8), "keep")
    }

    /// A journey's export keeps its file's name and the session's bytes, byte for byte, the spectrum as CSV and as MSA, and leaves nothing else in
    /// the folder. Red under: a name or a byte changed on the way to the folder; a scratch file left beside the export.
    @MainActor func testAJourneyExportKeepsItsNamesAndBytes() async throws {
        let session = try await dualRoom()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eels-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = Data(try XCTUnwrap(session.spectrumCSV).utf8)
        let msa = try XCTUnwrap(try session.spectrumMSA())
        let expected: [(EELSExportKind, String, Data)] = [(.spectrum, "dual spectrum.csv", csv), (.spectrumMSA, "dual spectrum.msa", msa)]
        for (kind, name, bytes) in expected {
            var said = ""
            EELSRoomState().export(kind, from: session, maps: [], directory: dir) { said = $0 }
            XCTAssertEqual(said, "Exported \(name)")
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(name)), bytes, name)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["dual spectrum.csv", "dual spectrum.msa"])
    }

    // MARK: Method JSON

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func recomputedHash(_ json: String) throws -> String {
        var d = try object(json)
        d["sha256"] = nil
        let canonical = try JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    /// The method JSON carries the SHA-256 of its own record (the object without the hash, compact, sorted keys), as the EDS method JSON does; a
    /// different method has a different hash. Red under: no hash; a hash over the pretty text; the same hash for two methods.
    @MainActor func testTheMethodJSONCarriesItsSHA256() async throws {
        let session = try await dualRoom()
        let json = try XCTUnwrap(session.methodJSON)
        let hash = try XCTUnwrap(try object(json)["sha256"] as? String)
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, try recomputedHash(json))
        XCTAssertTrue(json.contains("\"reference\" : \"" + ResultRow.Product.eelsThicknessReference + "\""), "the old keys stay")
        session.setThreshold(.fixed(3))
        await session.settled()
        let other = try XCTUnwrap(session.methodJSON)
        XCTAssertNotEqual(try object(other)["sha256"] as? String, hash)
        XCTAssertEqual(try object(other)["sha256"] as? String, try recomputedHash(other))
    }

    /// A file with only a core loss has no thickness map, and its method JSON says so in the room's words instead of leaving the export off; the grid,
    /// the file and the hash are there, and no log-ratio key. Red under: no JSON without a map; a log-ratio record for a file with no low loss.
    @MainActor func testTheMethodJSONOfACoreLossOnlyFile() async throws {
        let session = try await coreOnlyRoom()
        XCTAssertTrue(session.hasMethodRecord)
        let json = try XCTUnwrap(session.methodJSON)
        let d = try object(json)
        XCTAssertEqual(d["thickness"] as? String, "none")
        XCTAssertEqual(d["thickness_unavailable"] as? String, "This file holds no low loss, so it has no t/λ.")
        XCTAssertEqual(d["file"] as? String, "core.dm4")
        XCTAssertEqual(d["width"] as? Int, 2); XCTAssertEqual(d["height"] as? Int, 2)
        XCTAssertNil(d["pixels_with_t_over_lambda"]); XCTAssertNil(d["zero_loss"]); XCTAssertNil(d["method"])
        XCTAssertEqual(d["sha256"] as? String, try recomputedHash(json))
        XCTAssertFalse(EELSSession().hasMethodRecord, "nothing open: nothing to record")
    }

    // MARK: Info

    /// The tilts and the instrument as FormatoKit's DM reader maps them (RosettaSciIO's `get_mapping`): `Stage Alpha` / `Beta` in degrees as stored, the
    /// first of `Session Info.Microscope`, `Microscope Info.Name`, `Microscope Info.Microscope`; a stack-builder copy is read the same way; a file that states
    /// none has none. Red under: the tilts or the instrument dropped; the copy missed.
    func testTheTiltsAndInstrumentAreFormatoKitsDMReading() throws {
        let numbers = ["Microscope Info.Stage Position.Stage Alpha": 12.5, "Microscope Info.Stage Position.Stage Beta": -3, "Microscope Info.Voltage": 200_000]
        let strings = ["Microscope Info.Name": "JEM-ARM200F"]
        let stated = EELSOpening.stated(numbers: numbers, strings: strings)
        XCTAssertEqual(stated.alphaTiltDegrees, 12.5); XCTAssertEqual(stated.betaTiltDegrees, -3); XCTAssertEqual(stated.instrument, "JEM-ARM200F")
        let prefix = "source.Tags at creation."
        let copy = EELSOpening.stated(numbers: Dictionary(uniqueKeysWithValues: numbers.map { (prefix + $0.key, $0.value) }),
                                      strings: Dictionary(uniqueKeysWithValues: strings.map { (prefix + $0.key, $0.value) }))
        XCTAssertEqual(copy.alphaTiltDegrees, 12.5); XCTAssertEqual(copy.instrument, "JEM-ARM200F")
        let none = EELSOpening.stated(numbers: [:], strings: [:])
        XCTAssertNil(none.alphaTiltDegrees); XCTAssertNil(none.betaTiltDegrees); XCTAssertNil(none.instrument)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/eels-planted.dm4")
        let loaded = try EELSOpening.open(url: url)
        XCTAssertNil(loaded.alphaTiltDegrees, "the planted file states no stage"); XCTAssertNil(loaded.betaTiltDegrees)
    }

    /// The Info rows: the tilts and the instrument where the file states them, and the beam energy with where it came from (the file, or typed, which
    /// wins). Red under: a tilt row with no tilt; the source left out; the file's value shown after a typed one.
    @MainActor func testTheInfoRowsNameTheTiltsTheInstrumentAndTheBeamSource() async throws {
        let en = Locale(identifier: "en_US")
        let loaded = LoadedEELS(fileName: "info.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 17.5, collectionMrad: 33.25,
                                origin: "GMS DM4 object 2 (EELS)", alphaTiltDegrees: 12.5, betaTiltDegrees: -3, instrument: "JEM-ARM200F")
        let session = EELSSession()
        await session.bind(loaded).value
        await session.settled()
        XCTAssertEqual(session.beamEnergySource, .file)
        func rows() -> [String] {
            EELSInfoFormat.rows(try! XCTUnwrap(session.source), beamEnergyKeV: session.beamEnergyKeV, beamEnergySource: session.beamEnergySource, locale: en)
                .map { "\($0.label): \($0.value)" }
        }
        XCTAssertEqual(rows(), ["File: info.dm4", "Read as: GMS DM4 object 2 (EELS)", "Scan: 4 × 3 px", "Channels: 256", "Energy axis: -5 eV + i × 0.5 eV",
                                "Beam: 200 keV · from the file", "Convergence: 17.5 mrad", "Collection: 33.25 mrad",
                                "Alpha tilt: 12.5°", "Beta tilt: -3°", "Instrument: JEM-ARM200F"])
        session.setBeamEnergy(300)
        XCTAssertEqual(session.beamEnergySource, .typed)
        XCTAssertTrue(rows().contains("Beam: 300 keV · typed"), rows().joined(separator: "\n"))

        let bare = EELSSession()
        await bare.bind(try EELSRoomTests.loaded()).value
        await bare.settled()
        XCTAssertNil(bare.beamEnergySource)
        let plain = EELSInfoFormat.rows(try XCTUnwrap(bare.source), beamEnergyKeV: bare.beamEnergyKeV, beamEnergySource: bare.beamEnergySource, locale: en).map(\.label)
        XCTAssertFalse(plain.contains("Beam")); XCTAssertFalse(plain.contains("Alpha tilt")); XCTAssertFalse(plain.contains("Instrument"))
    }

    // MARK: The picture

    /// The Export section (Spectrum MSA beside Spectrum CSV) beside the Info section with its new rows, rendered offscreen. Writes
    /// `macTEM-98-export-info.png` when MACEM_SHOT_DIR is set (TEST_RUNNER_MACEM_SHOT_DIR); otherwise only checks that it renders.
    @MainActor func testTheExportAndInfoSectionsRenderOffscreen() async throws {
        let appState = AppState()
        let loaded = LoadedEELS(fileName: "info.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 17.5, collectionMrad: 33.25,
                                origin: "GMS DM4 object 2 (EELS)", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "GMS DM4 object 3 (EELS)",
                                alphaTiltDegrees: 12.5, betaTiltDegrees: -3, instrument: "JEM-ARM200F")
        await appState.eels.bind(loaded).value
        appState.eels.setThreshold(.fixed(2.5))
        await appState.eels.settled()
        let state = EELSRoomState()
        let view = HStack(alignment: .top, spacing: 12) {
            ScrollView { EELSExportSection(session: appState.eels, state: state).padding(.horizontal, 12) }.frame(width: 340)
            ScrollView { EELSRoomInfo().padding(.horizontal, 12) }.frame(width: 340)
        }
        .padding(12)
        .environment(appState)
        let canvas = NSSize(width: 720, height: 460)
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
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-98-export-info.png"))
    }
}
