//
//  ProfileCSVTests.swift
//  The line-profile CSV (`ProfileCSV`): the whole text for a planted profile, the header's keys
//  in order, the one line that says what the app shows the positions in, the sanitising of every value that comes from
//  outside the program, `nan` / `inf` / `-inf`, RFC 4180 quoting of the column header, a number that ignores the user's
//  locale, a bit-exact round trip of every number, an empty profile that is not a file, and the "unvalidated" clause.
//  The parity against Python's own `float()` and the planted Velox, DM and GMS images is tools/parity/export-parity (P1); these
//  pin the writer's rules without Python and fail on the spot.
//  Mutations each test was broken by (all in ProfileCSV.swift): `%.17g` as `%.15g`;
//  `String(format:)` given `de_DE`; NaN written as `0`; -inf written as `inf`; positions multiplied by the shown factor;
//  the x and y scale lines swapped; the start's x and y swapped; an uncalibrated axis printed; `headerValue` skipping
//  U+2028, or turning every non-ASCII scalar into a space; the object not passed through `headerValue`; the column
//  header written unquoted; an empty profile giving "" instead of nil; the unvalidated test made case-sensitive;
//  CRLF line ends in the written file; (found in review) the y scale line's origin or unit written from x, the method line's
//  width written as a constant.
//

import ImagoCore
import XCTest
import TEMCore

