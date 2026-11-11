//
//  SEMEDSStateTests.swift
//  The EDS room's SEM additions (macTEM#278, #272, #267 for the EDS rows): `SEMEDSState` reads the shipped BAM TM002 spectrum into
//  exspy's line table and clears on any other file, and the SEM-EDS words and session rows write their numbers in the locale they are
//  given, never grouped, with UnitDisplay's dash for a non-finite value.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class SEMEDSStateTests: XCTestCase {
    private static let us = Locale(identifier: "en_US")
    private static let de = Locale(identifier: "de_DE")
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The shipped SEM spectrum: an SEM file with exspy's five lines at 10 kV, the conditions the file states; the same path again changes
    /// nothing; a file that is not an SEM `.hspy`, and no file, clear it. Mutation: the state keeps the last table for another file.
    @MainActor func testTheStateReadsTheShippedSpectrumAndClearsOnAnyOtherFile() async throws {
        let state = SEMEDSState()
        let path = try XCTUnwrap(DemoDocuments.Shipped.semEDSSpectrum.url).path
        await state.load(path: path)
        XCTAssertTrue(state.isSEMSpectrum)
        XCTAssertEqual(state.rows.map(\.line), ["Al_Ka", "C_Ka", "Cu_La", "Mn_La", "Zr_La"])
        XCTAssertEqual(state.spectrum?.conditions.beamEnergyKeV, 10)
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.rows.allSatisfy { $0.backgroundWindows?.count == 4 }, "exspy's tutorial subtracts two background windows per line")

        await state.load(path: path)
        XCTAssertEqual(state.rows.count, 5)

        let nickel = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url).path
        await state.load(path: nickel)
        XCTAssertFalse(state.isSEMSpectrum)
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.path, nickel)

        await state.load(path: path)
        await state.load(path: nil)
        XCTAssertFalse(state.isSEMSpectrum)
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertNil(state.path)
    }

    /// The words: counts never grouped, keV with three places in the locale given, UnitDisplay's dash for a non-finite value, no "-0".
    /// Mutation: the system's grouping ("12,345") or the formatter's own "NaN" and "-0.000".
    func testTheSEMEDSWordsTakeTheirLocaleUngroupedWithOneDash() {
        XCTAssertEqual(SEMEDSFormat.counts(12345, locale: Self.us), "12345")
        XCTAssertEqual(SEMEDSFormat.counts(12345, locale: Self.de), "12345")
        XCTAssertEqual(SEMEDSFormat.keV(1.4866, locale: Self.de), "1,487")
        XCTAssertEqual(SEMEDSFormat.keV(1.4866, locale: Self.posix), "1.487")
        XCTAssertEqual(SEMEDSFormat.keV(.nan, locale: Self.us), UnitDisplay.number(.nan))
        XCTAssertEqual(SEMEDSFormat.counts(.infinity, locale: Self.us), UnitDisplay.number(.infinity))
        XCTAssertEqual(SEMEDSFormat.keV(-0.0001, locale: Self.us), "0.000")
        XCTAssertEqual(SEMEDSFormat.keV(-0.043, locale: Self.us), "-0.043")
    }

    /// The words take printf's digits through `UnitDisplay.fixed`, so a decimal tie reads as the CSV beside it. Red before: FormatStyle
    /// rounded the shortest decimal spelling, "0.4" and "5.898" (the binary values are 0.34999… and 5.89749…).
    func testTheSEMEDSWordsRoundAsPrintf() {
        XCTAssertEqual(SEMEDSFormat.fixed(0.35, 1, locale: Self.posix), "0.3")
        XCTAssertEqual(SEMEDSFormat.keV(5.8975, locale: Self.posix), "5.897")
        XCTAssertEqual(SEMEDSFormat.fixed(0.35, 1, locale: Self.de), UnitDisplay.fixed(0.35, places: 1, locale: Self.de))
    }

    /// The SEM Conditions rows in the locale given, never grouped: the live time and the take-off angle at one place, the others as
    /// `UnitDisplay.number` writes them; a row the file does not state is left out. Red before: no `conditionRows`; the view wrote the
    /// rows with FormatStyle in the system's locale, "1.234,5 s" in German.
    func testTheConditionRowsAreNeverGrouped() throws {
        let c = SEMEDSLines.Conditions(beamEnergyKeV: 20, energyResolutionMnKaEV: 128.5, elevationAngleDeg: 35, tiltAlphaDeg: 0,
                                       liveTimeS: 1234.5)
        let de = SEMEDSFormat.conditionRows(c, microscope: "Zeiss", locale: Self.de)
        XCTAssertEqual(de.map(\.label), ["Microscope", "Beam", SEMEDSFormat.takeOff, "Elevation", "Stage tilt", "Resolution", "Live time"])
        let values = Dictionary(uniqueKeysWithValues: de.map { ($0.label, $0.value) })
        XCTAssertEqual(values["Microscope"], "SEM · Zeiss")
        XCTAssertEqual(values["Beam"], "20 kV")
        XCTAssertEqual(values[SEMEDSFormat.takeOff], "\(UnitDisplay.fixed(c.takeOffAngleDeg, places: 1, locale: Self.de))°")
        XCTAssertEqual(values["Elevation"], "35°")
        XCTAssertEqual(values["Stage tilt"], "0°")
        XCTAssertEqual(values["Resolution"], "128,5 eV at Mn Kα")
        XCTAssertEqual(values["Live time"], "1234,5 s")
        let posix = SEMEDSFormat.conditionRows(c, microscope: nil, locale: Self.posix)
        XCTAssertEqual(posix.first?.value, "SEM")
        XCTAssertEqual(posix.last?.value, "1234.5 s")

        let bare = SEMEDSFormat.conditionRows(SEMEDSLines.Conditions(beamEnergyKeV: nil), microscope: nil, locale: Self.us)
        XCTAssertEqual(bare.map(\.label), ["Microscope", SEMEDSFormat.takeOff, "Elevation", "Stage tilt", "Resolution"],
                       "no beam and no live time in the file: no rows for them")
    }

    /// The session rows of the spectrum's lines in the locale the report asks for: one decimal mark through the row, ungrouped counts,
    /// no k-factor or composition of their own (the shared EDS room quantifies, D-SEM-107). Mutation: a row in the reader's locale
    /// inside a POSIX report, or a grouped count.
    @MainActor func testTheSpectrumsSessionRowsWriteTheLocaleTheyAreGiven() async throws {
        let state = SEMEDSState()
        await state.load(path: try XCTUnwrap(DemoDocuments.Shipped.semEDSSpectrum.url).path)
        let posix = SEMSessionLedger.compositionRows(state, locale: Self.posix)
        XCTAssertEqual(posix.map(\.label), ["Al Kα", "C Kα", "Cu Lα", "Mn Lα", "Zr Lα"])
        let al = try XCTUnwrap(posix.first)
        XCTAssertEqual(al.fields.map(\.name), ["Energy", "Window", "Intensity"])
        XCTAssertEqual(al.fields.first?.value, "1.486 keV")   // Al Kα 1.4865 keV, below the half in binary
        XCTAssertFalse(al.value.contains(","), al.value)
        XCTAssertTrue(al.value.hasSuffix(" counts"), al.value)
        XCTAssertEqual(al.methods, [.edsLines])
        let de = try XCTUnwrap(SEMSessionLedger.compositionRows(state, locale: Self.de).first)
        XCTAssertEqual(de.fields.first?.value, "1,486 keV")
        XCTAssertFalse(de.value.contains("."), de.value)
    }
}
