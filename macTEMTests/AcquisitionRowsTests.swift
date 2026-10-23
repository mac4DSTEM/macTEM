//
//  AcquisitionRowsTests.swift
//  Pins the Info tab's Acquisition rows (`AcquisitionRows`, archive: roadmap-registrations-2026-10-15.md V1-4a, the panel): the nine labels in order,
//  the planted values with their units, **P1** every printed number reads back, in the reader's own locale, within
//  5e-7 relative of the core's value in the core's unit (awkward values, a sweep over thirteen decades, en/de/fr),
//  **P2** a nil reads "Not recorded" and never a number, a field of `unread` names its format, a note shows with its
//  row (and is spoken with it), and a differing second copy is its own row.
//
//  Registered mutations, each named by the test meant to turn it red (applied to a scratch copy of the formatter and
//  of this file, compiled bare with `swift test`, 2026-10-13; the lane's log is in the report, not the repo):
//   - nil as "0": testNothingRecordedReadsNotRecordedNeverZero, testNilReadingsNeverPrintAsANumber
//   - a note dropped: testANoteShowsBeneathItsRowAndIsSpokenWithIt, testASecondCopyIsItsOwnRowWithTheSameNote
//   - the second copy dropped: testASecondCopyIsItsOwnRowWithTheSameNote, testRowIdsAreUnique
//   - a unit converted twice (kV /1000 again; mm ×1000; µs ×1e6): testPlantedValuesPrintWithTheirUnits,
//     testEveryPrintedNumberReadsBackWithinTheRegisteredBound
//

import XCTest
import FormatoCore
import TEMCore
@testable import macTEM

