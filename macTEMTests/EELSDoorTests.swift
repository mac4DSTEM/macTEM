//
//  EELSDoorTests.swift
//  The EELS room's own Open goes through the app's Open (`AppState.open(urls:)`), as File > Open and the Patterns, Indexing and Maps rooms' buttons do:
//  the file is among the window's EELS files (so the Results room lists the room's numbers under it and the room follows the selection), the EELS room
//  is in front, and the session is handed the file once, by the app's Open and not by the door as well.
//
//  THE FILE: an EMSA/MSA spectrum of signal type ELS (256 channels of 0.5 eV from -5 eV, a zero-loss peak at 0 eV and a flat tail), written by
//  FormatoKit's MSA writer into a temporary folder that tearDown removes.
//

import XCTest
import FormatoCore
import FormatoMSA
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSDoorTests: XCTestCase {

    /// Every event line the EELS session said, in order.
    private final class Recorder {
        var lines: [String] = []
    }

    private var scratch: [URL] = []

    override func tearDown() {
        for folder in scratch { try? FileManager.default.removeItem(at: folder) }
        scratch = []
        super.tearDown()
    }

    /// One EELS spectrum as an `.msa` file in a fresh temporary folder, removed at tearDown.
    private func eelsSpectrum(named name: String) throws -> URL {
        var counts = [Double](repeating: 0, count: 256)
        counts[9] = 300
        counts[10] = 1400
        counts[11] = 300
        for channel in 30..<130 { counts[channel] = 13 }
        var bytes = Data(capacity: counts.count * 8)
        for c in counts { withUnsafeBytes(of: c.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        func entry(_ key: String, _ v: Double, _ units: String) -> FormatoMetadataEntry {
            FormatoMetadataEntry(key: key, value: .number(v), units: units, provenance: FormatoProvenance(file: "", source: "test", rule: "planted"))
        }
        let signal = FormatoSignal(title: "planted", signalType: "EELS",
                                   axes: [FormatoAxis(name: "Energy loss", size: counts.count, scale: 0.5, offset: -5, units: "eV", navigate: false)],
                                   metadata: FormatoMetadata([entry("Acquisition_instrument.TEM.beam_energy", 200, "kV"),
                                                              entry("Acquisition_instrument.TEM.convergence_angle", 12.5, "mrad"),
                                                              entry("Acquisition_instrument.TEM.Detector.EELS.collection_angle", 25, "mrad")]),
                                   data: try FormatoArray(dataType: .float64, shape: [counts.count], bytes: bytes))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eels-door-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scratch.append(folder)
        let url = folder.appendingPathComponent(name)
        try MSAWriter.encode(signal, creator: "test").write(to: url)
        return url
    }

    /// The room's Open leaves the file among the window's EELS files and the EELS room in front, and the session is handed the file once. Red under:
    /// the door opening the session itself (the file never among the EELS files, so no Results rows and no following the selection; the window left in
    /// the room it was in); the door opening the session as well as the app's Open (two reads of one file).
    @MainActor func testTheRoomsOpenGoesThroughTheAppsOpenAndTheSessionGetsTheFileOnce() async throws {
        let url = try eelsSpectrum(named: "point.msa")
        XCTAssertEqual(FileRouting.inventory(path: url.path), FileInventory(eelsSpectrumImage: true), "the planted file is an EELS spectrum")
        let state = AppState(launch: LaunchOptions(arguments: []))
        let recorder = Recorder()
        state.eels.onEvent = { recorder.lines.append($0) }
        XCTAssertEqual(state.navigation.workspaceArea, .image)

        let opening = try XCTUnwrap(EELSDoor.open(url, in: state), "the door started no Open")
        await opening.value
        XCTAssertTrue(state.eelsFiles.contains(url), "the file is one of the window's EELS files")
        XCTAssertEqual(state.navigation.workspaceArea, .eels, "the EELS room is in front")
        XCTAssertTrue(state.edsFiles.isEmpty, "an EELS spectrum is not the EDS room's")
        XCTAssertTrue(state.openItems.items.isEmpty, "a spectrum is not an open image")
        XCTAssertNil(state.errorMessage)

        for _ in 0..<2000 where !state.eels.hasImage { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(state.eels.fileName, "point.msa", "the app's Open handed the file to the room")
        await state.eels.settled()
        XCTAssertEqual(recorder.lines.filter { $0 == "Opening point.msa…" }.count, 1, "the session was handed the file once: \(recorder.lines)")
    }

    /// The door's room comes back in front only where the app's Open landed in the EDS room for a file that opened into both rooms. Red under: the
    /// person thrown into the EDS room by the EELS room's own button; a person who went to another room meanwhile pulled back.
    func testTheRoomComesBackInFrontOnlyFromTheEDSRoomOfAFileInBothRooms() {
        XCTAssertTrue(EELSDoor.returnsToFront(inEELS: true, inEDS: true, room: .edx), "a file with both cubes lands in the EDS room: back to the door's room")
        XCTAssertFalse(EELSDoor.returnsToFront(inEELS: true, inEDS: false, room: .eels), "an EELS file lands in the EELS room by itself")
        XCTAssertFalse(EELSDoor.returnsToFront(inEELS: true, inEDS: false, room: .edx), "the person went to the EDS room: they stay")
        XCTAssertFalse(EELSDoor.returnsToFront(inEELS: false, inEDS: true, room: .edx), "an EDS file opened from here belongs in the EDS room")
        XCTAssertFalse(EELSDoor.returnsToFront(inEELS: false, inEDS: false, room: .image), "an image opened from here lands in the Image room")
        for room in WorkspaceArea.allCases where room != .edx {
            XCTAssertFalse(EELSDoor.returnsToFront(inEELS: true, inEDS: true, room: room), "\(room.rawValue): the person moved on")
        }
    }

    /// The importer hands its file to the door, the door to the app's Open, and the room opens the session nowhere itself. Red under: the importer
    /// calling `session.open(url:)`.
    func testTheImporterHandsItsFileToTheAppsOpen() throws {
        let source = try FFTRoomWiringTests.squeezedUI("EELSRoom.swift")
        XCTAssertTrue(source.contains("case .success(let urls): if let url = urls.first { EELSDoor.open(url, in: appState) }"))
        XCTAssertTrue(source.contains("guard let opening = appState.open(urls: [url]) else { return nil }"))
        XCTAssertFalse(source.contains(".open(url:"), "the room opens the session nowhere itself")
    }
}
