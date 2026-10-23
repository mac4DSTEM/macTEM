//
//  FileRoutingTests.swift
//  Open by content (`FileRouting`, TEMCore; `AppState.open(urls:)`): FormatoKit's sniff decides where a file goes, a single spectrum (an
//  `.msa`, a Velox file of spectra) opens in the EDX room as a one-pixel spectrum image, a 4D dataset or an unknown file is refused in
//  words, and a file of images keeps the Image room. The kit's fixtures are planted and committed; the owner's and RosettaSciIO's example
//  files are read from `References/` when they are there (and the test says it skipped when not): nothing of them is copied.
//

import XCTest
import SpectroCore
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
@testable import macTEM

nonisolated final class FileRoutingTests: XCTestCase {

    static func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)").path
    }

    static func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The suite's `References/…` file, or a skip: the owner's data and the parity examples are not committed anywhere.
    static func reference(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // The org folder's References (this repo's own `References/` when it has one).
        let candidates = [root.appendingPathComponent("References/\(relative)").path,
                          root.deletingLastPathComponent().appendingPathComponent("References/\(relative)").path]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("not skipped on Paul's Mac: \(relative) is not here")
        }
        return path
    }

    // MARK: Routes

    /// Images are images, a Velox file of spectra only is one spectrum, 4D datasets and unknown files are refused with the sentence that
    /// says what they are. Red under: the extension deciding; a Velox spectrum opened as an image.
    func testFilesAreInventoriedByContent() throws {
        XCTAssertEqual(FileRouting.inventory(path: Self.fixture("planted-2d.dm4")), FileInventory(image: true))
        XCTAssertEqual(FileRouting.inventory(path: Self.fixture("velox-aniso.emd")), FileInventory(image: true))
        XCTAssertEqual(FileRouting.inventory(path: Self.fixture("velox-single-spectrum.emd")), FileInventory(singleSpectrum: true))
        let mib = try Self.temp("scan.mib", Data("x".utf8))
        guard let fourD = FileRouting.inventory(path: mib.path).refusal else { return XCTFail("a MIB file is a 4D dataset") }
        XCTAssertTrue(fourD.contains("scan.mib") && fourD.contains("4D dataset") && fourD.contains("mac4DSTEM"), fourD)
        let unknown = try Self.temp("notes.xyz", Data("hello".utf8))
        XCTAssertEqual(FileRouting.inventory(path: unknown.path).refusal,
                       "notes.xyz is not a format macTEM opens (or its extension and its first bytes disagree).")
        let liar = try Self.temp("fake.dm4", Data("this is not a DM file".utf8))
        XCTAssertNotNil(FileRouting.inventory(path: liar.path).refusal, "bytes that disagree with the extension are refused")
    }

    /// The landing room is the richest dataset: a spectrum cube before an image, EELS between.
    func testTheLandingRoomIsTheRichestDataset() {
        XCTAssertEqual(FileInventory(image: true).landing, .image)
        XCTAssertEqual(FileInventory(image: true, edsSpectrumImage: true).landing, .eds)
        XCTAssertEqual(FileInventory(image: true, eelsSpectrumImage: true).landing, .eels)
        XCTAssertEqual(FileInventory(image: true, edsSpectrumImage: true, eelsSpectrumImage: true).landing, .eds)
        XCTAssertEqual(FileInventory(singleSpectrum: true).landing, .eds)
        XCTAssertNil(FileInventory(refusal: "no").landing)
        XCTAssertGreaterThan(FileInventory.Landing.eds.richness, FileInventory.Landing.eels.richness)
        XCTAssertGreaterThan(FileInventory.Landing.eels.richness, FileInventory.Landing.image.richness)
    }

    // MARK: Single spectra

    /// An `.msa` written by the room's own export reads back as a one-pixel spectrum image with the same counts, axis and beam energy; it
    /// routes to the EDX room. Red under: counts rounded wrongly; the axis read in eV as keV; the beam energy dropped.
    func testAnMSAFileIsAOnePixelSpectrumImage() throws {
        let counts: [UInt64] = (0..<256).map { UInt64($0 % 17) * 3 + 1 }
        let axis = EnergyAxis(offset: -0.1, scale: 0.01, size: counts.count)
        let url = try Self.temp("planted.msa", try EDXExports.msa(counts: counts, axis: axis, title: "planted", beamEnergyKeV: 200))
        XCTAssertEqual(FileRouting.inventory(path: url.path), FileInventory(singleSpectrum: true))
        XCTAssertTrue(FileRouting.isSingleSpectrum(path: url.path))
        let loaded = try FileRouting.spectrumFile(path: url.path)
        XCTAssertEqual(loaded.metadata.scanWidth, 1); XCTAssertEqual(loaded.metadata.scanHeight, 1)
        XCTAssertEqual(loaded.metadata.channelCount, 256)
        XCTAssertEqual(loaded.metadata.beamEnergyKeV, 200)
        XCTAssertEqual(loaded.energyAxis.offset, -0.1, accuracy: 1e-9); XCTAssertEqual(loaded.energyAxis.scale, 0.01, accuracy: 1e-9)
        XCTAssertEqual(loaded.metadata.energyDispersionEV, 10, accuracy: 1e-6)
        XCTAssertEqual(loaded.image.sum(mask: nil), counts, "the counts, exactly")
        let negative = try Self.temp("neg.msa", try EDXExports.msa(counts: [1, 2, 3], axis: axis, title: "x", beamEnergyKeV: nil).replacingBytes("1.000000", with: "-1.000000"))
        XCTAssertThrowsError(try FileRouting.spectrumFile(path: negative.path)) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "The spectrum holds negative or non-finite values: it is not a count spectrum.")
        }
    }

    /// FormatoKit's planted Velox single spectrum (12 channels of 5 eV from -480 eV, 200 kV): it opens as a one-pixel spectrum image.
    func testAVeloxSingleSpectrumOpens() throws {
        let path = Self.fixture("velox-single-spectrum.emd")
        XCTAssertTrue(EDXOpening.isSpectrumImage(at: URL(fileURLWithPath: path)))
        let loaded = try FileRouting.spectrumFile(path: path)
        XCTAssertEqual(loaded.metadata.channelCount, 12)
        XCTAssertEqual(loaded.energyAxis.offset, -0.48, accuracy: 1e-9); XCTAssertEqual(loaded.energyAxis.scale, 0.005, accuracy: 1e-9)
        XCTAssertEqual(loaded.metadata.beamEnergyKeV, 200)
        XCTAssertEqual(loaded.image.sum(mask: nil).count, 12)
    }

    // MARK: Through the app's Open

    /// The app's Open sends an `.msa` to the EDX room (the room is selected, the spectrum bound as one pixel) and an image to the Image room
    /// (no room change); a refused file raises the alert with its sentence. Red under: everything opened as an image.
    @MainActor func testTheAppsOpenRoutesASpectrumToTheEDXRoomAndAnImageToTheImageRoom() async throws {
        let counts: [UInt64] = (0..<512).map { UInt64($0 % 23) * 2 + 1 }
        let msa = try Self.temp("spectrum.msa", try EDXExports.msa(counts: counts, axis: EnergyAxis(offset: 0, scale: 0.01, size: counts.count), title: "t", beamEnergyKeV: 200))
        let state = AppState(launch: LaunchOptions(arguments: []))
        XCTAssertEqual(state.navigation.workspaceArea, .image)
        await state.open(urls: [msa])?.value
        XCTAssertEqual(state.navigation.workspaceArea, .edx)
        for _ in 0..<2000 where !state.edx.hasImage { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(state.edx.fileName, "spectrum.msa")
        await state.edx.settled()
        XCTAssertEqual(state.edx.regionPixels, 1)
        XCTAssertEqual(state.edx.totalCounts, counts.reduce(0, +))
        XCTAssertTrue(state.openItems.items.isEmpty, "a spectrum is not an open image")

        let dm = try Self.temp("planted.dm4", Data(contentsOf: URL(fileURLWithPath: Self.fixture("planted-2d.dm4"))))
        await state.open(urls: [dm])?.value
        XCTAssertEqual(state.openItems.items.count, 1)
        XCTAssertEqual(state.navigation.workspaceArea, .image, "an image opened from a spectrum room lands on the image")
        XCTAssertTrue(state.edx.hasImage, "the spectrum is still there")

        let mib = try Self.temp("scan.mib", Data("x".utf8))
        await state.open(urls: [mib])?.value
        XCTAssertTrue(state.errorMessage?.contains("4D dataset") == true, "the alert says what the file is: \(state.errorMessage ?? "none")")
        XCTAssertEqual(state.openItems.items.count, 1, "a refused file opens nothing")
    }

    // MARK: Example files (read from References, not committed)

    /// A real Velox single spectrum (the FEI example in the parity set): it routes to the EDX room and reads as 4096 channels with a
    /// plausible beam energy.
    func testTheFEIExampleSpectrumOpensAsASpectrum() throws {
        let path = try Self.reference("mac4DSTEM/velox-parity/fei_emd_files/fei_emd_spectrum.emd")
        XCTAssertEqual(FileRouting.inventory(path: path), FileInventory(singleSpectrum: true))
        let loaded = try FileRouting.spectrumFile(path: path)
        XCTAssertEqual(loaded.metadata.channelCount, 4096)
        XCTAssertGreaterThan(loaded.image.sum(mask: nil).reduce(0, +), 0)
    }

    /// The three Velox files of the study each hold images AND spectrum streams (the EELS one also an EELS cube): the file decides, so the
    /// inventory says image + EDS (+ EELS), and the landing room is the spectrum cube's, never the image's. Red under: images first.
    func testAVeloxSpectrumImageIsAnImageAndAnEDSCubeAndLandsInEDS() throws {
        let small = FileRouting.inventory(path: try Self.reference("mac4DSTEM/velox-parity/velox_emd_version11/Test SI 16x16 215 kx.emd"))
        XCTAssertEqual(small, FileInventory(image: true, edsSpectrumImage: true))
        XCTAssertEqual(small.landing, .eds)
        let dual = FileRouting.inventory(path: try Self.reference("mac4DSTEM/velox-parity/velox_EELS_EDS/example_velox_EELS_EDS.emd"))
        XCTAssertEqual(dual, FileInventory(image: true, edsSpectrumImage: true, eelsSpectrumImage: true))
        XCTAssertEqual(dual.landing, .eds)
        let loaded = try EDXOpening.open(url: URL(fileURLWithPath: try Self.reference("mac4DSTEM/velox-parity/velox_emd_version11/Test SI 16x16 215 kx.emd")))
        XCTAssertEqual(loaded.metadata.scanWidth, 16); XCTAssertEqual(loaded.metadata.scanHeight, 16)
    }

    /// The study's own file (1.7 GB, in the data folder): inventoried from its group names without reading a pixel.
    func testTheStudyFileIsAnImageAndAnEDSCube() throws {
        let data = ProcessInfo.processInfo.environment["MACEM_DATA"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data").path
        let path = data + "/stem-edx/SI HAADF 1456 77000 x 20260420.emd"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "not skipped on Paul's Mac: the study file is not here")
        XCTAssertEqual(FileRouting.inventory(path: path), FileInventory(image: true, edsSpectrumImage: true))
    }

    /// Opening a file with a spectrum cube fills BOTH rooms (the image item and the EDS session) and lands in EDS; the Image room's data is
    /// not dropped by the switch. A spectrum-only file leaves the Image room disabled with its reason.
    @MainActor func testOpeningAVeloxSpectrumImageFillsTheImageAndTheEDSRoomsAndLandsInEDS() async throws {
        let path = try Self.reference("mac4DSTEM/velox-parity/velox_emd_version11/Test SI 16x16 215 kx.emd")
        let state = AppState(launch: LaunchOptions(arguments: []))
        XCTAssertEqual(state.navigation.workspaceArea, .image)
        await state.open(urls: [URL(fileURLWithPath: path)])?.value
        XCTAssertEqual(state.navigation.workspaceArea, .edx, "the file decides, not the room the window was in")
        for _ in 0..<4000 where !state.edx.hasImage { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(state.edx.hasImage, "the EDS room has the cube")
        XCTAssertEqual(state.openItems.items.count, 1, "and the Image room has the image")
        state.selectWorkspace(.image)
        XCTAssertEqual(state.navigation.workspaceArea, .image, "switching rooms drops nothing")
        XCTAssertTrue(state.edx.hasImage)
        XCTAssertNil(state.roomUnavailableReason(.edx)); XCTAssertNil(state.roomUnavailableReason(.image))
        XCTAssertNotNil(state.roomUnavailableReason(.eels), "no EELS cube in this file")
        XCTAssertNotNil(state.roomUnavailableReason(.diffraction), "the file's image is a HAADF scan image, not a pattern")
        XCTAssertNil(state.roomUnavailableReason(.fft))
    }

    /// The rooms a window's documents fill: with nothing open every built room stays enterable; with an image only, the spectrum rooms say
    /// why not; with a spectrum cube only, the image rooms do; the room that loses its data gives way to one that has some.
    func testRoomAvailabilityFollowsTheDocuments() {
        let none = RoomHoldings()
        for area in WorkspaceArea.allCases where area.isBuilt { XCTAssertNil(RoomAvailability.reason(area, holdings: none), "\(area)") }
        let image = RoomHoldings(images: true)
        XCTAssertNil(RoomAvailability.reason(.fft, holdings: image))
        XCTAssertNotNil(RoomAvailability.reason(.edx, holdings: image))
        XCTAssertNotNil(RoomAvailability.reason(.eels, holdings: image))
        let cube = RoomHoldings(eds: true)
        XCTAssertNil(RoomAvailability.reason(.edx, holdings: cube))
        XCTAssertNotNil(RoomAvailability.reason(.image, holdings: cube))
        XCTAssertNotNil(RoomAvailability.reason(.results, holdings: cube))
        XCTAssertEqual(RoomAvailability.fallback(holdings: cube), .edx)
        XCTAssertEqual(RoomAvailability.fallback(holdings: image), .image)
        XCTAssertEqual(RoomAvailability.fallback(holdings: RoomHoldings(images: true, eds: true)), .image)
        // The HAADF of a spectrum-image file is a scan image: Image, FFT and Results take it, Diffraction does not. Red under: Diffraction enabled for it.
        let companion = RoomHoldings(images: true, eds: true, imagesAreSpectrumCompanions: true)
        XCTAssertNil(RoomAvailability.reason(.image, holdings: companion)); XCTAssertNil(RoomAvailability.reason(.fft, holdings: companion))
        XCTAssertNotNil(RoomAvailability.reason(.diffraction, holdings: companion))
        XCTAssertNil(RoomAvailability.reason(.diffraction, holdings: RoomHoldings(images: true, eds: true)), "an image file beside the cube is a candidate pattern")
    }
}

private nonisolated extension Data {
    func replacingBytes(_ a: String, with b: String) -> Data {
        guard let text = String(data: self, encoding: .isoLatin1) else { return self }
        return Data(text.replacingOccurrences(of: a, with: b).utf8)
    }
}