nonisolated final class AcquisitionRowsTests: XCTestCase {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let german = Locale(identifier: "de_DE")
    private static let french = Locale(identifier: "fr_FR")
    private static let micro = "\u{00B5}"   // U+00B5, the micro sign the rest of the app writes in "µm"

    private typealias Field = AcquisitionMetadata.Field

    /// The five numeric fields: the row id and the unit its text ends with.
    private static let numeric: [(id: String, unit: String)] = [
        ("highTension", "kV"), ("magnification", "\u{00D7}"), ("cameraLength", "mm"), ("dwell", "\(micro)s"), ("exposure", "s"),
    ]

    private func rows(_ metadata: AcquisitionMetadata, ext: String = "tif", locale: Locale = posix) -> [AcquisitionRows.Row] {
        AcquisitionRows.rows(metadata, formatExtension: ext, locale: locale)
    }

    private static func row(_ rows: [AcquisitionRows.Row], _ id: String) throws -> AcquisitionRows.Row {
        try XCTUnwrap(rows.first { $0.id == id }, "no row \(id)")
    }

    /// Every field of the nine set to a planted reading.
    private func planted() -> AcquisitionMetadata {
        var m = AcquisitionMetadata()
        m.highTensionKV = MetadataReading(200)
        m.magnification = MetadataReading(28_500)
        m.cameraLengthMM = MetadataReading(245)
        m.detector = MetadataReading("Ceta")
        m.dwellUS = MetadataReading(2)
        m.exposureS = MetadataReading(0.5)
        m.acquired = MetadataReading("2026-03-05 14:22:01")
        m.instrument = MetadataReading("Titan Themis")
        m.mode = MetadataReading("STEM")
        return m
    }

    /// The five numeric fields all set to `value`.
    private func numbers(_ value: Double) -> AcquisitionMetadata {
        var m = AcquisitionMetadata()
        m.highTensionKV = MetadataReading(value)
        m.magnification = MetadataReading(value)
        m.cameraLengthMM = MetadataReading(value)
        m.dwellUS = MetadataReading(value)
        m.exposureS = MetadataReading(value)
        return m
    }

    /// The number in a row's text, read in `locale` strictly (the lenient parse is the one that read a German "0.0275" as 275).
    private func number(in row: AcquisitionRows.Row, unit: String, locale: Locale, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        XCTAssertTrue(row.value.hasSuffix(unit), "\(row.id) '\(row.value)' does not end in \(unit)", file: file, line: line)
        let text = row.value.dropLast(unit.count).trimmingCharacters(in: .whitespaces)
        return try Double(text, format: .number.locale(locale), lenient: false)
    }

    // MARK: The panel's order and wording

    /// The nine rows, in the panel's order, with the registered labels.
    func testTheNineRowsComeInThePanelsOrderWithTheirLabels() {
        let all = rows(planted())
        XCTAssertEqual(all.map(\.id), Field.allCases.map(\.rawValue))
        XCTAssertEqual(all.map(\.label), ["High tension", "Magnification", "Camera length", "Detector", "Dwell",
                                          "Exposure", "Acquired", "Instrument", "Mode"])
        XCTAssertTrue(all.allSatisfy { !$0.isPlaceholder && $0.note == nil })
    }

    /// Mutation: a unit converted twice (kV /1000 again, mm ×1000, µs ×1e6) — "0.2 kV", "245000 mm" instead of the planted text.
    func testPlantedValuesPrintWithTheirUnits() throws {
        let all = rows(planted())
        let expected = ["highTension": "200 kV", "magnification": "28500\u{00D7}", "cameraLength": "245 mm",
                        "detector": "Ceta", "dwell": "2 \(Self.micro)s", "exposure": "0.5 s",
                        "acquired": "2026-03-05 14:22:01", "instrument": "Titan Themis", "mode": "STEM"]
        for (id, text) in expected { XCTAssertEqual(try Self.row(all, id).value, text, id) }
        // The dwell's micro sign is U+00B5, never the Greek letter mu (U+03BC).
        let dwell = try Self.row(all, "dwell").value.unicodeScalars.map(\.value)
        XCTAssertTrue(dwell.contains(0x00B5) && !dwell.contains(0x03BC))
        // The magnification's cross is U+00D7 and follows the number with no space.
        XCTAssertEqual(try Self.row(all, "magnification").value.unicodeScalars.map(\.value).last, 0x00D7)
    }

    // MARK: P1: no number moves

    private static let awkward: [Double] = [
        1.23456789e5,           // 6 digits would print 123457: 1.7e-6 off
        0.000123,
        1.0000004, 1.00000049,  // a leading digit of 1 is the worst case for the digits kept
        9.999999, 99_999.95, 9.9999996,   // rounds up across a decade
        2.0000000000000004, 195.00000000000003, 28_499.999999999996,   // float noise from a unit conversion
        1.5e-7, 123_456_789.123, 0.1 + 0.2,
    ]

    /// P1 with the registered bound: 5e-7 relative, read back in the same locale, in the core's unit. Mutation: a
    /// unit converted twice (the read-back is 1000 times off), or fewer digits (6 digits fail on 1.23456789e5).
    func testEveryPrintedNumberReadsBackWithinTheRegisteredBound() throws {
        for locale in [Self.posix, Self.german, Self.french] {
            for value in Self.awkward {
                let all = rows(numbers(value), locale: locale)
                for (id, unit) in Self.numeric {
                    let back = try number(in: Self.row(all, id), unit: unit, locale: locale)
                    XCTAssertEqual(back, value, accuracy: 5e-7 * abs(value), "\(id) \(value) in \(locale.identifier)")
                }
            }
        }
    }

    /// The same over a sweep of thirteen decades (1e-6 to 1e7), 400 values from a fixed generator, in German: the
    /// bound holds for every leading digit, not just the planted ones.
    func testASweepOfThirteenDecadesReadsBackWithinTheBound() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        for _ in 0..<400 {
            let value = pow(10, -6 + 13 * next()) * (1 + 9 * next()) / 5
            let all = rows(numbers(value), locale: Self.german)
            for (id, unit) in Self.numeric {
                let back = try number(in: Self.row(all, id), unit: unit, locale: Self.german)
                XCTAssertEqual(back, value, accuracy: 5e-7 * abs(value), "\(id) \(value)")
            }
        }
    }

    /// Why 7 digits and not the 6 of the Image section's rows: at 6 the registered bound is false (it is 5e-6 for a
    /// leading digit of 1), and the planted 1.23456789e5 kV reads back 123457.
    func testSixSignificantDigitsWouldBreakTheRegisteredBound() throws {
        XCTAssertGreaterThanOrEqual(AcquisitionRows.significantDigits, 7)
        let six = UnitDisplay.number(1.23456789e5, digits: 6, locale: Self.posix)
        XCTAssertEqual(six, "123457")
        XCTAssertGreaterThan(abs(try Double(six, format: .number.locale(Self.posix), lenient: false) - 1.23456789e5) / 1.23456789e5, 5e-7)
    }

    /// German writes the decimal comma and the row parses back with it; the same value in English reads differently.
    func testAGermanLocaleWritesItsCommaAndReadsBackWithIt() throws {
        var m = AcquisitionMetadata()
        m.exposureS = MetadataReading(0.000123)
        m.highTensionKV = MetadataReading(1.23456789e5)
        let de = rows(m, locale: Self.german)
        XCTAssertEqual(try Self.row(de, "exposure").value, "0,000123 s")
        XCTAssertEqual(try Self.row(de, "highTension").value, "123456,8 kV")
        let en = rows(m, locale: Self.posix)
        XCTAssertEqual(try Self.row(en, "exposure").value, "0.000123 s")
        XCTAssertEqual(try Self.row(en, "highTension").value, "123456.8 kV")
    }

    // MARK: P2: nothing recorded

    /// P2: every field nil → nine placeholders, "Not recorded". Mutation: nil as "0".
    func testNothingRecordedReadsNotRecordedNeverZero() {
        let all = rows(AcquisitionMetadata())
        XCTAssertEqual(all.count, 9)
        for row in all {
            XCTAssertEqual(row.value, "Not recorded", row.id)
            XCTAssertTrue(row.isPlaceholder, row.id)
            XCTAssertNil(row.note, row.id)
            XCTAssertEqual(row.spokenValue, "Not recorded", row.id)
        }
    }

    /// No placeholder carries a digit or a unit, in any locale or for any extension: a missing value is never a number.
    /// Mutation: a numeric field's nil read as a zero reading ("0 kV").
    func testNilReadingsNeverPrintAsANumber() {
        for locale in [Self.posix, Self.german] {
            for ext in ["", "tif", "emd"] {
                for row in rows(AcquisitionMetadata(), ext: ext, locale: locale) {
                    XCTAssertFalse(row.value.contains(where: \.isNumber), "\(row.id): \(row.value)")
                    for (_, unit) in Self.numeric { XCTAssertFalse(row.value.hasSuffix(unit), "\(row.id): \(row.value)") }
                }
            }
        }
    }

    /// A single recorded field leaves the other eight "Not recorded" (a nil is per field).
    func testOneRecordedFieldLeavesTheOthersNotRecorded() throws {
        var m = AcquisitionMetadata()
        m.detector = MetadataReading("HAADF")
        let all = rows(m)
        XCTAssertEqual(try Self.row(all, "detector").value, "HAADF")
        XCTAssertEqual(all.filter(\.isPlaceholder).count, 8)
        XCTAssertTrue(all.filter(\.isPlaceholder).allSatisfy { $0.value == "Not recorded" })
    }

    /// A value that is not a finite number is not printed ("—" would be): it reads "Not recorded".
    func testANonFiniteNumberIsNotShown() throws {
        var m = AcquisitionMetadata()
        m.highTensionKV = MetadataReading(Double.nan)
        m.dwellUS = MetadataReading(Double.infinity, otherCopy: Double.nan)
        let all = rows(m)
        XCTAssertEqual(try Self.row(all, "highTension").value, "Not recorded")
        XCTAssertEqual(try Self.row(all, "dwell").value, "Not recorded")
        XCTAssertEqual(all.count, 9)
        // A finite value with a non-finite second copy shows the value and no second row.
        m.exposureS = MetadataReading(0.5, otherCopy: Double.infinity)
        XCTAssertEqual(rows(m).count, 9)
        XCTAssertEqual(try Self.row(rows(m), "exposure").value, "0.5 s")
    }

    // MARK: Unread fields

    /// An `.emd`'s four unread fields name their format and never say "Not recorded"; the five the reader does read
    /// are shown or "Not recorded" as ever. Mutation: unread shown as "Not recorded".
    func testAnUnreadFieldNamesItsFormatAndIsNeverNotRecorded() throws {
        var m = AcquisitionMetadata()
        m.highTensionKV = MetadataReading(300)
        m.unread = [.magnification, .cameraLength, .exposure, .mode]
        let all = rows(m, ext: "emd")
        for id in ["magnification", "cameraLength", "exposure", "mode"] {
            let row = try Self.row(all, id)
            XCTAssertEqual(row.value, "Not read from .emd files yet", id)
            XCTAssertTrue(row.isPlaceholder, id)
            XCTAssertNil(row.note, id)
            XCTAssertEqual(row.spokenValue, "Not read from .emd files yet", id)
        }
        XCTAssertEqual(try Self.row(all, "highTension").value, "300 kV")
        for id in ["detector", "dwell", "acquired", "instrument"] { XCTAssertEqual(try Self.row(all, id).value, "Not recorded", id) }
    }

    /// The extension is spelled as the file system gives it, lower-cased and without a dot; none names no format.
    func testTheUnreadPlaceholderNormalisesTheExtension() {
        XCTAssertEqual(AcquisitionRows.notRead(formatExtension: "emd"), "Not read from .emd files yet")
        XCTAssertEqual(AcquisitionRows.notRead(formatExtension: "EMD"), "Not read from .emd files yet")
        XCTAssertEqual(AcquisitionRows.notRead(formatExtension: ".Emd"), "Not read from .emd files yet")
        XCTAssertEqual(AcquisitionRows.notRead(formatExtension: ""), "Not read from this format yet")
        var m = AcquisitionMetadata()
        m.unread = [.mode]
        XCTAssertEqual(try? Self.row(rows(m, ext: "EMD"), "mode").value, "Not read from .emd files yet")
    }

    /// A reading the core holds is shown even when its field is also listed unread: never hide a value that came through.
    func testAReadingWinsOverTheUnreadList() throws {
        var m = AcquisitionMetadata()
        m.highTensionKV = MetadataReading(200)
        m.unread = [.highTension]
        let row = try Self.row(rows(m, ext: "emd"), "highTension")
        XCTAssertEqual(row.value, "200 kV")
        XCTAssertFalse(row.isPlaceholder)
    }

    // MARK: Notes and second copies

    /// A note shows with its row, and VoiceOver reads it after the value. Mutation: a note dropped.
    func testANoteShowsBeneathItsRowAndIsSpokenWithIt() throws {
        var m = planted()
        m.cameraLengthMM = MetadataReading(245, note: "mm (assumed)")
        m.acquired = MetadataReading("2026-03-05 14:22:01", note: AcquisitionMetadata.localTimeNote)
        let all = rows(m)
        let camera = try Self.row(all, "cameraLength")
        XCTAssertEqual(camera.note, "mm (assumed)")
        XCTAssertEqual(camera.value, "245 mm", "the note is beside the value, not in it")
        XCTAssertEqual(camera.spokenValue, "245 millimeters, mm (assumed)")
        let date = try Self.row(all, "acquired")
        XCTAssertEqual(date.note, "local time, zone not stored")
        XCTAssertEqual(date.spokenValue, "2026-03-05 14:22:01, local time, zone not stored")
        XCTAssertEqual(all.compactMap(\.note).count, 2, "a row without a note has none")
    }

    /// A second copy that differs is its own row, right after its field, "<label> (second copy)", with the same note.
    /// Mutation: the second copy dropped; its note dropped.
    func testASecondCopyIsItsOwnRowWithTheSameNote() throws {
        var m = planted()
        m.highTensionKV = MetadataReading(200, otherCopy: 300)
        m.acquired = MetadataReading("2026-03-05 14:22:01", note: AcquisitionMetadata.localTimeNote,
                                     otherCopy: "2026-03-05 14:22:09")
        let all = rows(m)
        XCTAssertEqual(all.map(\.id), ["highTension", "highTension.second", "magnification", "cameraLength", "detector", "dwell",
                                       "exposure", "acquired", "acquired.second", "instrument", "mode"])
        let kv = try Self.row(all, "highTension.second")
        XCTAssertEqual(kv.label, "High tension (second copy)")
        XCTAssertEqual(kv.value, "300 kV")
        XCTAssertEqual(kv.spokenValue, "300 kilovolts")
        XCTAssertEqual(try Self.row(all, "highTension").value, "200 kV", "the first copy stays")
        let date = try Self.row(all, "acquired.second")
        XCTAssertEqual(date.label, "Acquired (second copy)")
        XCTAssertEqual(date.value, "2026-03-05 14:22:09")
        XCTAssertEqual(date.note, "local time, zone not stored")
        XCTAssertEqual(date.spokenValue, "2026-03-05 14:22:09, local time, zone not stored")
        // The second copy is a number too: it reads back within the bound, in the core's unit.
        XCTAssertEqual(try number(in: kv, unit: "kV", locale: Self.posix), 300, accuracy: 5e-7 * 300)
    }

    /// A reading without a second copy adds no row.
    func testNoSecondCopyAddsNoRow() {
        XCTAssertEqual(rows(planted()).count, 9)
        XCTAssertFalse(rows(planted()).contains { $0.id.hasSuffix(".second") })
    }

    /// Every row has its own id, second copies included: the list is a `ForEach` over them.
    func testRowIdsAreUnique() {
        var m = planted()
        m.highTensionKV = MetadataReading(200, otherCopy: 300)
        m.magnification = MetadataReading(28_500, otherCopy: 57_000)
        m.cameraLengthMM = MetadataReading(245, otherCopy: 100)
        m.detector = MetadataReading("Ceta", otherCopy: "BM-Ceta")
        m.dwellUS = MetadataReading(2, otherCopy: 3)
        m.exposureS = MetadataReading(0.5, otherCopy: 1)
        m.acquired = MetadataReading("2026-03-05 14:22:01", otherCopy: "2026-03-05 14:22:09")
        m.instrument = MetadataReading("Titan Themis", otherCopy: "Titan")
        m.mode = MetadataReading("STEM", otherCopy: "TEM")
        let all = rows(m)
        XCTAssertEqual(all.count, 18)
        XCTAssertEqual(Set(all.map(\.id)).count, 18)
    }

    // MARK: Speech

    /// The units VoiceOver reads are words ("kV", "mm" and "µs" are read letter by letter); one reads "1 kilovolt".
    func testSpokenValuesSpellTheUnits() throws {
        var m = planted()
        let all = rows(m)
        let spoken = ["highTension": "200 kilovolts", "magnification": "28500 times", "cameraLength": "245 millimeters",
                      "dwell": "2 microseconds", "exposure": "0.5 seconds", "detector": "Ceta"]
        for (id, text) in spoken { XCTAssertEqual(try Self.row(all, id).spokenValue, text, id) }
        m.highTensionKV = MetadataReading(1)
        m.exposureS = MetadataReading(1)
        XCTAssertEqual(try Self.row(rows(m), "highTension").spokenValue, "1 kilovolt")
        XCTAssertEqual(try Self.row(rows(m), "exposure").spokenValue, "1 second")
    }
}
