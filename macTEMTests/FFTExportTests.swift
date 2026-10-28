//
//  FFTExportTests.swift
//  The FFT room's export writers and the additions they made to the PNG writer (archive: roadmap-registrations-2026-10-15.md V1-10 slice 2, `FFTExport`,
//  `RadialProfileCSV`, `SpotsCSV`, `ImageExport.Provenance`, `Mark.Kind.spot`; archive: fft-export-design-2026-10-14.md),
//  read back from the text and the bytes they write. Tier 2: tests that fail when the code is broken. The parity against
//  Python's own float, Pillow and numpy over a planted image is tools/parity/export-parity (F-1 to F-5).
//
//  Mutations sampled (each applied alone to a scratch copy of the production file, the named test went red; logs in the
//  lane's report): RadialProfileCSV: `%.17g` as `%.6g` (the values test); the centre (k + 1/2)·w as k·w (the centres test);
//  `count > 0` dropped (the empty-bins test); "NO window" as "Hann-windowed" in `transformNote` (the header test).
//  SpotsCSV: the in-mask flag inverted (the flags test).
//  ImageExport: the spot's ring drawn one pixel low (the ring test, with a 0.15 px tolerance on a spot at a pixel centre); Provenance applied when nil / not replacing validation
//  (the provenance tests).
//

import XCTest
import ImageIO
import TEMCore
import ImagoCore
import ImagoFFT

