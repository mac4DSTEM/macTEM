//
//  NumberFormatTests.swift
//  The one number format (`Num`, `UnitDisplay`): a value that rounds to zero is written as zero, with no sign, whatever the sign of what was
//  rounded; the digits are printf's (the CSV's) in the reader's decimal mark, with no exponent and no grouping.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class NumberFormatTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    /// Red before: "-0.00" for a deviation of exactly zero from the kit (negative zero) and for -0.001 at two places.
    func testNoNegativeZero() {
        XCTAssertEqual(Num.signed(-0.0, 2, locale: en), "0.00")
        XCTAssertEqual(Num.signed(-0.001, 2, locale: en), "0.00")
        XCTAssertEqual(Num.fixed(-0.0, 2, locale: en), "0.00")
        XCTAssertEqual(Num.fixed(-0.004, 2, locale: en), "0.00")
        XCTAssertEqual(Num.signed(-0.0, 2, locale: de), "0,00")
    }

    func testSignsAndDecimalsOtherwiseAreUnchanged() {
        XCTAssertEqual(Num.signed(0.5, 1, locale: en), "+0.5")
        XCTAssertEqual(Num.signed(-0.06, 2, locale: en), "-0.06")
        XCTAssertEqual(Num.fixed(2.0366, 3, locale: de), "2,037")
        XCTAssertEqual(Num.fixed(-0.006, 2, locale: en), "-0.01")
        XCTAssertEqual(Num.sig(0.012625, 6, locale: de), "0,012625")
    }

    /// A decimal tie rounds as the binary value does, as the CSV beside it: 0.35 is 0.34999… ("0.3") and 2.675 is 2.67499… ("2.67"), in the
    /// reader's mark. Red before: FormatStyle rounded the shortest spelling, half to even, and read "0.4" and "2.68".
    func testATieRoundsAsTheCSVDoes() {
        XCTAssertEqual(Num.fixed(0.35, 1, locale: en), String(format: "%.1f", 0.35))
        XCTAssertEqual(Num.fixed(0.35, 1, locale: en), "0.3")
        XCTAssertEqual(Num.fixed(0.35, 1, locale: de), "0,3")
        XCTAssertEqual(Num.signed(0.35, 1, locale: en), "+0.3")
        XCTAssertEqual(UnitDisplay.number(2.675, digits: 3, locale: en), "2.67")
        XCTAssertEqual(Num.sig(2.675, 3, locale: de), "2,67")
        XCTAssertEqual(ParticleFormat.number(2.675, locale: en), ParticleFormat.csvNumber(2.675), "the object table and its CSV show one last digit")
    }

    /// The spelling stays as it was: no exponent for a small or a large value, no trailing zeros, no grouping, a dash for no value.
    /// Red under: `%g` itself ("1.23e-05", "1.23e+06"), or the trailing zeros of `%.3e`.
    func testNoExponentNoTrailingZerosNoGrouping() {
        XCTAssertEqual(UnitDisplay.number(0.0000123, digits: 3, locale: en), "0.0000123")
        XCTAssertEqual(UnitDisplay.number(1_234_567, digits: 3, locale: en), "1230000")
        XCTAssertEqual(UnitDisplay.number(9.9996, digits: 4, locale: de), "10", "rounds up across a decade")
        XCTAssertEqual(UnitDisplay.number(-4.5, locale: de), "-4,5")
        XCTAssertEqual(UnitDisplay.number(0, digits: 3, locale: en), "0")
        XCTAssertEqual(UnitDisplay.number(.nan, locale: en), "—")
        XCTAssertEqual(Num.fixed(12_345.678, 1, locale: de), "12345,7")
        XCTAssertEqual(Num.fixed(87.6, 0, locale: de), "88", "no decimal mark at zero places")
        XCTAssertEqual(UnitDisplay.fixed(-0.004, places: 2, locale: de), "0,00")
    }

    /// The numbers inside on-screen sentences take the reader's decimal mark, as the fields beside them do: NLPAR's λ row, an SEM-EDS window's
    /// refusal, the FFT room's accuracy note and the transform panel's ratio. Red before: `%.3f`, `%.4g`, `%.3g` and a literal "0.5" always
    /// wrote a point, so each German line below read "0.123", "1.5 keV", "0.5–3 %" and "1.5 : 1".
    func testOnScreenSentencesTakeTheLocaleDecimalMark() {
        XCTAssertEqual(PatternsProcessingSections.lambdaText(0.12345, locale: de), "0,123")
        XCTAssertEqual(PatternsProcessingSections.lambdaText(0.12345, locale: en), "0.123")
        let axis = SEMEDSLines.Axis(offsetKeV: 0, scaleKeV: 0.01, size: 100)
        XCTAssertThrowsError(try SEMEDSLines.channels(from: 1.5, to: 2, axis: axis, locale: de)) { error in
            XCTAssertEqual(error as? SEMEDSLines.Refusal, SEMEDSLines.Refusal("A window starts at 1,5 keV, above the spectrum's end."))
        }
        XCTAssertThrowsError(try SEMEDSLines.channels(from: 1.5, to: 2, axis: axis, locale: en)) { error in
            XCTAssertEqual(error as? SEMEDSLines.Refusal, SEMEDSLines.Refusal("A window starts at 1.5 keV, above the spectrum's end."))
        }
        XCTAssertEqual(FFTRoomFormat.accuracyNote(width: 64, height: 64, locale: de), "With noise, d is good to 1–5 % at 64 px and 0,5–3 % at 128 px.")
        XCTAssertEqual(FFTRoomFormat.accuracyNote(width: 64, height: 64, locale: en), "With noise, d is good to 1–5 % at 64 px and 0.5–3 % at 128 px.")
        // 3 x 2 bins drawn at 3·Δq : 2·1.5Δq, a square box: the PNG is 1.5 : 1.
        let dq = 0.0390625
        XCTAssertEqual(ExportSnapshot.aspectSentence(width: 3, height: 2, spacingX: dq, spacingY: dq * 1.5, locale: de),
                       " This region is 3 × 2 bins: the PNG has one pixel per bin, so it is 1,5 : 1 where the room shows it 1 : 1.")
        XCTAssertEqual(ExportSnapshot.aspectSentence(width: 3, height: 2, spacingX: dq, spacingY: dq * 1.5, locale: en),
                       " This region is 3 × 2 bins: the PNG has one pixel per bin, so it is 1.5 : 1 where the room shows it 1 : 1.")
    }
}
