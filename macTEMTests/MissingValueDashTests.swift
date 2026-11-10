//
//  MissingValueDashTests.swift
//  A missing value is one dash in every room (#272): the EELS results table's I, at% and wt% cells, the Regions table's t/λ and per-edge
//  cells and the FFT room's empty region fields show `UnitDisplay.noValue` ("—"), as the SEM rooms' tables do (`SEMNumberFormatTests`).
//  Screen text only: the results CSV writes its own numbers, and a range ("300–800 eV") keeps its en dash.
//

import XCTest
import TEMCore

nonisolated final class MissingValueDashTests: XCTestCase {
    private func row(intensity: Double?, atomic: Double? = nil) -> EELSEdgeRow {
        EELSEdgeRow(id: "C_K", title: "C K", onsetEV: 284, intensity: intensity, arealDensityPerNM2: nil, atomicPercent: atomic,
                    weightPercent: nil, unavailable: nil)
    }

    /// The EELS results cells without a value, and a composition that is not finite, show the one dash; a cell with a value keeps its
    /// text. Red before: each wrote an en dash ("–").
    func testTheEELSCellsWithoutAValueShowTheOneDash() {
        let en = Locale(identifier: "en_US")
        let bare = row(intensity: nil)
        XCTAssertEqual(EELSRoomFormat.intensityText(bare, locale: en), UnitDisplay.noValue)
        XCTAssertEqual(EELSRoomFormat.atomicText(bare, locale: en), UnitDisplay.noValue)
        XCTAssertEqual(EELSRoomFormat.weightText(bare, locale: en), UnitDisplay.noValue)
        for v in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(EELSRoomFormat.percent(v, 0.3, locale: en), UnitDisplay.noValue, "\(v)")
        }
        XCTAssertEqual(EELSRoomFormat.atomicText(row(intensity: 1, atomic: 44.4), locale: en), "44.4")
    }

    /// The Regions table's t/λ, I and at% cells and the FFT room's empty Left, Top and Size fields take the same dash. Red before: an
    /// en dash in all four places.
    func testTheRegionsTableAndTheFFTFieldsShowTheOneDash() throws {
        let regions = try FFTRoomWiringTests.squeezedUI("EELSRegionsTable.swift")
        XCTAssertEqual(regions.components(separatedBy: "?? UnitDisplay.noValue)").count - 1, 3, "the t/λ, I and at% cells")
        XCTAssertFalse(regions.contains("\u{2013}"), "no en dash stands for a missing value")
        let fft = try FFTRoomWiringTests.squeezedUI("FFTRoomInspector.swift")
        XCTAssertTrue(fft.contains("unit: \"px\", prompt: UnitDisplay.noValue, onCommit: commit)"), "the empty region field's prompt")
        XCTAssertFalse(fft.contains("prompt: \"\u{2013}\""))
    }
}
