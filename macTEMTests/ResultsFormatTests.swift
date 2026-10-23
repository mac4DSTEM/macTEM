//
//  ResultsFormatTests.swift
//  Every sentence and number the Results room shows (V1-10 slice 3, `ResultsFormat`): the groups' names, a row's Value as the
//  owner's room reads it (a mark as `MarkFormat`, a spot as `FFTRoomFormat`), its Source, Record and badge, the badge that turns to
//  "Unvalidated · <note>", the spoken row, the line ⌘C copies, the Info fields, the header's count, the states' words and the export's
//  name, message and menu title. Expected strings are literals worked out by hand. Tier 2.
//
//  Mutations sampled (each alone, the named test went red): a metre length shown in metres (the Velox row); the pixel-grid angle
//  shown as physical; the badge ignoring the reader's note; "1 results"; the export name keeping the file's extension.
//

import ImagoCore
import XCTest
import TEMCore
import TEMSession
import ImagoFFT
@testable import macTEM

nonisolated final class ResultsFormatTests: XCTestCase {

    private static let en = Locale(identifier: "en_US")
    private static let nm = AxisCalibration(scale: 0.5, unit: "nm", origin: 0)
    private static let tall = AxisCalibration(scale: 0.8, unit: "nm", origin: 0)
    private static let velox = AxisCalibration(scale: 4.46179e-11, unit: "m", origin: 0)

    private func distance(_ a: ImagePoint, _ b: ImagePoint, x: AxisCalibration?, y: AxisCalibration?, lineage: String? = "s1") -> ResultRow {
        .distance(id: "mark:1", label: "Distance 1", a: a, b: b, x: x, y: y, lineage: lineage)
    }

    private func value(_ row: ResultRow, x: AxisCalibration?, y: AxisCalibration?) -> String {
        ResultsFormat.value(row, x: x, y: y, locale: Self.en)
    }

    private func spotRow(region: ResultRow.Region = .init(col: 0, row: 0, width: 96, height: 64)) -> ResultRow {
        ResultRow(id: "spot:1", product: .spot, label: "Spot 1", entries: [
            .init("d", 0.4, unit: "nm"), .init("q", 2.5, unit: "1/nm"),
            .init("region_col", Double(region.col), unit: "px"), .init("region_row", Double(region.row), unit: "px"),
            .init("region_width", Double(region.width), unit: "px"), .init("region_height", Double(region.height), unit: "px"),
        ])
    }

    // MARK: Groups

    /// The group names, and which room removes a result (there is no ⌫ here). Red under: a group named for the other.
    func testGroupNamesAndOwners() {
        XCTAssertEqual(ResultsFormat.title(.marks), "Marks")
        XCTAssertEqual(ResultsFormat.title(.spots), "FFT Spots")
        XCTAssertEqual(ResultsFormat.owner(.marks), "the Image room")
        XCTAssertEqual(ResultsFormat.owner(.spots), "the FFT room")
    }

    // MARK: The Value column

    /// A distance reads as the Image room's row does: length in the shown unit at 4 digits, then pixels. The oracle is
    /// `MarkFormat.value` itself. Red under: a Velox metre length shown in metres; the pixels dropped; the file's unit used for a
    /// metre axis.
    func testADistanceReadsAsTheImageRoomsRowDoes() {
        // Anisotropic nm pixels: 60 columns of 0.5 and 80 rows of 0.8 nm: sqrt(30² + 64²) = 70.68 nm in 100 px.
        let a = ImagePoint(x: 0, y: 0), b = ImagePoint(x: 60, y: 80)
        XCTAssertEqual(value(distance(a, b, x: Self.nm, y: Self.tall), x: Self.nm, y: Self.tall), "70.68 nm · 100 px")
        // A Velox pixel is in metres: 1000 px of 4.46179e-11 m are 44.6179 nm.
        let far = ImagePoint(x: 1000, y: 0)
        XCTAssertEqual(value(distance(a, far, x: Self.velox, y: Self.velox), x: Self.velox, y: Self.velox), "44.62 nm · 1000 px")
        XCTAssertEqual(value(distance(a, b, x: nil, y: nil), x: nil, y: nil), "100 px")
        for (x, y) in [(Self.nm, Self.tall), (Self.velox, Self.velox), (nil, nil)] as [(AxisCalibration?, AxisCalibration?)] {
            let mark = ImageMark(kind: .distance, points: [a, far])
            XCTAssertEqual(value(distance(a, far, x: x, y: y), x: x, y: y), MarkFormat.value(mark, x: x, y: y, locale: Self.en))
        }
    }

    /// An angle at one decimal, with "(pixel grid)" when it was taken there; a refusal its words, capitalised. Red under: the pixel
    /// grid read as physical; the degree sign dropped.
    func testAnAngleAndItsRefusal() {
        let a = ImagePoint(x: 10, y: 0), v = ImagePoint(x: 0, y: 0), c = ImagePoint(x: 0, y: 10)
        let calibrated = ResultRow.angle(id: "m", label: "Angle 1", a: a, vertex: v, c: c, x: Self.nm, y: Self.nm, lineage: nil)
        let grid = ResultRow.angle(id: "m", label: "Angle 2", a: a, vertex: v, c: c, x: nil, y: nil, lineage: nil)
        XCTAssertEqual(value(calibrated, x: Self.nm, y: Self.nm), "90.0°")
        XCTAssertEqual(value(grid, x: nil, y: nil), "90.0° (pixel grid)")
        let zero = ResultRow.angle(id: "m", label: "Angle 3", a: v, vertex: v, c: c, x: nil, y: nil, lineage: nil)
        XCTAssertEqual(value(zero, x: nil, y: nil), "No angle: an arm has zero length")
    }

    /// A profile as the Image room's row: "Profile · 25 nm" at 3 digits, "Profile · 50 px" without a calibration. Red under: the
    /// kind's word dropped; the width shown in place of the length.
    func testAProfileReadsAsTheImageRoomsRowDoes() {
        let a = ImagePoint(x: 0, y: 0), b = ImagePoint(x: 30, y: 40)
        let p = { (x: AxisCalibration?, y: AxisCalibration?) in ResultRow.profile(id: "m", label: "Profile 1", a: a, b: b, width: 5, x: x, y: y, lineage: nil) }
        XCTAssertEqual(value(p(Self.nm, Self.nm), x: Self.nm, y: Self.nm), "Profile · 25 nm")
        XCTAssertEqual(value(p(nil, nil), x: nil, y: nil), "Profile · 50 px")
    }

    /// A spot reads as the FFT room's row: "d 0.4 nm · |q| 2.5 nm⁻¹"; a refused one its reason. Red under: |q| before d; the refusal's
    /// words lost.
    func testASpotReadsAsTheFFTRoomsRowDoes() {
        XCTAssertEqual(value(spotRow(), x: nil, y: nil), FFTRoomFormat.spotValue(d: 0.4, q: 2.5, unit: "nm", locale: Self.en))
        XCTAssertEqual(value(spotRow(), x: nil, y: nil), "d 0.4 nm · |q| 2.5 nm⁻¹")
        let refused = ResultRow.unmeasuredSpot(id: "spot:2", number: 2, clickRow: 64, clickCol: 64,
                                               region: .init(col: 0, row: 0, width: 96, height: 64), reason: ResultRow.reason(.nearDC))
        XCTAssertEqual(value(refused, x: nil, y: nil), "Not measured: the peak nearest the click is within 3 bins of the centre")
    }

    // MARK: Source, Record and the badge

    /// A mark's source, a spot's region (the whole image, or the crop with its corner). Red under: the crop's corner swapped.
    func testSource() {
        let mark = distance(ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4), x: nil, y: nil)
        XCTAssertEqual(ResultsFormat.source(mark, imageWidth: 96, imageHeight: 64), "Image · mark")
        XCTAssertEqual(ResultsFormat.source(spotRow(), imageWidth: 96, imageHeight: 64), "FFT · the whole image")
        XCTAssertEqual(ResultsFormat.source(spotRow(region: .init(col: 16, row: 8, width: 64, height: 64)), imageWidth: 96, imageHeight: 64),
                       "FFT · region 64 × 64 px at (16, 8)")
        XCTAssertEqual(ResultsFormat.source(spotRow(region: .init(col: 0, row: 0, width: 96, height: 64)), imageWidth: 128, imageHeight: 64),
                       "FFT · region 96 × 64 px at (0, 0)", "a crop the size of another image is a crop")
    }

    /// The Record column: the node of a saved mark, else "not recorded" (a spot never claims a node). Red under: "not recorded"
    /// written for a mark that has a node.
    func testRecord() {
        XCTAssertEqual(ResultsFormat.record(distance(ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4), x: nil, y: nil)), "s1")
        XCTAssertEqual(ResultsFormat.record(distance(ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4), x: nil, y: nil, lineage: nil)),
                       "not recorded")
        XCTAssertEqual(ResultsFormat.record(spotRow()), "not recorded")
    }

    /// The badge is the producer's label; a reader's note saying "unvalidated" turns it to "Unvalidated · <that note>" and the
    /// tooltip stays the producer's sentence. Red under: the note ignored; the match made case-sensitive.
    func testTheBadge() {
        let d = distance(ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4), x: nil, y: nil)
        XCTAssertEqual(ResultsFormat.badge(d, notes: []), "Checked · closed form")
        XCTAssertEqual(ResultsFormat.badge(spotRow(), notes: ["a note"]), "Checked · planted spots")
        XCTAssertEqual(ResultsFormat.badge(d, notes: ["Scale read from the header, UNVALIDATED"]),
                       "Unvalidated · Scale read from the header, UNVALIDATED")
        XCTAssertEqual(ResultsFormat.validation(d), ImageMeasurement.validation)
        XCTAssertEqual(ResultsFormat.validation(spotRow()), FFTExport.spotsValidation)
    }

    // MARK: Spoken, copied, Info

    /// One spoken sentence: the label, the value with "px" as pixels, the badge, the record. Red under: "px" left as letters.
    func testTheSpokenRow() {
        let d = distance(ImagePoint(x: 0, y: 0), ImagePoint(x: 60, y: 80), x: Self.nm, y: Self.tall)
        let v = value(d, x: Self.nm, y: Self.tall)
        XCTAssertEqual(ResultsFormat.spoken(d, value: v, badge: ResultsFormat.badge(d, notes: [])),
                       "Distance 1, 70.68 nm, 100 pixels, Checked closed form, recorded as s1")
        XCTAssertEqual(ResultsFormat.spoken(spotRow(), value: "d 0.4 nm · |q| 2.5 nm⁻¹", badge: "Checked · planted spots"),
                       "Spot 1, d 0.4 nm, |q| 2.5 nm⁻¹, Checked planted spots, not recorded")
    }

    /// ⌘C: five columns, tab-separated, one line per row, in the order given. Red under: the columns reordered; a separator other
    /// than a tab.
    func testTheCopiedLines() {
        let image = CalibratedImage(width: 96, height: 64, pixels: [Float](repeating: 0, count: 96 * 64), x: Self.nm, y: Self.tall,
                                    fileName: "scan.dm4", source: "o", voltage: nil)
        let rows = [distance(ImagePoint(x: 0, y: 0), ImagePoint(x: 60, y: 80), x: Self.nm, y: Self.tall), spotRow()]
        XCTAssertEqual(ResultsFormat.copyLine(label: "A", value: "B", source: "C", record: "D", badge: "E"), "A\tB\tC\tD\tE")
        let text = ResultsFormat.copyText(rows, image: image, locale: Self.en)
        XCTAssertEqual(text.components(separatedBy: "\n"), [
            "Distance 1\t70.68 nm · 100 px\tImage · mark\ts1\tChecked · closed form",
            "Spot 1\td 0.4 nm · |q| 2.5 nm⁻¹\tFFT · the whole image\tnot recorded\tChecked · planted spots",
        ])
        XCTAssertEqual(ResultsFormat.copyText([], image: image), "")
    }

    /// The Info tab's fields: a number to 6 digits with its unit as displayed, a words-only entry its words, an empty one a dash.
    /// Red under: the unit dropped; a nil value shown as 0.
    func testInfoFields() {
        func field(_ entry: ResultRow.Entry) -> (name: String, text: String) { ResultsFormat.field(entry, locale: Self.en) }
        XCTAssertEqual(field(.init("width", 12.5, unit: "px")).text, "12.5 px")
        XCTAssertEqual(field(.init("third", 1.0 / 3.0, unit: "nm")).text, "0.333333 nm")
        XCTAssertEqual(field(.init("angle", 90, unit: "deg", text: "taken on the pixel grid")).text, "90° · taken on the pixel grid")
        XCTAssertEqual(field(.init("outcome", nil, text: "not measured")).text, "not measured")
        XCTAssertEqual(field(.init("nothing", nil)).text, "—")
        XCTAssertEqual(field(.init("v", .nan, unit: "px")).text, "—", "a number that is not one has no unit")
        XCTAssertEqual(field(.init("width", 12.5, unit: "px")).name, "width")
    }

    // MARK: The header and the states

    /// "1 result", "12 results"; the header's summary with the hidden count; the session sentence's fallback. Red under: "1 results";
    /// the hidden count shown when nothing is hidden.
    func testCountsAndTheSummary() {
        XCTAssertEqual(ResultsFormat.count(1), "1 result")
        XCTAssertEqual(ResultsFormat.count(0), "0 results")
        XCTAssertEqual(ResultsFormat.count(12), "12 results")
        XCTAssertEqual(ResultsFormat.summary(fileName: "scan.dm4", shown: 12, hidden: 3), "scan.dm4 · 12 results, 3 hidden")
        XCTAssertEqual(ResultsFormat.summary(fileName: "scan.dm4", shown: 1, hidden: 0), "scan.dm4 · 1 result")
        XCTAssertEqual(ResultsFormat.session(firstLine: "Saved at 14:03 to scan.dm4.mactem.h5."), "Saved at 14:03 to scan.dm4.mactem.h5.")
        XCTAssertEqual(ResultsFormat.session(firstLine: nil), "No marks in this file's session record.")
    }

    func testTheStatesWords() {
        XCTAssertEqual(ResultsFormat.emptyTitle, "No results yet")
        XCTAssertEqual(ResultsFormat.emptyDetail, "Measure in the Image or FFT room; the numbers appear here.")
        XCTAssertEqual(ResultsFormat.allHiddenTitle, "All results are hidden")
        XCTAssertEqual(ResultsFormat.allHiddenDetail, "Switch a group on in the inspector's Show section.")
        XCTAssertEqual(ResultsFormat.noSelection, "Select a result to see its numbers and how far it is trusted.")
        XCTAssertEqual(ResultsFormat.severalSelected, "Several results are selected.")
    }

    // MARK: Export

    /// The save panel starts as the bare stem plus ".results" (the content type adds ".csv"): "scan.results" for "scan.dm4". Red
    /// under: the file's extension kept ("scan.dm4.results"); ".csv" added by hand.
    func testTheExportName() {
        XCTAssertEqual(ResultsFormat.exportName(fileName: "scan.dm4"), "scan.results")
        XCTAssertEqual(ResultsFormat.exportName(fileName: "scan.v2.tif"), "scan.v2.results")
        XCTAssertEqual(ResultsFormat.exportName(fileName: ""), "image.results")
    }

    func testTheExportWords() {
        XCTAssertEqual(ResultsFormat.exportMessage(rows: 3, groups: [.marks, .spots]),
                       "3 results · Marks and FFT Spots · numbers exact, one line per quantity")
        XCTAssertEqual(ResultsFormat.exportMessage(rows: 1, groups: [.marks]), "1 result · Marks · numbers exact, one line per quantity")
        XCTAssertEqual(ResultsFormat.exportingDoneLine(name: "scan.results.csv", rows: 3), "Exported scan.results.csv — 3 results")
        XCTAssertEqual(ResultsFormat.exportTitle(enabled: true, hasRows: true), "All Results as CSV…")
        XCTAssertEqual(ResultsFormat.exportTitle(enabled: false, hasRows: false), "All Results as CSV… (nothing measured yet)")
        XCTAssertEqual(ResultsFormat.exportTitle(enabled: false, hasRows: true), "All Results as CSV… (a read is running)")
    }
}
