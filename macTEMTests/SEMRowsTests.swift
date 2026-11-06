//
//  SEMRowsTests.swift
//  The Image room's SEM section wording (ImageRoomSEM.swift, `SEMRows`): the rows in order, each number at 7 significant digits in
//  its unit, the pixel size in the unit the pixel reads in, the stage in mm, a field the file lacks left out, and the notes
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

    func testTheZeissRowsInOrder() {
        let rows = SEMRows.rows(zeiss(), locale: en)
        XCTAssertEqual(rows.map(\.id), ["vendor", "instrument", "pixelSize", "beamEnergy", "magnification", "workingDistance", "detector",
                                        "dwell", "beamCurrent", "spot", "chamberPressure", "stage", "acquired", "user", "databar"])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["vendor"]?.value, "Zeiss")
        XCTAssertNil(byID["vendor"]?.note)
        XCTAssertEqual(byID["pixelSize"]?.value, "2.614514 µm/px")
        XCTAssertEqual(byID["beamEnergy"]?.value, "25 kV")
        XCTAssertEqual(byID["magnification"]?.value, "105×")
        XCTAssertEqual(byID["workingDistance"]?.value, "14.808 mm")
        XCTAssertEqual(byID["detector"]?.value, "HE-SE2")
        XCTAssertNil(byID["detector"]?.note, "RosettaSciIO maps the Zeiss detector")
        XCTAssertEqual(byID["dwell"]?.value, "0.05 µs")
        XCTAssertEqual(byID["beamCurrent"]?.value, "1 nA")
        XCTAssertEqual(byID["spot"]?.value, "1")
        XCTAssertEqual(byID["spot"]?.note, SEMImageMetadata.unvalidatedNote)
        XCTAssertEqual(byID["chamberPressure"]?.value, "0.000187 Pa")
        XCTAssertEqual(byID["stage"]?.value, "x 75.6442 · y 60.4901 · z 25.193 mm · R 10.2° · T 0°")
        XCTAssertEqual(byID["acquired"]?.value, "2015-12-23 09:40:32")
        XCTAssertEqual(byID["user"]?.value, "LIM")
        XCTAssertEqual(byID["databar"]?.value, "Drawn into the scan")
        XCTAssertEqual(byID["databar"]?.note, SEMImageMetadata.zeissDatabarNote)
    }

    func testAThermoFileShowsItsDatabarAndStageInMillimetresFromMetres() {
        var m = SEMImageMetadata(vendor: .thermo, imageWidth: 512, imageHeight: 471, stageUnit: "m")
        m.pixelSizeX = 3.3724e-6; m.pixelSizeY = 3.3724e-6
        m.detector = "ETD"; m.stageX = 2.576e-05; m.stageY = 0.000194177; m.stageZ = 0.007965; m.stageRotationDeg = 2.3611
        m.magnificationText = nil; m.databarRows = 29; m.date = "2016-06-13"
        let byID = Dictionary(uniqueKeysWithValues: SEMRows.rows(m, locale: en).map { ($0.id, $0) })
        XCTAssertEqual(byID["vendor"]?.value, "Thermo Fisher / FEI")
        XCTAssertEqual(byID["detector"]?.note, SEMImageMetadata.unvalidatedNote, "RosettaSciIO does not map the Thermo detector")
        XCTAssertEqual(byID["stage"]?.value, "x 0.02576 · y 0.194177 · z 7.965 mm · R 2.3611°")
        XCTAssertEqual(byID["databar"]?.value, "29 rows under a 442-row scan")
        XCTAssertEqual(byID["acquired"]?.value, "2016-06-13", "the date alone when the time is missing")
        XCTAssertNil(byID["magnification"], "a field the file lacks is left out")
        XCTAssertNil(byID["beamEnergy"])
    }

    func testATescanFileCarriesTheTescanNoteOnceAndItsSpotInNanometres() {
        var m = SEMImageMetadata(vendor: .tescan, imageWidth: 1024, imageHeight: 840, stageUnit: "m")
        m.spotSize = 1.1e-8; m.spotSizeUnit = "m"; m.chamberPressurePa = 0.009; m.databarRows = 72
        m.pixelSizeX = 2.5e-8; m.pixelSizeY = 3e-8
        let byID = Dictionary(uniqueKeysWithValues: SEMRows.rows(m, locale: en).map { ($0.id, $0) })
        XCTAssertEqual(byID["vendor"]?.note, SEMImageMetadata.tescanNote)
        XCTAssertEqual(byID["spot"]?.value, "11 nm")
        XCTAssertNil(byID["spot"]?.note, "the Tescan note is on the vendor row, once")
        XCTAssertNil(byID["chamberPressure"]?.note)
        XCTAssertEqual(byID["pixelSize"]?.value, "25 × 30 nm/px", "two sizes when the axes differ")
        XCTAssertEqual(byID["databar"]?.value, "72 rows under a 768-row scan")
    }

    func testTheGermanLocaleWritesTheComma() {
        let byID = Dictionary(uniqueKeysWithValues: SEMRows.rows(zeiss(), locale: Locale(identifier: "de_DE")).map { ($0.id, $0) })
        XCTAssertEqual(byID["workingDistance"]?.value, "14,808 mm")
        XCTAssertEqual(byID["pixelSize"]?.value, "2,614514 µm/px")
    }
}
