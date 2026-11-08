//
//  MapsFigureLabelTests.swift
//  The words burned into the Maps room's Map PNG and Texture PNG and into the EELS room's maps PNG are in `ExportSnapshot.labelLocale`
//  (en_US_POSIX), not the reader's: a de_DE reader still gets "0.5 to 2.25" in a figure, as from the Image room. The screen keeps the
//  reader's locale. The process locale cannot be changed from inside a test, so each check pins the default against the literal and
//  de_DE is the control that the literal separates the two locales. Red before: the label helpers and the tile's `detailText(locale:)`
//  do not exist, and the figures wrote their numbers in the reader's locale.
//

import Foundation
import TEMCore
import XCTest
@testable import macTEM

nonisolated final class MapsFigureLabelTests: XCTestCase {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let german = Locale(identifier: "de_DE")

    /// The legend's value range of a property or derived layer. Red under: the range made in the reader's locale (on a Mac that
    /// writes a comma); the default moved off `labelLocale`.
    func testTheRangeLabelIsInPOSIXWhateverTheReadersLocale() {
        XCTAssertEqual(MapsFigure.rangeLabel(0.5...2.25), "0.5 to 2.25")
        XCTAssertEqual(MapsFigure.rangeLabel(0.5...2.25), MapsFigure.rangeLabel(0.5...2.25, locale: Self.posix))
        XCTAssertEqual(MapsFigure.rangeLabel(0.5...2.25, locale: Self.german), "0,5 to 2,25", "the control: de_DE writes a comma")
        XCTAssertEqual(ExportSnapshot.labelLocale.identifier, "en_US_POSIX")
    }

    /// The scale bar under the map ("um" as the files write it, shown as µm) and a texture figure's colour bar maximum.
    func testTheScaleBarAndTheColourBarLabelsAreInPOSIX() {
        XCTAssertEqual(MapsFigure.scaleBarLabel(length: 0.5, unit: "um"), "0.5 \u{00B5}m")
        XCTAssertEqual(MapsFigure.scaleBarLabel(length: 0.5, unit: "um", locale: Self.german), "0,5 \u{00B5}m", "the control")
        XCTAssertEqual(MapsFigure.mrdLabel(3.214), "0 to 3.21 MRD")
        XCTAssertEqual(MapsFigure.mrdLabel(3.214, locale: Self.german), "0 to 3,21 MRD", "the control")
    }

    /// A flat EELS tile's line under its name, as the maps figure passes the export's locale. Red under: the figure's detail made in
    /// the reader's locale (the locale ignored by `detailText(locale:)` or `flatValueText(locale:)`).
    func testAFlatEELSTileIsLabelledInPOSIXInTheFigure() {
        let tile = EELSMapTile(id: "zlpShift", title: "ZLP shift", unit: "eV", width: 2, height: 1, values: [0.5, 0.5], version: 1, footer: nil)
        XCTAssertEqual(tile.detailText(locale: ExportSnapshot.labelLocale), "every pixel 0.5 eV")
        XCTAssertEqual(tile.detailText(locale: Self.german), "every pixel 0,5 eV", "the control")
        XCTAssertEqual(tile.flatValueText(locale: ExportSnapshot.labelLocale), "0.5 eV")
        let ranged = EELSMapTile(id: "i0", title: "I0", unit: "counts", width: 2, height: 1, values: [1, 2], version: 1, footer: nil)
        XCTAssertEqual(ranged.detailText(locale: ExportSnapshot.labelLocale), "counts", "a tile with a range names its unit")
    }
}
