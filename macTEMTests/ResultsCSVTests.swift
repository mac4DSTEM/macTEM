//
//  ResultsCSVTests.swift
//  The Results room's CSV and its rows (V1-10 slice 3, `ResultsCSV`, `ResultRow`): the header's keys in order and one validation
//  line per product present, the columns, one line per quantity and a line for a refusal, the numbers exact (`nan`, `inf`, `-inf`,
//  -0), RFC 4180 quoting of a cell with a comma, a quote and a newline, a header value that cannot end its line, an empty ledger that is
//  no file, the builders' quantities against the owners' own (`ImageMeasurement`, `SpotMeasurement`), and R-P2 — every validation sentence
//  is a producer's own constant, "validated" is never claimed, and a product without a constant does not compile (the switches below
//  are exhaustive). Tier 1 in its parity (tools/parity/export-parity, R-P1: Python's `float` and `csv` re-read a planted ledger); these pin
//  the writer's rules without Python and fail on the spot.
//
//  Mutations each test was broken by (ResultsCSV.swift, ResultRow.swift): the cells written without quoting; a validation line
//  omitted; the value of a words-only line written as 0; NaN written 0; `%.15g`; a spot's d taken from |q|; the lineage column
//  dropped; `Product.validation` of the spot replaced by a sentence of its own.
//

import XCTest
import DiffractoGeometry
import TEMCore
import ImagoCore
import ImagoFFT

