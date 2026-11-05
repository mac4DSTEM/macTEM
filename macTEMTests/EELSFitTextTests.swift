//
//  EELSFitTextTests.swift
//  The EELS fit's words on screen read cleanly: the fit quality as the EDS room writes it ("χ²/dof 1.42 · Pearson", its significant figures, the
//  locale's decimal mark), a results footer that fits the results column at its minimum width, a notes popover as tall as its text, and a status-line
//  readout that names the hovered map's value only, as the EDS room's. Display only: the CSV and the method JSON keep their exact text and values.
//
//  THE TRUTH: planted fit qualities (an exact fit's χ²/dof of 2.3e7 and the hand case of `EELSFitQualityTests`), planted tiles, and the planted
//  C K, N K, O K session of `EELSControlsTests` fitted by MLLS.
//

import XCTest
import AppKit
import SwiftUI
import ShellLayout
import ShellSpectroscopy
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSFitTextTests: XCTestCase {

    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    /// The drive's case: RSS 1.373e19 and χ²/dof 2.3e7 over 162 degrees of freedom. On screen the χ² is written "χ²/dof" (the subscript r drew as a
    /// comma in the caption font) with the EDS room's significant figures, in the locale's decimal mark. Red under: "χ²ᵣ 23000000 (Pearson, 162 dof)".
    func testTheFitQualityReadsAsTheEDSRoomsInEnglishAndGerman() {
        let big = EELSFitQuality(rss: 1.373e19, channels: 166, parameters: 4, reducedChiSquared: 2.3e7)
        XCTAssertEqual(EELSRoomFormat.fitQualityText(big, locale: en), "RSS 1.373e19 · χ²/dof 2.3e7 · Pearson, 162 dof")
        XCTAssertEqual(EELSRoomFormat.fitQualityText(big, locale: de), "RSS 1,373e19 · χ²/dof 2,3e7 · Pearson, 162 dof")
        XCTAssertEqual(EELSRoomFormat.fitQualitySummary(big, locale: en), "χ²/dof 2.3e7 · Pearson")
        XCTAssertEqual(EELSRoomFormat.fitQualitySummary(big, locale: de), "χ²/dof 2,3e7 · Pearson")
        // The EDS room's figures (SpectroKit's `qualityText`): two decimals under 10, one under 100, none from 100; scientific under 0.01.
        for (chi, enText, deText) in [(1.4236, "1.42", "1,42"), (54.83, "54.8", "54,8"), (123.4, "123", "123"), (1.0, "1.00", "1,00"),
                                        (0.00123, "1.23e-3", "1,23e-3"), (0, "0.00", "0,00")] {
            let q = EELSFitQuality(rss: 1234, channels: 316, parameters: 4, reducedChiSquared: chi)
            XCTAssertEqual(EELSRoomFormat.fitQualitySummary(q, locale: en), "χ²/dof \(enText) · Pearson")
            XCTAssertEqual(EELSRoomFormat.fitQualitySummary(q, locale: de), "χ²/dof \(deText) · Pearson")
            XCTAssertEqual(EELSRoomFormat.fitQualityText(q, locale: de), "RSS 1234 · χ²/dof \(deText) · Pearson, 312 dof")
        }
        // No χ²: the RSS and why, in full; the RSS alone in the footer.
        let deconvolved = EELSFitQuality(rss: 1.373e19, channels: 166, parameters: 4, reducedChiSquared: nil, chiSquaredUnavailable: EELSFitQuality.notCounts)
        XCTAssertEqual(EELSRoomFormat.fitQualityText(deconvolved, locale: en), "RSS 1.373e19 · " + EELSFitQuality.notCounts)
        XCTAssertEqual(EELSRoomFormat.fitQualitySummary(deconvolved, locale: en), "RSS 1.373e19")
        for text in [EELSRoomFormat.fitQualityText(big, locale: de), EELSRoomFormat.fitQualitySummary(big, locale: de)] {
            XCTAssertFalse(text.contains("\u{1D63}"), "no subscript r on screen: \(text)")
        }
    }

    /// The exports keep their own text: the results CSV's quality line is the export formatter's (POSIX, "χ²ᵣ", the full digits), never the screen's, and
    /// the method JSON's fit quality holds the kit's numbers. Red under: the screen's wording or rounding reaching an export.
    @MainActor func testTheExportsKeepTheirExactText() async throws {
        let session = try await EELSFitNotesTests.fittedSession(.mlls)
        let q = try XCTUnwrap(session.resultQuality)
        let csv = try XCTUnwrap(session.resultsCSV)
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertTrue(csv.contains(EELSRoomFormat.fitQuality(q, locale: posix)), csv)
        XCTAssertFalse(csv.contains(EELSRoomFormat.fitQualityText(q, locale: posix)), "the screen's wording stays off the CSV")
        XCTAssertFalse(csv.contains("χ²/dof"), csv)
        let regionQuality = try XCTUnwrap(session.regionQuality)
        let json = try XCTUnwrap(session.fitParameters?["fit_quality"] as? [String: Any])
        XCTAssertEqual(json["rss"] as? Double, regionQuality.rss)
        XCTAssertEqual(json["chi2_reduced_pearson"] as? Double, regionQuality.reducedChiSquared)
        XCTAssertEqual(json["degrees_of_freedom"] as? Int, regionQuality.degreesOfFreedom)
    }

    /// The footer line, measured in the caption font, fits the results column at its minimum width (padding and chevron taken off), with many notes, a
    /// huge χ² and the German decimal mark. Red under: the full "RSS … · χ²ᵣ … (Pearson, n dof)" in the footer ("(Pearson, 162…" on the drive).
    @MainActor func testTheFooterFitsTheResultsColumnAtItsMinimumWidth() {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let room = EDXLayout.resultsWidth.min - 2 * LayoutPolicy.infobarHorizontalPadding - 6 - width("⌃") - 4
        let cases = [EELSFitQuality(rss: 1.373e19, channels: 166, parameters: 4, reducedChiSquared: 2.3e7),
                     EELSFitQuality(rss: -1.234e-19, channels: 166, parameters: 4, reducedChiSquared: 123.4),
                     EELSFitQuality(rss: 1.373e19, channels: 166, parameters: 4, reducedChiSquared: nil, chiSquaredUnavailable: EELSFitQuality.notCounts)]
        for q in cases {
            for locale in [en, de] {
                let line = EELSRoomFormat.fitNotesSummary(notes: 12, quality: EELSRoomFormat.fitQualitySummary(q, locale: locale))
                XCTAssertLessThanOrEqual(width(line), room, "\(line) is \(width(line)) pt in \(room) pt")
            }
        }
    }

    /// The popover is as tall as its text, up to the EDS popover's 280 pt, and scrolls beyond. Red under: a fixed 280 pt for three lines of text.
    @MainActor func testThePopoverHeightFollowsItsContent() throws {
        func height(_ notes: [String]) -> CGFloat {
            let host = NSHostingView(rootView: EELSFitNotesList(notes: notes, quality: "RSS 1.373e19 · χ²/dof 2.3e7 · Pearson, 162 dof",
                                                                method: "exact NNLS · power-law background · no deconvolution", methodNames: ["EELS edge model"]))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let short = height(["N not detected (MLLS amount ≤ 0)"])
        let longer = height(["N not detected (MLLS amount ≤ 0)", "O K below detection: I is at or under 3σ, the edge is not detected in this region"])
        let many = height((1...40).map { "Note \($0): an edge that says something about its own number at some length" })
        XCTAssertGreaterThan(short, 40)
        XCTAssertLessThan(short, EELSFitNotesList.maximumHeight - 60, "a few lines leave no empty half")
        XCTAssertGreaterThan(longer, short, "the height follows the text")
        XCTAssertEqual(many, EELSFitNotesList.maximumHeight, accuracy: 0.5, "a long list stops at the maximum and scrolls")
        XCTAssertEqual(EELSFitNotesList.maximumHeight, 280)
        try Self.save(EELSFitNotesList(notes: ["N not detected (MLLS amount ≤ 0)"], quality: "RSS 1.373e19 · χ²/dof 2.3e7 · Pearson, 162 dof",
                                       method: "exact NNLS · power-law background · convolved with the low loss · no deconvolution",
                                       methodNames: ["EELS edge model: power law + dft GOS edges, non-negative least squares"]),
                      name: "macTEM-fittext-popover.png")
    }

    /// The status line over one map names the pixel and that map's value, as the EDS room's (never every map at once, which ran past the line); the mix
    /// names its members'. Any map can be read, the edge maps too. Display formatting: scientific outside 0.01–100 000. Red under: no `tileReadout`.
    func testTheReadoutNamesTheHoveredMapOnly() {
        func tile(_ id: String, _ title: String, _ unit: String, _ values: [Double]) -> EELSMapTile {
            EELSMapTile(id: id, title: title, unit: unit, width: 2, height: 1, values: values, version: 1, footer: nil)
        }
        let t = tile("tOverLambda", "t/λ", "", [1.104, .nan])
        let total = tile("iTotal", "I total", "counts", [7_113_000, 1])
        let c = tile("edge-C-K", "C K", "nm⁻²", [12.5, 3]), o = tile("at-O", "O", "at%", [3.77, 1])
        XCTAssertEqual(EELSRoomFormat.tileReadout(x: 0, y: 0, tiles: [t], refusal: nil, locale: en), "row 0 · col 0 · t/λ 1.104")
        XCTAssertEqual(EELSRoomFormat.tileReadout(x: 0, y: 0, tiles: [total], refusal: nil, locale: de), "row 0 · col 0 · I total 7,113e6 counts")
        XCTAssertEqual(EELSRoomFormat.tileReadout(x: 1, y: 0, tiles: [t], refusal: "I_0 <= 0", locale: en), "row 0 · col 1 · t/λ: I_0 <= 0")
        XCTAssertEqual(EELSRoomFormat.tileReadout(x: 0, y: 0, tiles: [c], refusal: "I_0 <= 0", locale: en), "row 0 · col 0 · C K 12.5 nm⁻²",
                       "the thickness refusal belongs to the thickness maps")
        XCTAssertEqual(EELSRoomFormat.tileReadout(x: 0, y: 0, tiles: [c, o], refusal: nil, unanswered: "no peak", locale: de),
                       "row 0 · col 0 · deconvolution: no answer, no peak · C K 12,5 nm⁻² · O 3,77 at%")
        XCTAssertEqual(EELSRoomFormat.tileReadout(x: 5, y: 5, tiles: [c], refusal: nil, locale: en), "row 5 · col 5", "off the grid: no values")
    }

    /// The results panel at the room's minimum results width, after an MLLS fit: the footer reads in full. The picture goes to the shots folder.
    @MainActor func testThePanelDrawsAtItsMinimumWidth() async throws {
        let session = try await EELSFitNotesTests.fittedSession(.mlls)
        try Self.save(EELSResultsPanel(session: session), name: "macTEM-fittext-footer.png", size: NSSize(width: EDXLayout.resultsWidth.min, height: 300))
    }

    /// Draws `view` offscreen (a borderless window never shown) and writes it to ~/GitHub/.worktrees/shots when that folder exists.
    @MainActor static func save(_ view: some View, name: String, size: NSSize? = nil) throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let frame = size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: frame), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: frame)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("GitHub/.worktrees/shots")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(name))
    }
}
