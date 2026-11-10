//
//  SEMRowsTests.swift
//  The Image room's SEM rows (ImageRoomSEM.swift, `SEMRows`): the design's order, each number at 7 significant digits in its unit,
//  the pixel and scan sizes in the unit they read in, a field the file lacks left out, beam current before spot, and the notes
//  (RosettaSciIO's unmapped fields, the Zeiss data zone, the Tescan reader) where they belong.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class SEMRowsTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func zeiss() -> SEMImageMetadata {
        var m = SEMImageMetadata(vendor: .zeiss, imageWidth: 1024, imageHeight: 768, stageUnit: "mm")
        m.pixelSizeX = 2.614514e-6; m.pixelSizeY = 2.614514e-6
        m.beamEnergyKV = 25; m.magnification = 105; m.workingDistanceMM = 14.808; m.detector = "HE-SE2"
        m.dwellS = 5e-8; m.beamCurrentNA = 1; m.spotSize = 1; m.chamberPressurePa = 0.000187
        m.stageX = 75.6442; m.stageY = 60.4901; m.stageZ = 25.193; m.stageRotationDeg = 10.2; m.stageTiltDeg = 0
        m.instrument = "Merlin-61-08"; m.date = "2015-12-23"; m.time = "09:40:32"; m.user = "LIM"
        return m
    }

    private func byID(_ m: SEMImageMetadata, _ locale: Locale) -> [String: SEMRows.Row] {
        Dictionary(uniqueKeysWithValues: SEMRows.rows(m, locale: locale).map { ($0.id, $0) })
    }

    /// An SEM file's Acquisition section shows each field once: the TEM rows the SEM rows repeat and the TEM-only placeholders go,
    /// and a TEM reading the SEM rows lack stays (D-SEM-108). Mutation: all nine TEM rows above the SEM rows, as on the drive.
    func testTheTEMRowsBesideTheSEMRowsShowEachFieldOnce() {
        func row(_ id: String, _ value: String, placeholder: Bool = false) -> AcquisitionRows.Row {
            AcquisitionRows.Row(id: id, label: id, value: value, note: nil, isPlaceholder: placeholder, spokenValue: value)
        }
        let tem = [row("highTension", "25 kV"), row("magnification", "105×"), row("cameraLength", "Not recorded", placeholder: true),
                   row("detector", "HE-SE2"), row("dwell", "0.05 µs"), row("exposure", "Not recorded", placeholder: true),
                   row("acquired", "2015-12-23 09:40:32"), row("instrument", "Merlin"), row("mode", "Not recorded", placeholder: true)]
        XCTAssertEqual(AcquisitionRows.rows(beside: zeiss(), from: tem, locale: en).map(\.id), [],
                       "every TEM reading is an SEM row already, and the placeholders are TEM-only")
        var bare = zeiss()
        bare.magnification = nil; bare.magnificationText = nil
        XCTAssertEqual(AcquisitionRows.rows(beside: bare, from: tem, locale: en).map(\.id), ["magnification"],
                       "the TIFF's magnification stays when the vendor rows have none")
    }

    func testTheZeissRowsInTheDesignsOrder() {
        let rows = SEMRows.rows(zeiss(), locale: en)
        XCTAssertEqual(rows.map(\.id), ["instrument", "detector", "hv", "beamCurrent", "workingDistance", "magnification", "dwell",
                                        "pixelSize", "scanSize", "stageTilt", "stageRotation", "vacuum", "date", "databar"])
        let r = byID(zeiss(), en)
        XCTAssertEqual(r["instrument"]?.value, "Merlin-61-08")
        XCTAssertNil(r["instrument"]?.note)
        XCTAssertEqual(r["detector"]?.value, "HE-SE2")
        XCTAssertNil(r["detector"]?.note, "RosettaSciIO maps the Zeiss detector")
        XCTAssertEqual(r["hv"]?.value, "25 kV")
        XCTAssertEqual(r["beamCurrent"]?.value, "1 nA")
        XCTAssertNil(r["spot"], "beam current or spot: the current when the file has it")
        XCTAssertEqual(r["workingDistance"]?.value, "14.808 mm")
        XCTAssertEqual(r["magnification"]?.value, "105×")
        XCTAssertEqual(r["dwell"]?.value, "0.05 µs")
        XCTAssertEqual(r["pixelSize"]?.value, "2.614514 µm/px")
        XCTAssertEqual(r["scanSize"]?.value, "2.677262 × 2.007947 mm")
        XCTAssertEqual(r["stageTilt"]?.value, "0°")
        XCTAssertEqual(r["stageRotation"]?.value, "10.2°")
        XCTAssertEqual(r["vacuum"]?.value, "0.000187 Pa")
        XCTAssertEqual(r["vacuum"]?.note, SEMImageMetadata.unvalidatedNote)
        XCTAssertEqual(r["date"]?.value, "2015-12-23 09:40:32")
        XCTAssertEqual(r["databar"]?.value, "Drawn into the scan")
        XCTAssertEqual(r["databar"]?.note, SEMImageMetadata.zeissDatabarNote)
    }

    func testAThermoFileShowsItsSpotWithoutACurrentAndItsDatabar() {
        var m = SEMImageMetadata(vendor: .thermo, imageWidth: 512, imageHeight: 471, stageUnit: "m")
        m.pixelSizeX = 3.3724e-6; m.pixelSizeY = 3.3724e-6
        m.detector = "ETD"; m.spotSize = 1; m.stageRotationDeg = 2.3611
        m.databarRows = 29; m.date = "2016-06-13"
        let r = byID(m, en)
        XCTAssertEqual(r["instrument"]?.value, "Thermo Fisher / FEI", "the vendor stands in for a missing instrument name")
        XCTAssertEqual(r["detector"]?.note, SEMImageMetadata.unvalidatedNote, "RosettaSciIO does not map the Thermo detector")
        XCTAssertEqual(r["spot"]?.value, "1")
        XCTAssertEqual(r["spot"]?.note, SEMImageMetadata.unvalidatedNote)
        XCTAssertNil(r["beamCurrent"])
        XCTAssertEqual(r["scanSize"]?.value, "1.726669 × 1.490601 mm", "512 × 442 pixels of 3.3724 µm: the databar excluded")
        XCTAssertEqual(r["stageRotation"]?.value, "2.3611°")
        XCTAssertEqual(r["databar"]?.value, "29 rows under a 442-row scan")
        XCTAssertEqual(r["date"]?.value, "2016-06-13", "the date alone when the time is missing")
        XCTAssertNil(r["magnification"], "a field the file lacks is left out")
        XCTAssertNil(r["hv"])
        XCTAssertNil(r["stageTilt"])
    }

    func testATescanFileCarriesTheTescanNoteOnceAndItsSpotInNanometres() {
        var m = SEMImageMetadata(vendor: .tescan, imageWidth: 1024, imageHeight: 840, stageUnit: "m")
        m.instrument = "MIRA3 LMU"; m.spotSize = 1.1e-8; m.spotSizeUnit = "m"; m.chamberPressurePa = 0.009; m.databarRows = 72
        m.pixelSizeX = 2.5e-8; m.pixelSizeY = 3e-8
        let r = byID(m, en)
        XCTAssertEqual(r["instrument"]?.note, SEMImageMetadata.tescanNote)
        XCTAssertEqual(r["spot"]?.value, "11 nm")
        XCTAssertNil(r["spot"]?.note, "the Tescan note is on the instrument row, once")
        XCTAssertNil(r["vacuum"]?.note)
        XCTAssertEqual(r["pixelSize"]?.value, "25 × 30 nm/px", "two sizes when the axes differ")
        XCTAssertEqual(r["scanSize"]?.value, "25.6 × 23.04 µm")
        XCTAssertEqual(r["databar"]?.value, "72 rows under a 768-row scan")
    }

    func testTheGermanLocaleWritesTheComma() {
        let r = byID(zeiss(), Locale(identifier: "de_DE"))
        XCTAssertEqual(r["workingDistance"]?.value, "14,808 mm")
        XCTAssertEqual(r["pixelSize"]?.value, "2,614514 µm/px")
    }
}