nonisolated final class ResultsCSVTests: XCTestCase {

    // MARK: Fixtures

    private static let nmX = AxisCalibration(scale: 0.0731, unit: "nm", origin: 0)
    private static let nmY = AxisCalibration(scale: 0.0789, unit: "nm", origin: 0)
    private static let software = "macTEM 0.1.0 (1)"

    private func source(notes: [String] = [], fileName: String = "results.dm4", x: AxisCalibration? = ResultsCSVTests.nmX,
                        y: AxisCalibration? = ResultsCSVTests.nmY) -> ExportSource {
        ExportSource(software: Self.software, fileName: fileName, object: "ImageList.1", width: 128, height: 96, x: x, y: y,
                     notes: notes)
    }

    private func distance(_ id: String = "mark:1", label: String = "Distance 1", lineage: String? = "s1") -> ResultRow {
        .distance(id: id, label: label, a: ImagePoint(x: 12.3, y: 45.6), b: ImagePoint(x: 101.7, y: 23.1),
                  x: Self.nmX, y: Self.nmY, lineage: lineage)
    }

    private func angle() -> ResultRow {
        .angle(id: "mark:2", label: "Angle 1", a: ImagePoint(x: 20.5, y: 30.1), vertex: ImagePoint(x: 60.7, y: 62.3),
               c: ImagePoint(x: 110.9, y: 40.2), x: Self.nmX, y: Self.nmY, lineage: nil)
    }

    private func profile() -> ResultRow {
        .profile(id: "mark:3", label: "Profile 1", a: ImagePoint(x: 8.4, y: 100.2), b: ImagePoint(x: 120.6, y: 77.7), width: 5,
                 x: Self.nmX, y: Self.nmY, lineage: "s3")
    }

    private func measuredSpot() throws -> SpotMeasurement {
        var pixels = [Float](repeating: 0, count: 64 * 64)
        for r in 0..<64 {
            for c in 0..<64 {
                pixels[r * 64 + c] = Float(100 + 10 * cos(2 * Double.pi * (0.1731 * Double(c) + 0.0627 * Double(r))))
            }
        }
        let image = CalibratedImage(width: 64, height: 64, pixels: pixels, x: Self.nmX, y: Self.nmY, fileName: "lattice",
                                    source: "", voltage: nil)
        return try SpotMeasurement.measure(image.micrograph, clickRow: 36, clickColumn: 43)
    }

    private func spot() throws -> ResultRow {
        .spot(id: "spot:1", number: 1, measured: try measuredSpot(), region: .init(col: 0, row: 0, width: 128, height: 96))
    }

    private func refused() -> ResultRow {
        .unmeasuredSpot(id: "spot:2", number: 2, clickRow: 64, clickCol: 64, region: .init(col: 10, row: 20, width: 64, height: 64),
                        reason: ResultRow.reason(.nearDC))
    }

    /// RFC 4180: a minimal reader (quoted cells, doubled quotes, newlines inside quotes) so the test needs no library.
    private func parse(_ body: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var chars = Array(body.unicodeScalars)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { cell.unicodeScalars.append("\""); chars.removeFirst() } else { quoted = false }
                } else { cell.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(cell); cell = "" }
            else if c == "\n" { row.append(cell); rows.append(row); row = []; cell = "" }
            else { cell.unicodeScalars.append(c) }
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    /// The file split into its `# key: value` header lines and the rows after (the column header first).
    private func split(_ text: String) -> (header: [String], rows: [[String]]) {
        let lines = text.components(separatedBy: "\n")
        let k = lines.firstIndex { !$0.hasPrefix("#") } ?? lines.count
        return (Array(lines[..<k]), parse(lines[k...].joined(separator: "\n")))
    }

    private func header(_ text: String, _ key: String) -> String? {
        split(text).header.first { $0.hasPrefix("# \(key): ") }.map { String($0.dropFirst("# \(key): ".count)) }
    }

    // MARK: The file

    /// The header names the file as the file states it, the session sentence and one validation line per PRODUCT PRESENT, each the
    /// producer's constant; the columns follow. Red under: a validation line for an absent product; one omitted; the session line gone.
    func testTheHeaderAndTheColumns() throws {
        let rows = [distance(), angle(), try spot()]
        let text = try XCTUnwrap(ResultsCSV.text(rows, source: source(notes: ["The scale is the file's"]), session: "Saved at 14:03."))
        let parts = split(text)
        XCTAssertEqual(parts.header.first, "# macTEM results")
        XCTAssertEqual(header(text, "software"), "macTEM 0.1.0 (1)")
        XCTAssertEqual(header(text, "file"), "results.dm4")
        XCTAssertEqual(header(text, "object"), "ImageList.1")
        XCTAssertEqual(header(text, "image"), "128 x 96 px")
        XCTAssertEqual(header(text, "x scale"), "0.0731 nm per px, origin 0.0 px")
        XCTAssertEqual(header(text, "y scale"), "0.0789 nm per px, origin 0.0 px")
        XCTAssertEqual(header(text, "session"), "Saved at 14:03.")
        XCTAssertEqual(header(text, "notes"), "The scale is the file's")
        XCTAssertEqual(header(text, "validation (distance)"), ImageMeasurement.validation)
        XCTAssertEqual(header(text, "validation (angle)"), ImageMeasurement.validation)
        XCTAssertEqual(header(text, "validation (spot)"), FFTExport.spotsValidation)
        XCTAssertNil(header(text, "validation (profile)"), "no profile in the ledger, no profile line")
        XCTAssertTrue(try XCTUnwrap(header(text, "numbers")).hasPrefix("%.17g"))
        XCTAssertEqual(parts.rows.first, ["group", "id", "label", "quantity", "value", "unit", "text", "validation", "lineage"])
        XCTAssertTrue(parts.header.last?.hasPrefix("#") == true)
        // The order of the header: the title, the file, its calibration, the session, then the validation lines.
        let keys = parts.header.dropFirst().map { $0.dropFirst(2).prefix { $0 != ":" } }
        XCTAssertEqual(keys.map(String.init), ["software", "file", "object", "image", "x scale", "y scale", "session", "notes",
                                               "points", "units", "validation (distance)", "validation (angle)",
                                               "validation (spot)", "lineage", "numbers"])
    }

    /// One line per quantity, in the rows' order, with the group, the id, the label, the producer's sentence and the lineage on
    /// each; a refusal adds an `outcome` line with its words and an empty value. Red under: the lineage column dropped; the
    /// refusal line missing; a quantity skipped.
    func testOneLinePerQuantity() throws {
        let rows = [distance(), try spot(), refused()]
        let text = try XCTUnwrap(ResultsCSV.text(rows, source: source(), session: "s"))
        let body = Array(split(text).rows.dropFirst())
        let expectedCount = rows.reduce(0) { $0 + $1.entries.count + ($1.refusal == nil ? 0 : 1) }
        XCTAssertEqual(body.count, expectedCount)
        XCTAssertTrue(body.allSatisfy { $0.count == 9 })
        let d = try XCTUnwrap(body.first { $0[3] == "length_px" })
        XCTAssertEqual(Array(d[0..<3]), ["marks", "mark:1", "Distance 1"])
        XCTAssertEqual(d[5], "px")
        XCTAssertEqual(d[7], ImageMeasurement.validation)
        XCTAssertEqual(d[8], "s1")
        let physical = try XCTUnwrap(body.first { $0[1] == "mark:1" && $0[3] == "length" })
        XCTAssertEqual(physical[5], "nm")
        let q = try XCTUnwrap(body.first { $0[1] == "spot:1" && $0[3] == "q" })
        XCTAssertEqual(q[0], "spots")
        XCTAssertEqual(q[5], "1/nm")
        XCTAssertEqual(q[7], FFTExport.spotsValidation)
        XCTAssertEqual(q[8], "", "a spot has no lineage node")
        let outcome = try XCTUnwrap(body.first { $0[1] == "spot:2" && $0[3] == "outcome" })
        XCTAssertEqual(outcome[4], "", "a refusal has no number")
        XCTAssertEqual(outcome[6], ResultRow.reason(.nearDC))
        XCTAssertFalse(body.contains { $0[1] == "spot:2" && $0[3] == "d" }, "a refused spot holds no d")
    }

    /// The numbers: `%.17g`, so a reader's `Double(_)` is the Double in memory bit for bit; nan, inf, -inf spelled; -0 kept; a
    /// words-only line has an empty value. Red under: `%.15g`; NaN written 0; -inf written inf; a words-only value written 0.
    func testNumbersAreExact() throws {
        let values: [Double] = [0.1, 1.0 / 3.0, 0, -0.0, .nan, .infinity, -.infinity, 5e-324, .greatestFiniteMagnitude, 0.1 + 0.2]
        let entries = values.enumerated().map { ResultRow.Entry("v\($0.offset)", $0.element, unit: "px") }
            + [ResultRow.Entry("words", nil, text: "only words")]
        let row = ResultRow(id: "raw:1", product: .distance, label: "raw", entries: entries)
        let text = try XCTUnwrap(ResultsCSV.text([row], source: source(), session: "s"))
        let body = Array(split(text).rows.dropFirst())
        XCTAssertEqual(body.count, entries.count)
        for (line, value) in zip(body, values) {
            if value.isNaN { XCTAssertEqual(line[4], "nan"); continue }
            if value == .infinity { XCTAssertEqual(line[4], "inf"); continue }
            if value == -.infinity { XCTAssertEqual(line[4], "-inf"); continue }
            XCTAssertEqual(try XCTUnwrap(Double(line[4])).bitPattern, value.bitPattern, "\(line[3]): \(line[4])")
        }
        XCTAssertEqual(body[3][4], "-0", "negative zero keeps its sign")
        XCTAssertEqual(body[10][4], "")
        XCTAssertEqual(body[10][6], "only words")
    }

    /// A label, a unit, a text and a refusal with a comma, a quote and a newline round-trip through RFC 4180 quoting, and a header
    /// value (the file's name, a note, the session sentence) can never end its own line. Red under: the cells written bare; the
    /// quotes not doubled; the header values not sanitised.
    func testQuotingAndSanitising() throws {
        let nasty = "a, \"b\"\nc"
        let row = ResultRow(id: "raw:1", product: .profile, label: nasty, entries: [.init("q", 1, unit: nasty, text: nasty)],
                            refusal: nasty, lineage: "s7")
        let text = try XCTUnwrap(ResultsCSV.text([row], source: source(notes: ["note\nwith newline"], fileName: "evil\r\nname.dm4"),
                                                 session: "line\none"))
        let body = Array(split(text).rows.dropFirst())
        XCTAssertEqual(body.count, 2)
        for line in body {
            XCTAssertEqual(line[2], nasty)
            XCTAssertEqual(line[8], "s7")
        }
        XCTAssertEqual(body[0][5], nasty)
        XCTAssertEqual(body[0][6], nasty)
        XCTAssertEqual(body[1][6], nasty)
        XCTAssertEqual(header(text, "file"), "evil  name.dm4")
        XCTAssertEqual(header(text, "session"), "line one")
        XCTAssertEqual(header(text, "notes"), "note with newline")
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("\r"), "LF line ends; the CR of the file name is a space")
    }

    /// No row, no file; the writer throws the named failure. Red under: an empty ledger writing a header-only file.
    func testNoRowsIsNoFile() async throws {
        XCTAssertNil(ResultsCSV.text([], source: source(), session: "s"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("results-\(UUID().uuidString).csv")
        do {
            try await ResultsCSV.export([], source: source(), session: "s", to: url)
            XCTFail("an empty ledger was written")
        } catch let failure as ExportFile.Failure {
            XCTAssertEqual(failure, .noResults)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(failure.errorDescription, "This file has no results yet, so there is nothing to export.")
        }
    }

    /// The written file is exactly `text`: UTF-8, no BOM, LF. Red under: the export writing another rendering.
    func testTheFileIsTheText() async throws {
        let rows = [distance(), angle()]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("results-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ResultsCSV.export(rows, source: source(), session: "s", to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), ResultsCSV.text(rows, source: source(), session: "s"))
        XCTAssertNotEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "no BOM")
    }

    // MARK: The rows

    /// The builders put the owners' own numbers under the names the CSV has: a distance's length in pixels and in the file's unit,
    /// an angle's degrees and its plane, a profile's width, a spot's d, |q|, components and centroid. Red under: a spot's d taken from
    /// |q|; the pixel grid claimed as physical; the width missing.
    func testTheBuildersCarryTheOwnersNumbers() throws {
        let a = ImagePoint(x: 12.3, y: 45.6), b = ImagePoint(x: 101.7, y: 23.1)
        let measured = ImageMeasurement.distance(a, b, x: Self.nmX, y: Self.nmY)
        let row = distance()
        XCTAssertEqual(row.entry("length_px")?.value, measured.pixels)
        XCTAssertEqual(row.entry("length")?.value, measured.physical)
        XCTAssertEqual(row.entry("length")?.unit, "nm")
        XCTAssertEqual(row.entry("x2")?.value, 101.7)
        XCTAssertEqual(row.lineage, "s1")
        let uncalibrated = ResultRow.distance(id: "m", label: "D", a: a, b: b, x: nil, y: nil, lineage: nil)
        XCTAssertNil(uncalibrated.entry("length"), "no physical length without a calibration")

        let arm = ImageMeasurement.angle(ImagePoint(x: 20.5, y: 30.1), vertex: ImagePoint(x: 60.7, y: 62.3),
                                         ImagePoint(x: 110.9, y: 40.2), x: Self.nmX, y: Self.nmY)
        XCTAssertEqual(angle().entry("angle")?.value, arm?.degrees)
        XCTAssertEqual(angle().entry("angle")?.text, "taken in the physical plane")
        let grid = ResultRow.angle(id: "m", label: "A", a: ImagePoint(x: 20.5, y: 30.1), vertex: ImagePoint(x: 60.7, y: 62.3),
                                   c: ImagePoint(x: 110.9, y: 40.2), x: nil, y: nil, lineage: nil)
        XCTAssertEqual(grid.entry("angle")?.text, "taken on the pixel grid")
        let zero = ResultRow.angle(id: "m", label: "A", a: ImagePoint(x: 5, y: 5), vertex: ImagePoint(x: 5, y: 5),
                                   c: ImagePoint(x: 9, y: 2), x: nil, y: nil, lineage: nil)
        XCTAssertNil(zero.entry("angle"))
        XCTAssertEqual(zero.refusal, "no angle: an arm has zero length")

        XCTAssertEqual(profile().entry("width")?.value, 5)
        XCTAssertEqual(profile().entry("width")?.unit, "px")

        let m = try measuredSpot()
        let s = try spot()
        XCTAssertEqual(s.entry("d")?.value, m.d)
        XCTAssertEqual(s.entry("q")?.value, m.q)
        XCTAssertEqual(s.entry("qx")?.value, m.qx)
        XCTAssertEqual(s.entry("qy")?.value, m.qy)
        XCTAssertEqual(s.entry("centroid_col")?.value, m.centroidCol)
        XCTAssertEqual(s.entry("d")?.unit, m.units)
        XCTAssertEqual(s.entry("q")?.unit, m.reciprocalUnits)
        XCTAssertNotEqual(s.entry("d")?.value, s.entry("q")?.value)
        XCTAssertEqual(s.label, "Spot 1")
        XCTAssertEqual(s.entry("region_width")?.value, 128)
        XCTAssertNil(s.refusal)
        let r = refused()
        XCTAssertNil(r.entry("d"), "a refusal holds no number")
        XCTAssertEqual(r.refusal, "not measured: the peak nearest the click is within 3 bins of the centre")
        XCTAssertEqual(r.entry("click_row")?.value, 64)
        XCTAssertEqual(r.entry("region_col")?.value, 10)
    }

    /// A spot measured on an image whose axes are already reciprocal ("1/nm", a diffraction pattern) writes the unit of q, qx and qy
    /// as "nm", not "1/1/nm" (ImagoKit's `SpotMeasurement.reciprocalUnits`; macTEM's `SpotMeasure` wrote "1/1/nm", ADR 027): the
    /// Results ledger and its CSV carry this string. Red under: the reciprocal of a reciprocal unit written as "1/" + unit.
    func testASpotOnAReciprocalAxisImageNamesItsReciprocalUnitNm() throws {
        let axis = AxisCalibration(scale: 0.05, unit: "1/nm", origin: 0)
        var pixels = [Float](repeating: 0, count: 64 * 64)
        for r in 0..<64 {
            for c in 0..<64 { pixels[r * 64 + c] = Float(100 + 10 * cos(2 * Double.pi * (0.1731 * Double(c) + 0.0627 * Double(r)))) }
        }
        let image = CalibratedImage(width: 64, height: 64, pixels: pixels, x: axis, y: axis, fileName: "pattern", source: "", voltage: nil)
        let m = try SpotMeasurement.measure(image.micrograph, clickRow: 36, clickColumn: 43)
        XCTAssertEqual(m.reciprocalUnits, "nm")
        let row = ResultRow.spot(id: "spot:1", number: 1, measured: m, region: .init(col: 0, row: 0, width: 64, height: 64))
        for name in ["q", "qx", "qy"] { XCTAssertEqual(row.entry(name)?.unit, "nm", "\(name) of a reciprocal-axis spot") }
        XCTAssertEqual(row.entry("d")?.unit, "1/nm")
    }

    /// Every refusal has its words, and they are the estimator's own cases. Red under: a case mapped to another's sentence.
    func testEveryRefusalHasItsWords() {
        let all: [SpotMeasurementError] = [.nearDC, .nearEdge, .crop(PixelCrop(row: 0, col: 0, height: 1, width: 1)), .mixedUnits("nm", "1/nm"),
                                          .fftSetup(width: 7, height: 9), .outside(row: 1, col: 2), .zeroFrequency, .nonFinite, .noPower]
        let words = all.map(ResultRow.reason)
        XCTAssertEqual(Set(words).count, all.count, "each failure has a sentence of its own")
        XCTAssertTrue(words.allSatisfy { $0.hasPrefix("not measured: ") })
        XCTAssertEqual(words[4], "not measured: the Fourier transform of 7 x 9 px could not be set up")
        XCTAssertTrue(ResultRow.noPeak.hasPrefix("not measured: no peak"))
    }

    // MARK: R-P2 — no sentence authored by the room

    /// Every product's validation sentence is its producer's own constant, verbatim, and only that. The switch is exhaustive: a
    /// product added without a case here is a compile error, and one added without a constant in `ResultRow.Product.validation`
    /// is one there. Red under: the spot's sentence replaced by one of its own; the profile's by the distance's; a sentence empty.
    func testEveryValidationSentenceIsAProducersConstant() {
        for product in ResultRow.Product.allCases {
            let producers: String
            switch product {
            case .distance, .angle: producers = ImageMeasurement.validation
            // A profile row's numbers are closed forms; the Image room's CSV samples are scikit-image's: both constants, in that order.
            case .profile: producers = ImageMeasurement.validation + ResultRow.Product.profileSamplesClause + ProfileCSV.validation
            case .spot: producers = FFTExport.spotsValidation
            // The kit's own self-reported sentence (validation: none) for the indexing; the calibration's is the room's statement of what its numbers are.
            case .ring: producers = RingIndexing.validation
            case .calibration: producers = product.validation
            }
            XCTAssertEqual(product.validation, producers, "\(product): not the producer's constant")
            XCTAssertFalse(product.validation.isEmpty)
            XCTAssertFalse(product.badge.isEmpty)
            XCTAssertTrue(product.badge.hasPrefix(product == .ring ? "Unvalidated · " : "Checked · "), "\(product): \(product.badge)")
        }
        XCTAssertTrue(ResultRow.Product.profile.validation.hasPrefix(ImageMeasurement.validation), "the row's numbers are closed forms")
        XCTAssertTrue(ResultRow.Product.profile.validation.hasSuffix(ProfileCSV.validation), "the samples are scikit-image's")
        XCTAssertEqual(Set(ResultRow.Product.allCases.map(\.group)), Set(ResultRow.Group.allCases),
                       "every group has a product, so a group has a sentence")
        for group in ResultRow.Group.allCases {
            switch group {
            case .marks: XCTAssertEqual(ResultRow.Product.allCases.filter { $0.group == .marks }.count, 3)
            case .spots: XCTAssertEqual(ResultRow.Product.allCases.filter { $0.group == .spots }.count, 1)
            case .calibration: XCTAssertEqual(ResultRow.Product.allCases.filter { $0.group == .calibration }.count, 1)
            case .rings: XCTAssertEqual(ResultRow.Product.allCases.filter { $0.group == .rings }.count, 1)
            }
        }
    }

    /// All six badges, as worded: three claims of a closed form (a profile row's numbers are the line's length and width, not the
    /// samples), one of planted spots, the calibration's closed forms and the ring's honest "unvalidated"; no version is written in a
    /// badge. Red under: the profile badge naming scikit-image again; a badge reworded.
    func testTheSixBadges() {
        XCTAssertEqual(ResultRow.Product.allCases.map(\.badge), ["Checked · closed form", "Checked · closed form",
                                                                "Checked · closed form", "Checked · planted spots",
                                                                "Checked · closed form", "Unvalidated · indexing"])
        XCTAssertEqual(ResultRow.Product.allCases.map(\.rawValue), ["distance", "angle", "profile", "spot", "calibration", "ring"])
    }

    /// A file whose reader notes say it is unvalidated keeps the qualifier on every claim the CSV makes: the header's validation
    /// lines and the validation column end with ", unvalidated (reader note)", as `ProfileCSV`'s line does; a file without such a note
    /// has none. Red under: the clause dropped from the header or from the column; added for a validated file; a case-sensitive match.
    func testAnUnvalidatedFileKeepsItsQualifier() throws {
        let rows = [distance(), profile(), try spot()]
        let clause = ", unvalidated (reader note)"
        XCTAssertEqual(ResultsCSV.unvalidatedClause, clause)
        let flagged = try XCTUnwrap(ResultsCSV.text(rows, source: source(notes: ["Scale is UNVALIDATED"]), session: "s"))
        for product in [ResultRow.Product.distance, .profile, .spot] {
            XCTAssertEqual(header(flagged, "validation (\(product.rawValue))"), product.validation + clause)
        }
        let body = Array(split(flagged).rows.dropFirst())
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.product) })
        for line in body { XCTAssertEqual(line[7], (byID[line[1]]?.validation ?? "") + clause, "\(line[1]) \(line[3])") }
        let plain = try XCTUnwrap(ResultsCSV.text(rows, source: source(notes: ["a plain note"]), session: "s"))
        XCTAssertEqual(header(plain, "validation (distance)"), ImageMeasurement.validation)
        XCTAssertFalse(plain.contains("unvalidated (reader note)"))
    }

    /// "Validated" is never claimed: no sentence the room or the CSV shows contains it (only "unvalidated" may), and the distance
    /// and angle sentence claims what V1-5's P1 gated — closed forms, 1e-12, tools/parity/profile-parity — and the file's scale as stated.
    /// Red under: "validated" written into a sentence; the 1e-12 or the tool's name dropped.
    func testNoSentenceClaimsValidated() {
        for product in ResultRow.Product.allCases {
            for sentence in [product.validation, product.badge] {
                XCTAssertFalse(sentence.lowercased().replacingOccurrences(of: "unvalidated", with: "").contains("validated"),
                               "\(product): \(sentence)")
            }
        }
        XCTAssertTrue(ImageMeasurement.validation.contains("closed form"))
        XCTAssertTrue(ImageMeasurement.validation.contains("1e-12"))
        XCTAssertTrue(ImageMeasurement.validation.contains("tools/parity/profile-parity"))
        XCTAssertTrue(ImageMeasurement.validation.contains("as the file states it"))
        XCTAssertTrue(ProfileCSV.validation.contains("scikit-image 0.26.0"))
        XCTAssertTrue(FFTExport.spotsValidation.contains("tools/parity/spot-parity"))
    }

    /// The profile CSV's `# validation:` line is still its constant (the line was moved into `ProfileCSV.validation`, byte for byte),
    /// with the reader-note clause added when the file's notes say so. Red under: the constant edited without the line.
    func testTheProfileCSVStillWritesItsConstant() throws {
        let img = CalibratedImage(width: 8, height: 6, pixels: (0..<48).map(Float.init), x: Self.nmX, y: Self.nmY, fileName: "p.dm4",
                                  source: "o", voltage: nil, notes: [])
        let profile = LineProfile.sample(img, from: ImagePoint(x: 1, y: 2), to: ImagePoint(x: 5, y: 2), width: 1)
        let plain = try XCTUnwrap(ProfileCSV.text(profile, start: ImagePoint(x: 1, y: 2), end: ImagePoint(x: 5, y: 2),
                                                  source: ExportSource(image: img, software: Self.software)))
        XCTAssertTrue(plain.contains("\n# validation: \(ProfileCSV.validation)\n"))
        let flagged = CalibratedImage(width: 8, height: 6, pixels: (0..<48).map(Float.init), x: Self.nmX, y: Self.nmY, fileName: "p.dm4",
                                      source: "o", voltage: nil, notes: ["Unvalidated scale"])
        let text = try XCTUnwrap(ProfileCSV.text(profile, start: ImagePoint(x: 1, y: 2), end: ImagePoint(x: 5, y: 2),
                                                 source: ExportSource(image: flagged, software: Self.software)))
        XCTAssertTrue(text.contains("\n# validation: \(ProfileCSV.validation), unvalidated (reader note)\n"))
    }

    /// The `validation` column of every line is its product's constant, and the header carries one line per product present with the
    /// same sentence. Red under: the column filled from another product; a header line with another sentence.
    func testTheColumnAndTheHeaderCarryTheSameConstants() throws {
        let calibration = ResultRow.calibration(id: "calibration", label: "Calibration", standard: "Au", family: "{111}", d: 2.3546, radius: 33.97,
                                                deltaQ: 0.0125, wavelength: 0.0251, lengthPixels: 7510, lengthMM: nil, fitVersusFilePercent: -1)
        let ring = ResultRow.ring(id: "diffraction:1", label: "Ring 1", radius: 39.24, q: 0.49, d: 2.039, family: "{200}", dListed: 2.0391,
                                  deltaPercent: 0.01, odds: "> 10⁶ : 1", verdict: "accepted", refusal: nil)
        let rows = [distance(), angle(), profile(), try spot(), calibration, ring]
        let text = try XCTUnwrap(ResultsCSV.text(rows, source: source(), session: "s"))
        let parts = split(text)
        for product in ResultRow.Product.allCases {
            XCTAssertEqual(header(text, "validation (\(product.rawValue))"), product.validation)
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.product) })
        for line in parts.rows.dropFirst() { XCTAssertEqual(line[7], byID[line[1]]?.validation, "\(line[1]) \(line[3])") }
    }
}
