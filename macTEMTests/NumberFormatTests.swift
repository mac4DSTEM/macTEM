//
//  NumberFormatTests.swift
//  The one number format (`Num`): a value that rounds to zero is written as zero, with no sign, whatever the sign of what was rounded.
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
