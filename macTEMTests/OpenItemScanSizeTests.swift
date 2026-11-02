//
//  OpenItemScanSizeTests.swift
//  The Open Files row of a spectrum image states the scan, not the size of the image the file also holds: a GMS DM4 spectrum image's image is
//  its survey (2048 × 2048 beside a 432 × 172 scan on a real file, 2026-11-02). The scan comes from the DM4 header (`FileInventory.scan`).
//  A Velox spectrum image's image is the scan image itself, so its row already states the scan; checked on the parity example when it is there.
//
//  THE TRUTH: the planted EELS DM4 (`Fixtures/eels-planted.dm4`: a 3 × 2 scan of 5 channels, `EELSRoomTests`) and a planted row format.
//

import XCTest
import ImagoCore
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class OpenItemScanSizeTests: XCTestCase {
    private static let planted = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/eels-planted.dm4")

    /// The inventory reads the scan from the header: x fastest, then y. Red under: no scan; x and y swapped.
    func testTheInventoryReadsTheScanOfADM4SpectrumImage() throws {
        let inventory = FileRouting.inventory(path: Self.planted.path)
        XCTAssertTrue(inventory.eelsSpectrumImage)
        let scan = try XCTUnwrap(inventory.scan)
        XCTAssertEqual(scan.width, 3); XCTAssertEqual(scan.height, 2)
        let loaded = try EELSOpening.open(url: Self.planted)
        XCTAssertEqual(scan.width, loaded.image.nx); XCTAssertEqual(scan.height, loaded.image.ny, "the scan the EELS room reads")
        XCTAssertNil(FileRouting.inventory(path: FileRoutingTests.fixture("planted-2d.dm4")).scan, "an image is not a scan")
    }

    /// A row with a scan states the scan and its sampling; without one, the image's size as before.
    func testARowStatesTheScanWhenTheFileHasOne() {
        let survey = AxisCalibration(scale: 2.5, unit: "nm")
        let scan = FileInventory.Scan(width: 432, height: 172, xScale: 11.6, xUnit: "nm")
        let shown = OpenItemRowFormat.shown(width: 2048, height: 2048, x: survey, scan: scan)
        XCTAssertEqual(OpenItemRowFormat.size(width: shown.width, height: shown.height), "432 × 172")
        XCTAssertEqual(shown.x, AxisCalibration(scale: 11.6, unit: "nm"))
        let plain = OpenItemRowFormat.shown(width: 2048, height: 2048, x: survey, scan: nil)
        XCTAssertEqual(OpenItemRowFormat.size(width: plain.width, height: plain.height), "2048 × 2048")
        XCTAssertEqual(plain.x, survey)
        let uncalibrated = OpenItemRowFormat.shown(width: 2048, height: 2048, x: survey, scan: FileInventory.Scan(width: 3, height: 2))
        XCTAssertNil(uncalibrated.x, "the survey's sampling is not the scan's")
    }

    /// The app's Open keeps the scan of the file it opened, for its row. Red under: the scan dropped at Open.
    @MainActor func testTheAppsOpenKeepsTheScanForTheRow() async throws {
        let url = try FileRoutingTests.temp("eels.dm4", Data(contentsOf: Self.planted))
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [url])?.value
        XCTAssertEqual(state.spectrumScans[url]?.width, 3)
        XCTAssertEqual(state.spectrumScans[url]?.height, 2)
    }

    /// EDS: a Velox spectrum image's image is drawn on the scan grid, so the row's size is the scan the EDS room reads (16 × 16 on the parity
    /// example). Skipped without the example file.
    @MainActor func testAVeloxSpectrumImageRowIsTheScanTheEDSRoomReads() async throws {
        let path = try FileRoutingTests.reference("mac4DSTEM/velox-parity/velox_emd_version11/Test SI 16x16 215 kx.emd")
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [URL(fileURLWithPath: path)])?.value
        await state.openItems.settled()
        let summary = try XCTUnwrap(state.openItems.items.first?.summary)
        let shown = OpenItemRowFormat.shown(width: summary.width, height: summary.height, x: summary.x, scan: state.spectrumScans[URL(fileURLWithPath: path)])
        XCTAssertEqual(OpenItemRowFormat.size(width: shown.width, height: shown.height), "16 × 16")
    }
}