nonisolated final class FFTExportTests: XCTestCase {

    // MARK: Fixtures

    private static let software = "macTEM 0.1.0 (1)"
    private static let region = PixelCrop(row: 0, col: 16, height: 64, width: 64)

    /// The planted image's header for `region` (96 × 64 at 0.05 × 0.04 nm): spectrum 64 × 64, Δq = 1/(64·d).
    private static func header(crop: PixelCrop? = region, fileName: String = "plant.dm4", notes: [String] = []) -> FFTExportHeader {
        let w = crop?.width ?? 96, h = crop?.height ?? 64
        return FFTExportHeader(software: software, fileName: fileName, object: "ImageList.1", imageWidth: 96, imageHeight: 64,
                               x: AxisCalibration(scale: 0.05, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.04, unit: "nm", origin: 0),
                               notes: notes, crop: crop, spectrumWidth: w, spectrumHeight: h, spacingX: 1.0 / (Double(w) * 0.05),
                               spacingY: 1.0 / (Double(h) * 0.04), unitsX: "1/nm", unitsY: "1/nm")
    }

    private static func spectrum() throws -> PowerSpectrum {
        try PowerSpectrum.compute(FFTAnalysisTests.plant().micrograph, crop: region)
    }

    /// The lines of a CSV that are data: after the column-header line (the first line that does not start with "#").
    private static func table(_ text: String) -> (header: [String], rows: [[String]], comments: [String]) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let comments = lines.filter { $0.hasPrefix("#") }
        let data = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        return (data[0].components(separatedBy: ","), data.dropFirst().map { $0.components(separatedBy: ",") }, comments)
    }

    // MARK: The radial profile

    /// Every mean, centre and count in the file is the in-memory value: `Double(cell)` equals it bit for bit, and the rows are
    /// the populated bins in order. Red under: `%.17g` as `%.6g`; the centre as k·w; bin 0 written; the shown column not
    /// the unit column times the app's factor.
    func testTheRadialProfileCSVRowsAreTheProfilesValuesBitForBit() throws {
        let profile = try RadialProfile.compute(Self.spectrum())
        let text = try XCTUnwrap(RadialProfileCSV.text(profile, header: Self.header()))
        let t = Self.table(text)
        XCTAssertEqual(t.header, ["bin", "|q| centre (nm\u{207B}\u{00B9})", "|q| centre (1/nm)", "mean |F|^2", "count"])
        // The rows are the room's chart points: k >= 1 with a pixel. Bin 0 (the DC) is not in the file.
        let populated = profile.count.indices.filter { $0 >= 1 && profile.count[$0] > 0 }
        XCTAssertEqual(t.rows.count, populated.count)
        XCTAssertEqual(t.rows.count, profile.points.count, "the file holds what the chart draws")
        XCTAssertGreaterThan(profile.count[0], 0, "the fixture's bin 0 is populated, so its absence is the rule")
        XCTAssertFalse(t.rows.contains { $0[0] == "0" }, "the DC bin is not written")
        XCTAssertTrue(t.comments.contains { $0.hasPrefix("# omitted: bin 0, the DC bin") })
        let factor = FFTUnits.spectrumUnit(profile.units).factor
        for (row, k) in zip(t.rows, populated) {
            XCTAssertEqual(row[0], "\(k)")
            let centre = (Double(k) + 0.5) * profile.width
            XCTAssertEqual(Double(row[2])?.bitPattern, centre.bitPattern, "centre \(k)")
            XCTAssertEqual(Double(row[1])?.bitPattern, (centre * factor).bitPattern, "shown centre \(k)")
            XCTAssertEqual(Double(row[3])?.bitPattern, profile.mean[k].bitPattern, "mean \(k)")
            XCTAssertEqual(Int(row[4]), profile.count[k], "count \(k)")
        }
    }

    /// A bin no pixel falls into has no row (the profile holds mean 0 there, which is not a measurement). Red under:
    /// `count > 0` dropped.
    func testTheRadialProfileCSVOmitsBinsWithNoPixel() throws {
        let spectrum = try Self.spectrum()
        let fine = try RadialProfile.compute(spectrum, width: spectrum.spacingX / 3)
        let empty = fine.count.indices.filter { fine.count[$0] == 0 }
        XCTAssertFalse(empty.isEmpty, "the fixture must have empty bins")
        let t = Self.table(try XCTUnwrap(RadialProfileCSV.text(fine, header: Self.header())))
        let written = Set(t.rows.compactMap { Int($0[0]) })
        XCTAssertTrue(written.isDisjoint(with: empty))
        XCTAssertEqual(t.rows.count, fine.count.count - empty.count - 1, "bin 0 (populated) is not written either")
    }

    /// The header says what the numbers are of: unwindowed and with the mean in, the region, the steps, the sentences. Red
    /// under: the transform's note saying Hann (it is the spot estimator that windows).
    func testTheRadialProfileHeaderSaysUnwindowedAndNamesTheRegionAndTheSteps() throws {
        let profile = try RadialProfile.compute(Self.spectrum())
        let text = try XCTUnwrap(RadialProfileCSV.text(profile, header: Self.header(notes: ["a note"])))
        let c = Self.table(text).comments
        XCTAssertEqual(c.first, "# macTEM radial profile")
        XCTAssertTrue(text.contains("NO window, the mean NOT removed"))
        XCTAssertFalse(text.contains("Hann"), "the profile is of the unwindowed transform")
        XCTAssertTrue(c.contains("# subject: region 64 x 64 px at (16, 0) (column, row of its top-left pixel)"))
        XCTAssertTrue(c.contains("# software: macTEM 0.1.0 (1)"))
        XCTAssertTrue(c.contains("# x scale: 0.05 nm per px, origin 0.0 px"), "\(c)")
        XCTAssertTrue(c.contains("# spectrum: 64 x 64 bins"))
        XCTAssertTrue(c.contains("# dq x: \(CSVText.number(1.0 / (64 * 0.05))) 1/nm per bin (\(CSVText.number(1.0 / (64 * 0.05))) nm\u{207B}\u{00B9})"), "\(c)")
        XCTAssertTrue(c.contains("# notes: a note"))
        XCTAssertTrue(c.contains { $0.hasPrefix("# validation: ") && $0.contains("numpy 2.5.4") })
        XCTAssertTrue(c.contains { $0.hasPrefix("# lineage: none") })
        XCTAssertTrue(c.contains { $0.hasPrefix("# bin width: ") })
        XCTAssertTrue(text.hasSuffix("\n") && !text.contains("\r"))
    }

    /// A control character in a name or a note becomes a space, as in the image export's CSV.
    func testControlCharactersInAFileNameAreSpaces() throws {
        let profile = try RadialProfile.compute(Self.spectrum())
        let text = try XCTUnwrap(RadialProfileCSV.text(profile, header: Self.header(fileName: "a\nb\u{2028}c.dm4")))
        XCTAssertTrue(text.contains("# file: a b c.dm4\n"))
    }

    func testAWholeImageIsNamedAsSuch() throws {
        XCTAssertEqual(FFTExportText.subject(crop: nil, imageWidth: 96, imageHeight: 64), "the whole image, 96 x 64 px")
    }

    // MARK: The spots

    private static func rows() throws -> [SpotsCSV.Row] {
        let a = try FFTAnalysisTests.measured(row: 37, col: 40)
        let b = try FFTAnalysisTests.measured(row: 29, col: 44)
        return [SpotsCSV.Row(number: 1, measured: a, inMask: true), SpotsCSV.Row(number: 3, measured: b, inMask: false)]
    }

    private static func spotsText(notes: [String] = [], omitted: Int = 1) throws -> String {
        try XCTUnwrap(SpotsCSV.text(rows: rows(), omitted: omitted, maskRadius: 3, maskEdge: 2, notes: notes, header: header()))
    }

    /// The numbers are the SpotMeasurement's Doubles bit for bit, the shown columns
    /// are the app's own conversion, and the flags are the list's. Red under: `%.6g`; the mask flag inverted; the shown columns not `FFTUnits`'.
    func testTheSpotsCSVRowsAreTheMeasuredValuesAndTheAppsOwnConversion() throws {
        let rows = try Self.rows()
        let t = Self.table(try Self.spotsText())
        XCTAssertEqual(t.header, ["spot", "d (nm)", "|q| (nm\u{207B}\u{00B9})", "in mask", "neighbour", "d (nm)",
                                  "|q| (1/nm)", "qx (1/nm)", "qy (1/nm)", "centroid col", "centroid row", "click col", "click row"])
        XCTAssertEqual(t.rows.count, 2)
        for (cells, row) in zip(t.rows, rows) {
            let m = row.measured
            XCTAssertEqual(Int(cells[0]), row.number)
            XCTAssertEqual(Double(cells[1])?.bitPattern, FFTUnits.length(m.d, unit: m.units).value.bitPattern)
            XCTAssertEqual(Double(cells[2])?.bitPattern, FFTUnits.reciprocal(m.q, realUnit: m.units).value.bitPattern)
            let qx = try XCTUnwrap(Double(cells[7])), qy = try XCTUnwrap(Double(cells[8]))
            XCTAssertEqual(qx.bitPattern, m.qx.bitPattern)
            XCTAssertEqual(qy.bitPattern, m.qy.bitPattern)
            XCTAssertEqual(cells[3], row.inMask ? "1" : "0")
            XCTAssertEqual(cells[4], m.neighbour ? "1" : "0")
            XCTAssertEqual(Double(cells[5])?.bitPattern, m.d.bitPattern)
            XCTAssertEqual(Double(cells[6])?.bitPattern, m.q.bitPattern)
            XCTAssertEqual(Double(cells[9])?.bitPattern, m.centroidCol.bitPattern)
            XCTAssertEqual(Double(cells[10])?.bitPattern, m.centroidRow.bitPattern)
            XCTAssertEqual(Int(cells[11]), m.clickedCol)
            XCTAssertEqual(Int(cells[12]), m.clickedRow)
        }
    }

    func testTheSpotsHeaderStatesTheEstimatorTheMaskTheOmittedAndTheNotes() throws {
        let text = try Self.spotsText(notes: ["With noise, d is good to 1\u{2013}5 % at 64 px."], omitted: 4)
        let c = Self.table(text).comments
        XCTAssertEqual(c.first, "# macTEM spots")
        XCTAssertTrue(text.contains("Hann-windowed, mean-removed copy of the region (the transform above is not)"))
        XCTAssertTrue(c.contains { $0.hasPrefix("# listed: 2 measured spots; not listed: 4") })
        XCTAssertTrue(c.contains("# mask: radius 3 bins, edge 2 bins (the masked inverse)"), "\(c)")
        XCTAssertTrue(c.contains("# note: With noise, d is good to 1\u{2013}5 % at 64 px."))
        XCTAssertTrue(c.contains { $0.hasPrefix("# validation: ") && $0.contains("planted spots") })
        XCTAssertTrue(c.contains { $0.hasPrefix("# lineage: none") })
        XCTAssertTrue(c.contains("# subject: region 64 x 64 px at (16, 0) (column, row of its top-left pixel)"))
    }

    func testNoMeasuredSpotWritesNothing() {
        XCTAssertNil(SpotsCSV.text(rows: [], omitted: 2, maskRadius: 3, maskEdge: 2, notes: [], header: Self.header()))
    }

    // MARK: The transform's source and Description

    /// The spectrum's "axes" are the steps in the shown unit, so the screen's bar rule applies to |q|. Red under: the
    /// factor dropped (1/nm is nm⁻¹ here, but a 1/m spectrum shows it), the y step taken from x.
    func testTheTransformSourceCarriesTheStepsInTheShownUnitAsAxes() {
        var h = Self.header()
        h.unitsX = "1/m"; h.unitsY = "1/m"; h.spacingX = 2e7; h.spacingY = 4e7
        let source = FFTExport.transformSource(h)
        XCTAssertEqual(source.width, 64); XCTAssertEqual(source.height, 64)
        XCTAssertEqual(source.x?.unit, "nm\u{207B}\u{00B9}")
        XCTAssertEqual(source.x?.scale ?? 0, 0.02, accuracy: 1e-15)
        XCTAssertEqual(source.y?.scale ?? 0, 0.04, accuracy: 1e-15)
        var uncalibrated = Self.header()
        uncalibrated.unitsX = "1/px"; uncalibrated.unitsY = "1/px"; uncalibrated.spacingX = 1.0 / 64; uncalibrated.spacingY = 1.0 / 64
        XCTAssertEqual(FFTExport.transformSource(uncalibrated).x?.unit, "px\u{207B}\u{00B9}")
    }

    /// 256 bins at 0.3125 nm⁻¹ per bin: 64 px aim = 20 nm⁻¹ exactly, drawn 64 px; the ladder leaves a reciprocal unit alone.
    /// Red under: the unit passed through `ladder` as a length, a bar measuring y.
    func testTheReciprocalScaleBarIsLabelledInNanometresInverseAndMeasured() throws {
        let axis = AxisCalibration(scale: 0.3125, unit: "nm\u{207B}\u{00B9}", origin: 0)
        let plan = try XCTUnwrap(ImageExport.scaleBarPlan(x: axis, y: AxisCalibration(scale: 0.5, unit: "nm\u{207B}\u{00B9}", origin: 0),
                                                           width: 256, height: 256))
        XCTAssertEqual(plan.label, "20 nm\u{207B}\u{00B9}")
        XCTAssertEqual(plan.drawnPixels, 64)
        XCTAssertEqual(plan.lengthPixels, 64, accuracy: 1e-12)
    }

    // MARK: Rendering

    private func source(_ w: Int, _ h: Int) -> ExportSource {
        ExportSource(software: Self.software, fileName: "t.dm4", object: "", width: w, height: h, x: nil, y: nil, notes: [])
    }

    private func display(_ w: Int, _ h: Int) -> ImageExport.Display {
        ImageExport.Display(normalized: [Float](repeating: 0, count: w * h), width: w, height: h, low: 0, high: 1, gamma: 1,
                            lut: (0..<1024).map { (i: Int) -> UInt8 in i % 4 == 3 ? 255 : UInt8(i / 4) }, colormap: "gray")
    }

    private func description(_ png: Data) throws -> [String: Any] {
        let bytes = [UInt8](png)
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let body = Array(bytes[(offset + 8)..<(offset + 8 + length)])
            if type == "tEXt" || type == "iTXt", let nul = body.firstIndex(of: 0), String(decoding: body[..<nul], as: UTF8.self) == "Description" {
                var i = nul + 1
                if type == "iTXt" {
                    i = nul + 3
                    while i < body.count, body[i] != 0 { i += 1 }
                    i += 1
                    while i < body.count, body[i] != 0 { i += 1 }
                    i += 1
                }
                return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body[i...])) as? [String: Any])
            }
            offset += 12 + length
        }
        throw XCTSkip("no Description chunk")
    }

    private func pixels(_ png: Data) throws -> (width: Int, height: Int, rgb: [UInt8]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for row in 0..<image.height { for col in 0..<image.width {
            for k in 0..<3 { rgb[3 * (row * image.width + col) + k] = data[row * context.bytesPerRow + 4 * col + k] }
        } }
        return (image.width, image.height, rgb)
    }

    /// The yellow-weighted centroid (pixel centres at +1/2), the pixels' extent and the Description's marks of a render of one spot
    /// on a black 128 x 128 plant.
    private func ring(at point: ImagePoint, label: String = "7") throws -> (x: Double, y: Double, width: Int, marks: [[String: Any]]) {
        let mark = ImageExport.Mark(kind: .spot, points: [point], width: 1, label: label)
        let rendered = try ImageExport.render(source: source(128, 128), display: display(128, 128), marks: [mark],
                                              options: ImageExport.Options(scaleBar: false, marks: true))
        let p = try pixels(rendered.png)
        var sw = 0.0, sx = 0.0, sy = 0.0, minX = 999, maxX = -1
        for row in 0..<p.height { for col in 0..<p.width {
            let r = Double(p.rgb[3 * (row * p.width + col)]), b = Double(p.rgb[3 * (row * p.width + col) + 2])
            guard r > 100, b < 0.5 * r else { continue }
            sw += r; sx += r * (Double(col) + 0.5); sy += r * (Double(row) + 0.5)
            minX = min(minX, col); maxX = max(maxX, col)
        } }
        XCTAssertGreaterThan(sw, 0, "a ring is drawn")
        return (sx / sw, sy / sw, maxX - minX, try XCTUnwrap(description(rendered.png)["marks"] as? [[String: Any]]))
    }

    /// A spot is one yellow ring centred on its centroid: on a black plant, the yellow-weighted centroid of the pixels is the
    /// point (x + ½, y + ½) — within 0.15 px for a spot on a pixel's centre (parity measures 0.002), within 0.3 for one a quarter
    /// pixel off it (the threshold on antialiased edge pixels biases it by 0.2, measured). Red under: the ring drawn at the
    /// corner (0.5 px off), a ring radius of 3.
    func testASpotMarkIsDrawnAsOneRingAtItsCentroid() throws {
        let aligned = try ring(at: ImagePoint(x: 60, y: 71))
        XCTAssertEqual(aligned.x, 60.5, accuracy: 0.15)
        XCTAssertEqual(aligned.y, 71.5, accuracy: 0.15)
        XCTAssertGreaterThan(aligned.width, 12, "radius 7 at u = 1: about 15 px across")
        let fractional = try ring(at: ImagePoint(x: 60.25, y: 71.5))
        XCTAssertEqual(fractional.x, 60.75, accuracy: 0.3)
        XCTAssertEqual(fractional.y, 72.0, accuracy: 0.15)
        XCTAssertEqual(fractional.marks.first?["kind"] as? String, "spot")
        XCTAssertEqual(fractional.marks.first?["label"] as? String, "7")
    }

    /// A spot with a non-finite coordinate or with two points is not drawn and is counted as skipped, as the other marks.
    func testASpotThatCannotBeDrawnIsSkippedAndCounted() throws {
        let bad = ImageExport.Mark(kind: .spot, points: [ImagePoint(x: .nan, y: 3)], width: 1, label: "1")
        let two = ImageExport.Mark(kind: .spot, points: [ImagePoint(x: 3, y: 3), ImagePoint(x: 4, y: 4)], width: 1, label: "2")
        let rendered = try ImageExport.render(source: source(64, 64), display: display(64, 64), marks: [bad, two],
                                              options: ImageExport.Options(scaleBar: false, marks: true))
        let d = try description(rendered.png)
        XCTAssertEqual((d["marks"] as? [Any])?.count, 0)
        XCTAssertEqual(d["marks_skipped"] as? Int, 2)
    }

    /// Without a provenance the Description is slice 1's (no "fft" key, the image export's two sentences); with one, the block
    /// is added and only validation and lineage change. Red under: the provenance applied when nil, validation not replaced,
    /// another key changed.
    func testProvenanceReplacesValidationAndLineageAndAddsTheFFTBlockOnly() throws {
        let plain = try ImageExport.render(source: source(64, 64), display: display(64, 64), marks: [],
                                           options: ImageExport.Options(scaleBar: true, marks: false))
        let explicitNil = try ImageExport.render(source: source(64, 64), display: display(64, 64), marks: [],
                                                 options: ImageExport.Options(scaleBar: true, marks: false), provenance: nil)
        XCTAssertEqual(plain.png, explicitNil.png, "nil changes nothing: the same bytes")
        let base = try description(plain.png)
        XCTAssertNil(base["fft"])
        XCTAssertTrue((base["validation"] as? String)?.hasPrefix("display rendering") == true)
        XCTAssertTrue((base["lineage"] as? String)?.contains("marks carry no lineage id") == true)

        let provenance = ImageExport.Provenance(fields: ["b": "2", "a": "1"], validation: "V", lineage: "L")
        let with = try ImageExport.render(source: source(64, 64), display: display(64, 64), marks: [],
                                          options: ImageExport.Options(scaleBar: true, marks: false), provenance: provenance)
        let d = try description(with.png)
        XCTAssertEqual(d["fft"] as? [String: String], ["a": "1", "b": "2"])
        XCTAssertEqual(d["validation"] as? String, "V")
        XCTAssertEqual(d["lineage"] as? String, "L")
        for key in base.keys where key != "validation" && key != "lineage" {
            XCTAssertEqual(d[key] as? NSObject, base[key] as? NSObject, key)
        }
        XCTAssertEqual(Set(d.keys), Set(base.keys).union(["fft"]))
        XCTAssertTrue(String(decoding: with.png, as: UTF8.self).contains("\"fft\":{\"a\":\"1\",\"b\":\"2\"}"), "sorted keys")
    }

    /// The transform's Description names the space, the steps, the unwindowed transform and the lineage.
    func testTheTransformProvenanceNamesTheSpaceTheStepsAndTheUnwindowedTransform() throws {
        let h = Self.header()
        let provenance = FFTExport.transformProvenance(h, spotsDrawn: 3)
        XCTAssertEqual(provenance.fields["space"], "reciprocal")
        XCTAssertEqual(provenance.fields["spots_drawn"], "3")
        XCTAssertEqual(provenance.fields["subject"], "region 64 x 64 px at (16, 0) (column, row of its top-left pixel)")
        XCTAssertEqual(provenance.fields["pane_aspect"], CSVText.number((64 * h.spacingX) / (64 * h.spacingY)))
        XCTAssertTrue(provenance.fields["transform"]?.contains("NO window") == true)
        XCTAssertTrue(provenance.fields["display"]?.contains("log10(|F|^2 / (W*H)^2)") == true)
        XCTAssertTrue(provenance.validation.contains("numpy 2.5.4"))
        XCTAssertTrue(provenance.lineage.hasPrefix("none"))
    }
}