nonisolated final class ProfileCSVTests: XCTestCase {

    // MARK: Fixtures

    private static let nmX = AxisCalibration(scale: 0.5, unit: "nm", origin: 0)
    private static let nmY = AxisCalibration(scale: 0.8, unit: "nm", origin: 0)

    /// A `w` × `h` image whose pixel at (row r, column c) is `f(r, c)`.
    private func image(_ w: Int, _ h: Int, x: AxisCalibration? = nil, y: AxisCalibration? = nil, fileName: String = "planted.dm4",
                       object: String = "ImageList.1", notes: [String] = [], _ f: (Int, Int) -> Float) -> CalibratedImage {
        CalibratedImage(width: w, height: h, pixels: (0..<(w * h)).map { f($0 / w, $0 % w) }, x: x, y: y,
                        fileName: fileName, source: object, voltage: nil, notes: notes)
    }

    private func source(_ image: CalibratedImage) -> ExportSource {
        ExportSource(image: image, software: "macTEM 0.1.0 (1)")
    }

    /// v = 100 + 3 r + 2 c on 8 × 6 pixels at 0.5 × 0.8 nm, the line (1, 2) → (5, 2): five samples on row 2, 0.5 nm apart,
    /// each exactly 106 + 2 c (a ramp is reproduced exactly by bilinear interpolation, float32 holds it exactly).
    private func planted(notes: [String] = [], fileName: String = "planted.dm4", object: String = "ImageList.1")
        -> (source: ExportSource, profile: LineProfile, start: ImagePoint, end: ImagePoint) {
        let img = image(8, 6, x: Self.nmX, y: Self.nmY, fileName: fileName, object: object, notes: notes) { r, c in
            Float(100 + 3 * r + 2 * c)
        }
        let start = ImagePoint(x: 1, y: 2), end = ImagePoint(x: 5, y: 2)
        return (source(img), LineProfile.sample(img, from: start, to: end, width: 1), start, end)
    }

    private func csv(_ p: (source: ExportSource, profile: LineProfile, start: ImagePoint, end: ImagePoint),
                     shown: (unit: String, factor: Double)? = nil,
                     file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(ProfileCSV.text(p.profile, start: p.start, end: p.end, source: p.source, shown: shown),
                      file: file, line: line)
    }

    /// The text split at LF; a file that ends with LF has an empty last element.
    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    /// The `# key: value` header lines up to the column header, the column header, and the data rows (`[position, value]`).
    private func parse(_ text: String) -> (header: [String], columns: String, rows: [[String]]) {
        let all = lines(text)
        let split = all.firstIndex { !$0.hasPrefix("#") } ?? all.count
        let rows = all.dropFirst(split + 1).filter { !$0.isEmpty }.map { $0.components(separatedBy: ",") }
        return (Array(all[..<split]), split < all.count ? all[split] : "", rows)
    }

    private func key(_ headerLine: String) -> String? {
        guard headerLine.hasPrefix("# "), let colon = headerLine.range(of: ": ") else { return nil }
        return String(headerLine[headerLine.index(headerLine.startIndex, offsetBy: 2)..<colon.lowerBound])
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileCSVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: The text

    /// Every byte of a small planted file, written out by hand: the header (its keys, their order, the points as Swift's
    /// shortest round trip, the scales as the file states them, the position's meaning), the column header, and the rows
    /// at `%.17g`, which drops trailing zeros. Red under: `%.15g` (not here, the numbers are short: see
    /// `testEveryNumberReadsBackBitEqual`), any header line reworded, reordered or dropped, CRLF, a BOM.
    func testTheTextIsExactForAPlantedProfile() throws {
        let text = try csv(planted())
        let expected = [
            "# macTEM line profile",
            "# software: macTEM 0.1.0 (1)",
            "# file: planted.dm4",
            "# object: ImageList.1",
            "# image: 8 x 6 px",
            "# start: x=1.0, y=2.0 (image pixels: x column, y row, pixel centres at integers)",
            "# end: x=5.0, y=2.0",
            "# width: 1 px",
            "# samples: 5",
            "# length: 2 nm",
            "# x scale: 0.5 nm per px, origin 0.0 px",
            "# y scale: 0.8 nm per px, origin 0.0 px",
            "# position: distance from the start along the line, in nm as the file states it "
                + "(not an axis coordinate; origins unused)",
            "# method: bilinear interpolation (order 1), scipy's \"reflect\" boundary (half-sample symmetric), "
                + "mean of 1 samples 1 px apart along the perpendicular on the pixel grid",
            "# notes: none",
            "# validation: samples compared with scikit-image 0.26.0 profile_line(order=1, mode=\"reflect\", "
                + "reduce_func=mean) (1e-5 relative; 1e-5 of the image's largest magnitude near zero); "
                + "calibration: as the file states it",
            "# lineage: none \u{2014} marks carry no lineage id until V1-2; the mark's parameters above stand in",
            "# numbers: %.17g (exact round trip); nan where a NaN pixel enters a sample",
            "position (nm),value",
            "0,108", "0.5,110", "1,112", "1.5,114", "2,116",
            "",
        ].joined(separator: "\n")
        XCTAssertEqual(text, expected)
    }

    func testTheHeaderKeysAreInTheContractsOrder() throws {
        let p = planted(notes: ["scale unvalidated (one acquisition)"])
        let text = try csv(p, shown: (unit: "nm", factor: 1e9))
        let parsed = parse(text)
        XCTAssertEqual(parsed.header.compactMap(key), [
            "software", "file", "object", "image", "start", "end", "width", "samples", "length", "x scale", "y scale",
            "position", "shown in macTEM as", "method", "notes", "validation", "lineage", "numbers",
        ])
        XCTAssertEqual(parsed.header.first, "# macTEM line profile")
        XCTAssertEqual(parsed.columns, "position (nm),value")
        XCTAssertEqual(parsed.rows.count, p.profile.samples.count)
        // Without `shown` the same file has the same keys minus that one.
        XCTAssertEqual(parse(try csv(p)).header.compactMap(key).filter { $0 == "shown in macTEM as" }, [])
    }

    /// A Velox pixel is 4.46179e-11 m: the file states metres, the positions stay in metres (the column header says so),
    /// and one line says what the app shows them in. Red under: the positions multiplied by the factor, the unit changed
    /// to the shown one, the line written when `shown` is nil or not written when it is given.
    func testTheShownLineSaysWhatTheAppShowsAndTheNumbersStayInTheFilesUnit() throws {
        let metres = AxisCalibration(scale: 4.46179e-11, unit: "m", origin: 0)
        let img = image(40, 30, x: metres, y: metres, fileName: "Camera Ceta.tif", object: "TIFF") { r, c in Float(r + c) }
        let start = ImagePoint(x: 2, y: 3), end = ImagePoint(x: 12, y: 3)
        let profile = LineProfile.sample(img, from: start, to: end, width: 1)
        XCTAssertEqual(profile.unit, "m")
        let src = source(img)
        let withShown = try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: src,
                                                      shown: (unit: "nm", factor: 1e9)))
        let without = try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: src))
        XCTAssertTrue(withShown.contains("\n# shown in macTEM as: nm (x 1000000000.0)\n"))
        XCTAssertFalse(without.contains("shown in macTEM"))
        XCTAssertEqual(lines(withShown).filter { $0.hasPrefix("# shown in macTEM as") }.count, 1)
        // The line sits between the position line and the method line, and nothing else differs.
        XCTAssertEqual(lines(withShown).filter { !$0.hasPrefix("# shown in macTEM as") }, lines(without))
        for text in [withShown, without] {
            let parsed = parse(text)
            XCTAssertEqual(parsed.columns, "position (m),value")
            XCTAssertTrue(parsed.header.contains("# x scale: 4.46179e-11 m per px, origin 0.0 px"))
            XCTAssertTrue(parsed.header.contains("# position: distance from the start along the line, in m as the file "
                                                 + "states it (not an axis coordinate; origins unused)"))
            XCTAssertTrue(parsed.header.contains("# length: \(CSVText.number(profile.positions.last ?? .nan)) m"))
            XCTAssertEqual(parsed.rows.map { Double($0[0])?.bitPattern }, profile.positions.map { $0.bitPattern },
                           "positions are the profile's own, in metres")
        }
    }

    func testTheHeaderPointsAndScalesReadBackBitEqual() throws {
        // 0.1 + 0.2 needs 17 digits: the shortest round trip is "0.30000000000000004", not "0.3".
        let a = 0.1 + 0.2, b = 1.0 / 3.0
        let axis = AxisCalibration(scale: a, unit: "nm", origin: 0.5)
        let img = image(30, 30, x: axis, y: axis) { r, c in Float(r * c) }
        let start = ImagePoint(x: a, y: b), end = ImagePoint(x: 20 + b, y: 12.75)
        let profile = LineProfile.sample(img, from: start, to: end, width: 3)
        let header = parse(try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: source(img)))).header
        func pair(_ prefix: String) -> (Double, Double)? {
            guard let line = header.first(where: { $0.hasPrefix(prefix) }),
                  let xs = line.range(of: "x="), let comma = line.range(of: ", y="), xs.upperBound <= comma.lowerBound
            else { return nil }
            let rest = line[comma.upperBound...]
            let yEnd = rest.firstIndex(of: " ") ?? rest.endIndex
            guard let x = Double(line[xs.upperBound..<comma.lowerBound]), let y = Double(rest[..<yEnd]) else { return nil }
            return (x, y)
        }
        let s = try XCTUnwrap(pair("# start: "))
        XCTAssertEqual(s.0.bitPattern, start.x.bitPattern, "start x is the first number, not y")
        XCTAssertEqual(s.1.bitPattern, start.y.bitPattern)
        let e = try XCTUnwrap(pair("# end: "))
        XCTAssertEqual(e.0.bitPattern, end.x.bitPattern)
        XCTAssertEqual(e.1.bitPattern, end.y.bitPattern)
        XCTAssertTrue(header.contains("# width: 3 px"))
        XCTAssertTrue(header.contains("# samples: \(profile.samples.count)"))
        XCTAssertTrue(header.contains("# x scale: 0.30000000000000004 nm per px, origin 0.5 px"))
        XCTAssertTrue(header.contains("# y scale: 0.30000000000000004 nm per px, origin 0.5 px"))
    }

    /// An uncalibrated axis, or one with a non-physical scale, is `none` (the same rule as the scale bar's), and the
    /// positions are pixels.
    func testAnUncalibratedAxisIsNoneAndThePositionsArePixels() throws {
        let img = image(10, 10, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                        y: AxisCalibration(scale: 0, unit: "nm", origin: 0)) { r, c in Float(r + c) }
        let start = ImagePoint(x: 0, y: 0), end = ImagePoint(x: 3, y: 4)
        let profile = LineProfile.sample(img, from: start, to: end, width: 1)
        let parsed = parse(try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: source(img))))
        XCTAssertTrue(parsed.header.contains("# x scale: 0.5 nm per px, origin 0.0 px"))
        XCTAssertTrue(parsed.header.contains("# y scale: none"))
        XCTAssertEqual(parsed.columns, "position (px),value")
        XCTAssertTrue(parsed.header.contains("# length: 5 px"))
        let bare = image(10, 10) { r, c in Float(r + c) }
        let bareProfile = LineProfile.sample(bare, from: start, to: end, width: 1)
        let bareHeader = parse(try XCTUnwrap(ProfileCSV.text(bareProfile, start: start, end: end, source: source(bare)))).header
        XCTAssertTrue(bareHeader.contains("# x scale: none"))
        XCTAssertTrue(bareHeader.contains("# y scale: none"))
    }

    /// Each scale line carries its OWN axis's scale, unit and origin, with an origin and a unit that differ between x and y:
    /// first nm and µm (two units, so the positions are pixels), then nm and nm. Red under: the y line's origin written from
    /// x, or the reverse; the y line's unit written from x.
    func testEachScaleLineCarriesItsOwnAxisOriginAndUnit() throws {
        let start = ImagePoint(x: 1, y: 1), end = ImagePoint(x: 9, y: 2)
        func header(x: AxisCalibration, y: AxisCalibration) throws -> [String] {
            let img = image(16, 4, x: x, y: y) { r, c in Float(r * 16 + c) }
            let profile = LineProfile.sample(img, from: start, to: end, width: 1)
            return parse(try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: source(img)))).header
        }
        let mixed = try header(x: AxisCalibration(scale: 0.5, unit: "nm", origin: 12),
                               y: AxisCalibration(scale: 0.8, unit: "\u{00B5}m", origin: -4.5))
        XCTAssertTrue(mixed.contains("# x scale: 0.5 nm per px, origin 12.0 px"), "\(mixed)")
        XCTAssertTrue(mixed.contains("# y scale: 0.8 \u{00B5}m per px, origin -4.5 px"), "\(mixed)")
        let same = try header(x: AxisCalibration(scale: 0.5, unit: "nm", origin: 12),
                              y: AxisCalibration(scale: 0.8, unit: "nm", origin: -4.5))
        XCTAssertTrue(same.contains("# x scale: 0.5 nm per px, origin 12.0 px"), "\(same)")
        XCTAssertTrue(same.contains("# y scale: 0.8 nm per px, origin -4.5 px"), "\(same)")
    }

    /// The method line names the width the samples were averaged over, the same width the `width:` line states. Red under:
    /// the width written as a constant in the method line.
    func testTheMethodLineNamesTheProfilesWidth() throws {
        let img = image(16, 4, x: Self.nmX, y: Self.nmY) { r, c in Float(r * 16 + c) }
        let start = ImagePoint(x: 1, y: 1), end = ImagePoint(x: 9, y: 2)
        let profile = LineProfile.sample(img, from: start, to: end, width: 4)
        XCTAssertEqual(profile.width, 4)
        let header = parse(try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: source(img)))).header
        XCTAssertTrue(header.contains("# width: 4 px"), "\(header)")
        XCTAssertTrue(header.contains("# method: bilinear interpolation (order 1), scipy's \"reflect\" boundary "
                                      + "(half-sample symmetric), mean of 4 samples 1 px apart along the perpendicular on the pixel grid"),
                      "\(header)")
    }

    // MARK: Sanitising

    func testHeaderValueTurnsControlsAndLineSeparatorsIntoSpaces() {
        // Every C0 control, DEL, every C1 control (U+0085 among them), U+2028 and U+2029.
        let controls = Array(0x00...0x1F) + [0x7F] + Array(0x80...0x9F) + [0x2028, 0x2029]
        for value in controls {
            let scalar = Unicode.Scalar(UInt32(value))!
            XCTAssertEqual(CSVText.headerValue("a\(Character(scalar))b"), "a b", "U+\(String(value, radix: 16, uppercase: true))")
        }
        // "\r\n" is ONE Character in Swift: a Character-wise replace would miss it. Two scalars, two spaces.
        XCTAssertEqual(CSVText.headerValue("a\r\nb"), "a  b")
        XCTAssertEqual(CSVText.headerValue("a\rb\nc"), "a b c")
        // Everything else is untouched: printable ASCII, the no-break space (U+00A0), accents, Å, µ, a dash, an emoji.
        let kept = "Az 09 ~!\"#%&'()*+,-./:;<=>?@[\\]^_`{|} \u{00A0}\u{00A1}\u{00E9}\u{00C5}\u{00B5}m \u{2014} \u{1F52C}"
        XCTAssertEqual(CSVText.headerValue(kept), kept)
        XCTAssertEqual(CSVText.headerValue(""), "")
    }

    /// A value from outside (the file name, the object, the notes, the unit, the software) can never end its own header
    /// line or start another: whatever it holds, the file has exactly the lines it was written with.
    func testNoValueFromOutsideCanBreakALine() throws {
        let hostile = "a\nb\r\nc\u{85}d\u{2028}e\u{2029}f\u{7F}g\th\u{0}i"
        let img = image(8, 6, x: AxisCalibration(scale: 0.5, unit: "n\nm", origin: 0), y: AxisCalibration(scale: 0.5, unit: "n\nm", origin: 0),
                        fileName: hostile, object: hostile, notes: [hostile, "second\rnote"]) { r, c in Float(r + c) }
        let start = ImagePoint(x: 0, y: 1), end = ImagePoint(x: 4, y: 1)
        let profile = LineProfile.sample(img, from: start, to: end, width: 1)
        let src = ExportSource(image: img, software: "macTEM\n0.1.0")
        let text = try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: src,
                                                 shown: (unit: "u\u{2028}x", factor: 2)))
        for bad: UInt32 in [0x0D, 0x85, 0x2028, 0x2029, 0x7F, 0x09, 0x00] {
            XCTAssertFalse(text.unicodeScalars.contains { $0.value == bad }, "U+\(String(bad, radix: 16, uppercase: true))")
        }
        let parsed = parse(text)
        // 18 comment lines (19 with the shown line), the column header, 5 rows, the empty element after the last LF.
        XCTAssertEqual(parsed.header.count, 19)
        XCTAssertEqual(lines(text).count, 19 + 1 + 5 + 1)
        XCTAssertTrue(parsed.header.allSatisfy { $0.hasPrefix("# ") })
        XCTAssertTrue(parsed.header.contains("# file: a b  c d e f g h i"))
        XCTAssertTrue(parsed.header.contains("# object: a b  c d e f g h i"))
        XCTAssertTrue(parsed.header.contains("# software: macTEM 0.1.0"))
        XCTAssertTrue(parsed.header.contains("# notes: a b  c d e f g h i; second note"))
        XCTAssertTrue(parsed.header.contains("# shown in macTEM as: u x (x 2.0)"))
        XCTAssertTrue(parsed.header.contains("# x scale: 0.5 n m per px, origin 0.0 px"))
        XCTAssertEqual(parsed.columns, "position (n m),value")
    }

    /// "Å" and "µ" are written as UTF-8 and read back intact (not as `?`, not as Latin-1 mojibake).
    func testNonASCIIIsWrittenAsUTF8() throws {
        let angstrom = "\u{00C5}", micro = "\u{00B5}"
        let img = image(8, 6, x: AxisCalibration(scale: 0.25, unit: angstrom, origin: 0), y: AxisCalibration(scale: 0.25, unit: angstrom, origin: 0),
                        fileName: "sample \(angstrom) \(micro).dm4", notes: ["\(micro)-note"]) { r, c in Float(r + c) }
        let start = ImagePoint(x: 0, y: 0), end = ImagePoint(x: 4, y: 0)
        let text = try XCTUnwrap(ProfileCSV.text(LineProfile.sample(img, from: start, to: end, width: 1), start: start, end: end,
                                                 source: source(img)))
        XCTAssertTrue(text.contains("# file: sample \(angstrom) \(micro).dm4\n"))
        XCTAssertTrue(text.contains("# x scale: 0.25 \(angstrom) per px, origin 0.0 px\n"))
        XCTAssertTrue(text.contains("# notes: \(micro)-note\n"))
        XCTAssertTrue(text.contains("\nposition (\(angstrom)),value\n"))
        XCTAssertEqual(String(decoding: Data(text.utf8), as: UTF8.self), text)
    }

    // MARK: nan, inf

    func testNumberSpellsNonFiniteValuesAsText() {
        XCTAssertEqual(CSVText.number(.nan), "nan")
        XCTAssertEqual(CSVText.number(-Double.nan), "nan", "never \"-nan\"")
        XCTAssertEqual(CSVText.number(Double(sign: .minus, exponentBitPattern: 0x7FF, significandBitPattern: 1)), "nan",
                       "a signalling NaN with its sign bit set")
        XCTAssertEqual(CSVText.number(.infinity), "inf")
        XCTAssertEqual(CSVText.number(-.infinity), "-inf")
    }

    /// A NaN pixel poisons the samples that have it among their four neighbours (`LineProfile`); +∞ and −∞ pixels do
    /// likewise (∞ × 0 is NaN). Each is a cell of text, never 0 and never empty, and every cell reads back as the Double
    /// it was written from. Red under: NaN written as 0, `-nan`, an empty cell.
    func testANaNOrInfinitePixelIsWrittenAsNanInfOrMinusInf() throws {
        let img = image(12, 3) { r, c in
            switch (r, c) {
            case (1, 3): return .nan
            case (1, 6): return .infinity
            case (1, 9): return -.infinity
            default: return Float(10 + c)
            }
        }
        let start = ImagePoint(x: 0, y: 1), end = ImagePoint(x: 11, y: 1)
        let profile = LineProfile.sample(img, from: start, to: end, width: 1)
        XCTAssertEqual(profile.samples.count, 12)
        XCTAssertTrue(profile.samples.contains { $0.isNaN } && profile.samples.contains(.infinity) && profile.samples.contains(-.infinity),
                      "the planted image must produce a NaN, an inf and a -inf sample: \(profile.samples)")
        let parsed = parse(try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: source(img))))
        XCTAssertEqual(parsed.rows.count, 12)
        for (row, sample) in zip(parsed.rows, profile.samples) {
            XCTAssertEqual(row.count, 2, "\(row)")
            XCTAssertFalse(row[1].isEmpty)
            let back = try XCTUnwrap(Double(row[1]), "cell \"\(row[1])\"")
            if sample.isNaN {
                XCTAssertEqual(row[1], "nan")
                XCTAssertTrue(back.isNaN)
            } else {
                XCTAssertEqual(back.bitPattern, sample.bitPattern, row[1])
                if sample.isInfinite { XCTAssertEqual(row[1], sample < 0 ? "-inf" : "inf") }
            }
        }
        let cells = Set(parsed.rows.map { $0[1] })
        XCTAssertTrue(cells.isSuperset(of: ["nan", "inf", "-inf"]), "\(cells)")
    }

    // MARK: Quoting

    /// A comma, a quote, CR or LF in the first cell of the column header quotes it, with the inner quotes doubled
    /// (RFC 4180). The unit is whatever the file wrote; CR and LF are already spaces by then (`headerValue`).
    func testTheColumnHeaderIsQuotedWhenItsUnitNeedsIt() throws {
        func columnHeader(_ unit: String) throws -> String {
            let axis = AxisCalibration(scale: 1, unit: unit, origin: 0)
            let img = image(6, 6, x: axis, y: axis) { r, c in Float(r + c) }
            let start = ImagePoint(x: 0, y: 0), end = ImagePoint(x: 3, y: 0)
            return parse(try XCTUnwrap(ProfileCSV.text(LineProfile.sample(img, from: start, to: end, width: 1), start: start,
                                                       end: end, source: source(img)))).columns
        }
        XCTAssertEqual(try columnHeader("nm"), "position (nm),value")
        XCTAssertEqual(try columnHeader("counts per px"), "position (counts per px),value", "a space needs no quotes")
        XCTAssertEqual(try columnHeader("a,b"), "\"position (a,b)\",value")
        XCTAssertEqual(try columnHeader("a\"b"), "\"position (a\"\"b)\",value")
        XCTAssertEqual(try columnHeader("a,b\"c"), "\"position (a,b\"\"c)\",value")
        XCTAssertEqual(try columnHeader("n\r\nm"), "position (n  m),value", "CR and LF are spaces before quoting is asked")
        // The quoted cell reads back as the unit: a reader of RFC 4180 gets "position (a,b"c)" and "value".
        XCTAssertEqual(Self.firstRecord("\"position (a,b\"\"c)\",value"), ["position (a,b\"c)", "value"])
    }

    /// A minimal RFC 4180 reader for one line: quoted cells with doubled quotes, commas between.
    private static func firstRecord(_ line: String) -> [String] {
        var cells: [String] = [], cell = "", quoted = false
        let characters = Array(line)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < characters.count, characters[i + 1] == "\"" { cell.append("\""); i += 1 } else { quoted = false }
                } else { cell.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { cells.append(cell); cell = "" }
            else { cell.append(c) }
            i += 1
        }
        cells.append(cell)
        return cells
    }

    // MARK: Locale

    /// A de_DE user still gets a point. `String(format:)` with no locale argument is POSIX whatever the process says; the
    /// control shows the locale WOULD have mattered (Foundation's locale path writes "0,1", a comma and fewer digits),
    /// and the C locale is set to de_DE for the duration. Red under: `String(format:locale:)` with a German locale.
    func testTheNumbersIgnoreTheLocale() throws {
        let german = Locale(identifier: "de_DE")
        XCTAssertTrue(String(format: "%.17g", locale: german, 0.1).contains(","), "the control: a German locale writes a comma")
        let saved = setlocale(LC_ALL, nil).map { String(cString: $0) } ?? "C"
        _ = try XCTUnwrap(setlocale(LC_ALL, "de_DE.UTF-8"), "de_DE.UTF-8 is not installed")
        defer { setlocale(LC_ALL, saved) }
        XCTAssertEqual(CSVText.number(0.1), "0.10000000000000001")
        XCTAssertEqual(CSVText.number(-1234.5), "-1234.5")
        XCTAssertEqual(CSVText.number(1e-5), "1.0000000000000001e-05")
        let p = planted()
        let text = try csv((p.source, p.profile, p.start, p.end), shown: (unit: "nm", factor: 1e9))
        XCTAssertTrue(text.contains("\n0.5,110\n"), "a row has a point, and exactly one comma")
        for row in parse(text).rows { XCTAssertEqual(row.count, 2, "\(row)") }
    }

    // MARK: Round trip

    /// `%.17g` is the shortest format that reads back every Double: the awkward ones (a third, a tenth, a subnormal, the
    /// largest and the smallest, negative zero) and a deterministic spread of random bit patterns all come back bit for
    /// bit. Red under: `%.15g` (0.1 + 0.2 and 1/3 come back different), `%g`, a float32 cast.
    func testEveryNumberReadsBackBitEqual() throws {
        var values: [Double] = [0.1, 0.2, 0.1 + 0.2, 1.0 / 3.0, 2.0 / 3.0, -0.0, 0.0, 1, -1, .pi, 1e-5, 123456789.123456789,
                                1e22, 1e23, 5e-324, 2.2250738585072009e-308, 2.2250738585072014e-308, 1e-310,
                                .leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude,
                                -.greatestFiniteMagnitude, 4.46179e-11, 4.46179e-10, 0.30000000000000004]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<20_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let v = Double(bitPattern: state ^ (state << 29))
            if v.isFinite { values.append(v) }
        }
        for v in values {
            let text = CSVText.number(v)
            guard let back = Double(text) else { XCTFail("\"\(text)\" does not parse (\(v))"); continue }
            XCTAssertEqual(back.bitPattern, v.bitPattern, "\(v) -> \"\(text)\" -> \(back)")
        }
        XCTAssertEqual(CSVText.number(-0.0), "-0")
        XCTAssertEqual(CSVText.number(0.1), "0.10000000000000001")
        XCTAssertEqual(CSVText.number(5e-324), "4.9406564584124654e-324")
        XCTAssertEqual(CSVText.number(2), "2")
        XCTAssertEqual(CSVText.number(0.5), "0.5", "trailing zeros are dropped")
        XCTAssertEqual(CSVText.number(1e22), "1e+22")
    }

    /// The same, through the file: an oblique, width-3 profile on pseudo-random pixels at an awkward calibration, every
    /// position and every sample cell re-read from the text equals the in-memory Double, bit for bit, in order.
    func testEveryRowOfARealProfileReadsBackBitEqual() throws {
        let axis = AxisCalibration(scale: 0.0123, unit: "nm", origin: 0)
        let img = image(37, 53, x: axis, y: axis) { r, c in
            Float(sin(Double(r * 37 + c) * 1.3) * 1000 + Double((r * 5 + c * 3) % 7) / 3)
        }
        let start = ImagePoint(x: 3.3, y: 1.7), end = ImagePoint(x: 30.1, y: 45.9)
        let profile = LineProfile.sample(img, from: start, to: end, width: 3)
        XCTAssertGreaterThan(profile.samples.count, 50)
        let rows = parse(try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: source(img)))).rows
        XCTAssertEqual(rows.count, profile.samples.count)
        for (i, row) in rows.enumerated() where i < profile.samples.count {
            XCTAssertEqual(row.count, 2)
            XCTAssertEqual(Double(row[0])?.bitPattern, profile.positions[i].bitPattern, "position \(i): \(row[0])")
            XCTAssertEqual(Double(row[1])?.bitPattern, profile.samples[i].bitPattern, "sample \(i): \(row[1])")
        }
    }

    // MARK: Empty, unvalidated, the file

    /// No samples, no file: `text` is nil, and `export` refuses by name and writes nothing.
    func testAProfileWithNoSamplesIsNotExported() async throws {
        let img = image(6, 6) { r, c in Float(r + c) }
        let start = ImagePoint(x: 0, y: 0), end = ImagePoint(x: .nan, y: 3)
        let empty = LineProfile.sample(img, from: start, to: end, width: 1)
        XCTAssertTrue(empty.samples.isEmpty)
        XCTAssertNil(ProfileCSV.text(empty, start: start, end: end, source: source(img)))
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("empty.csv")
        do {
            try await ProfileCSV.export(empty, start: start, end: end, source: source(img), shown: nil, to: url)
            XCTFail("an empty profile was exported")
        } catch {
            XCTAssertEqual(error as? ExportFile.Failure, .noSamples)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testTheUnvalidatedNoteAddsItsClauseToTheValidationLine() throws {
        func validation(_ notes: [String]) throws -> String {
            let header = parse(try csv(planted(notes: notes))).header
            return try XCTUnwrap(header.first { $0.hasPrefix("# validation: ") })
        }
        let plain = "# validation: samples compared with scikit-image 0.26.0 profile_line(order=1, mode=\"reflect\", "
            + "reduce_func=mean) (1e-5 relative; 1e-5 of the image's largest magnitude near zero); "
            + "calibration: as the file states it"
        XCTAssertEqual(try validation([]), plain)
        XCTAssertEqual(try validation(["8-bit render, not counts"]), plain, "a note that does not say unvalidated")
        let flagged = plain + ", unvalidated (reader note)"
        XCTAssertEqual(try validation(["scale unvalidated (one acquisition)"]), flagged)
        XCTAssertEqual(try validation(["Unvalidated scale"]), flagged, "case-insensitive")
        XCTAssertEqual(try validation(["fine", "x UNVALIDATED y"]), flagged, "any one note")
        // The notes themselves stay verbatim and in order, joined by "; ".
        let notes = parse(try csv(planted(notes: ["8-bit render, not counts", "scale unvalidated (one acquisition)"]))).header
        XCTAssertTrue(notes.contains("# notes: 8-bit render, not counts; scale unvalidated (one acquisition)"))
        XCTAssertTrue(parse(try csv(planted())).header.contains("# notes: none"))
    }

    /// `export` writes `text` as UTF-8 bytes: no BOM, no CR, a trailing LF, and the file ends where the text does.
    func testExportWritesTheTextAsUTF8WithLFLineEnds() async throws {
        let angstrom = "\u{00C5}", micro = "\u{00B5}"
        let img = image(8, 6, x: AxisCalibration(scale: 0.25, unit: angstrom, origin: 0), y: AxisCalibration(scale: 0.25, unit: angstrom, origin: 0),
                        fileName: "sample \(angstrom) \(micro).dm4") { r, c in Float(100 + 3 * r + 2 * c) }
        let start = ImagePoint(x: 1, y: 2), end = ImagePoint(x: 5, y: 2)
        let profile = LineProfile.sample(img, from: start, to: end, width: 1)
        let src = source(img)
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("profile.csv")
        try await ProfileCSV.export(profile, start: start, end: end, source: src, shown: (unit: "nm", factor: 0.1), to: url)
        let bytes = try Data(contentsOf: url)
        let expected = try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end, source: src, shown: (unit: "nm", factor: 0.1)))
        XCTAssertEqual(bytes, Data(expected.utf8))
        XCTAssertNotEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF], "no byte order mark")
        XCTAssertFalse(bytes.contains(0x0D), "no CR")
        XCTAssertEqual(bytes.last, 0x0A, "ends with LF")
        XCTAssertNotEqual(bytes.suffix(2), Data([0x0A, 0x0A]), "and with one")
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("# file: sample \(angstrom) \(micro).dm4\n"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["profile.csv"])
    }
}
