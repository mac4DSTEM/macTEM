// The FFT room's call sites that the pure tests cannot reach: the View menu read from its owner (C13), the radial chart's
// decade labels (C8) and the two spoken units (C14). Each fix of the 2026-10-14 review was right in its pure function while
// reverting the one line that used it left every test green; these go red when that line reverts.
import ShellControls
import ShellInspector
import XCTest
import SwiftUI
import AppKit
import TEMCore
import TEMSession
import ImagoFFT
@testable import macTEM

nonisolated final class FFTRoomWiringTests: XCTestCase {

    // MARK: Fixtures

    /// An owner whose lanes answer at once: the spectrum and the products are stand-ins, a spot is the registered estimator's
    /// answer on `FFTAnalysisTests.plant`'s region A.
    @MainActor private func owner() -> FFTAnalysis {
        FFTAnalysis(compute: FFTCompute(
            spectrum: { _, key in FFTAnalysisTests.fakeSpectrum(key) },
            spot: { _, _, row, col in
                (try? FFTAnalysisTests.measured(row: row, col: col)).map { .measured($0) } ?? .measuring
            },
            maskedInverse: { _, key in FFTMaskedInverseProduct(key: key, canvas: FFTAnalysisTests.fakeCanvas(), imaginaryMax: 0) },
            filter: { _, key in
                FFTFilterProduct(key: key, absf: FFTAnalysisTests.fakeCanvas(), wiener: FFTAnalysisTests.fakeCanvas(), n: 64,
                                 passes: 3, finalDelta: 4.5)
            }))
    }

    /// An owner whose spot lane answers (31, 33) with a refusal and (29, 44) with no peak, and any other click with a measurement.
    @MainActor private func ownerRefusingSomeSpots() -> FFTAnalysis {
        FFTAnalysis(compute: FFTCompute(
            spectrum: { _, key in FFTAnalysisTests.fakeSpectrum(key) },
            spot: { _, _, row, col in
                if row == 31 && col == 33 { return .refused(.nearDC) }
                if row == 29 && col == 44 { return .refused(.noPower) }
                return (try? FFTAnalysisTests.measured(row: row, col: col)).map { .measured($0) } ?? .measuring
            },
            maskedInverse: { _, key in FFTMaskedInverseProduct(key: key, canvas: FFTAnalysisTests.fakeCanvas(), imaginaryMax: 0) },
            filter: { _, key in
                FFTFilterProduct(key: key, absf: FFTAnalysisTests.fakeCanvas(), wiener: FFTAnalysisTests.fakeCanvas(), n: 64,
                                 passes: 3, finalDelta: 4.5)
            }))
    }

    @MainActor private func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
        throw FFTAnalysisTests.TimedOut()
    }

    /// The owner with its spectrum shown for region A and one spot measured on it (In Mask, as a new spot is).
    @MainActor private func ownerWithASpot() async throws -> (FFTAnalysis, FFTSpot.ID) {
        let analysis = owner()
        analysis.setRegion(FFTAnalysisTests.regionA, committed: true)
        analysis.show(FFTAnalysisTests.plant(), contentVersion: 1)
        try await until("the spectrum") { analysis.isSpectrumCurrent }
        analysis.measureSpot(row: 37, col: 40)
        try await until("the spot") { analysis.hasMeasuredSpot }
        return (analysis, try XCTUnwrap(analysis.spots.last).id)
    }

    /// The repo's own source file at `path`, read beside this test file.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of the declaration that begins with `start`, up to the first line that closes it at the top level.
    private func declaration(_ start: String, in text: String) throws -> String {
        let begin = try XCTUnwrap(text.range(of: start), "\(start) is not in the file")
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: begin.upperBound..<text.endIndex), "\(start) is not closed")
        return String(text[begin.lowerBound..<end.upperBound])
    }

    /// `text` with every run of white space one space, so a check reads code, not its layout.
    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: C13 — the View menu, item by item, read from its owner

    /// The menu the control draws is the owner's state, item by item: each view's title — its reason in brackets when it
    /// cannot be chosen, except the view the pane shows, which keeps its plain name — and whether it can be chosen. The
    /// finding's state is the one that matters: a measured spot taken out of the mask leaves the Masked Inverse "none in
    /// mask" and disabled, not "no spot", and not enabled. Red under (the review's mutants): the selected view carrying its
    /// reason (Mb4); `hasMaskSpot` passed for `hasMeasuredSpot` (Mb5); `hasMeasuredSpot` passed for `hasMaskSpot` (Mb8); a
    /// view enabled with a reason, or disabled without one; and, for the refused and peakless spots (they are In Mask by
    /// default but have no centroid), `entries(for:)` reading "any spot" (`!spots.isEmpty`, E-meas-nonempty) or "any spot In
    /// Mask" (E-mask-inmask) for the owner's flags.
    @MainActor func testTheViewMenuIsTheOwnersStateItemByItem() async throws {
        typealias Entry = FFTPaneFormat.MenuEntry
        let fresh = owner()
        XCTAssertEqual(FFTSourceViewControl.entries(for: fresh), [
            Entry(view: .original, title: "Original", isEnabled: true),
            Entry(view: .region, title: "Region (no transform yet)", isEnabled: false),
            Entry(view: .maskedInverse, title: "Masked Inverse (no spot)", isEnabled: false),
            Entry(view: .absf, title: "ABSF (filter first)", isEnabled: false),
            Entry(view: .wiener, title: "Wiener (filter first)", isEnabled: false),
        ], "nothing transformed")

        let refusing = ownerRefusingSomeSpots()
        refusing.setRegion(FFTAnalysisTests.regionA, committed: true)
        refusing.show(FFTAnalysisTests.plant(), contentVersion: 1)
        try await until("the spectrum") { refusing.isSpectrumCurrent }
        refusing.measureSpot(row: 31, col: 33)
        refusing.measureSpot(row: 29, col: 44)
        try await until("both answers") {
            refusing.spots.count == 2 && refusing.spots.allSatisfy { if case .measuring = $0.outcome { false } else { true } }
        }
        XCTAssertFalse(refusing.hasMeasuredSpot, "a refused and a peakless spot have no centroid")
        XCTAssertEqual(FFTSourceViewControl.entries(for: refusing)[2],
                       Entry(view: .maskedInverse, title: "Masked Inverse (no spot)", isEnabled: false),
                       "only a refused and a peakless spot: no spot is measured, not 'none in mask'")

        let (analysis, spot) = try await ownerWithASpot()
        XCTAssertEqual(FFTSourceViewControl.entries(for: analysis), [
            Entry(view: .original, title: "Original", isEnabled: true),
            Entry(view: .region, title: "Region", isEnabled: true),
            Entry(view: .maskedInverse, title: "Masked Inverse", isEnabled: true),
            Entry(view: .absf, title: "ABSF (filter first)", isEnabled: false),
            Entry(view: .wiener, title: "Wiener (filter first)", isEnabled: false),
        ], "a spot in the mask")

        analysis.setInMask(spot, false)
        XCTAssertTrue(analysis.hasMeasuredSpot)
        XCTAssertFalse(analysis.hasMaskSpot)
        XCTAssertEqual(FFTSourceViewControl.entries(for: analysis)[2],
                       Entry(view: .maskedInverse, title: "Masked Inverse (none in mask)", isEnabled: false),
                       "the finding's state: measured, taken out of the mask")

        analysis.setSourceView(.maskedInverse)
        XCTAssertEqual(analysis.sourceView, .maskedInverse)
        XCTAssertEqual(FFTSourceViewControl.entries(for: analysis)[2],
                       Entry(view: .maskedInverse, title: "Masked Inverse", isEnabled: false),
                       "the view shown is the face: its plain name, the pane says why")

        analysis.setSourceView(.original)
        analysis.runFilter()
        try await until("the filter") { analysis.filtered != nil }
        let filtered = FFTSourceViewControl.entries(for: analysis)
        XCTAssertEqual(filtered.map(\.view), FFTAnalysis.SourceView.allCases)
        XCTAssertEqual(filtered[3], Entry(view: .absf, title: "ABSF", isEnabled: true))
        XCTAssertEqual(filtered[4], Entry(view: .wiener, title: "Wiener", isEnabled: true))
        for entry in filtered where entry.view != analysis.sourceView {
            XCTAssertEqual(entry.isEnabled, !entry.title.contains("("), "\(entry.title): a reason exactly when disabled")
        }
    }

    /// The real control, hosted, shows the plain name of the view the pane shows on its face, within the narrowest header's
    /// budget, in each state where that view has a reason (a filter's view never does: the owner leaves it when its result
    /// goes); and its items are the entries, each disabled as its entry says.
    /// (A hosted menu has no items until it opens, and the host no accessibility tree, so the items' wiring is read from the
    /// source; the drive reads the menu itself.) Red under: the control drawing its own titles; the face carrying a reason.
    @MainActor func testTheViewMenusFaceIsThePlainNameOfTheViewShown() async throws {
        func face(_ analysis: FFTAnalysis) throws -> (title: String, width: Double) {
            let host = NSHostingView(rootView: FFTSourceViewControl(analysis: analysis))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            func popUp(in view: NSView) -> NSPopUpButton? {
                (view as? NSPopUpButton) ?? view.subviews.lazy.compactMap { popUp(in: $0) }.first
            }
            let button = try XCTUnwrap(popUp(in: host), "the control draws a pop-up button")
            return (button.title, Double(host.fittingSize.width))
        }
        let fresh = owner()
        fresh.setSourceView(.maskedInverse)
        XCTAssertEqual(try face(fresh).title, "Masked Inverse", "selected with no spot")
        XCTAssertLessThanOrEqual(try face(fresh).width, FFTPaneFormat.maximumFaceWidth)
        fresh.setSourceView(.region)
        XCTAssertEqual(try face(fresh).title, "Region", "selected with no transform")

        let (analysis, spot) = try await ownerWithASpot()
        analysis.setInMask(spot, false)
        analysis.setSourceView(.maskedInverse)
        let shown = try face(analysis)
        XCTAssertEqual(shown.title, "Masked Inverse", "the finding's state, selected")
        XCTAssertLessThanOrEqual(shown.width, FFTPaneFormat.maximumFaceWidth, "\(shown.width) pt")
        analysis.setSourceView(.original)
        XCTAssertEqual(try face(analysis).title, "Original")

        let control = squeezed(try declaration("struct FFTSourceViewControl: View {", in: source("macTEM/UI/FFTSourceImagePane.swift")))
        XCTAssertTrue(control.contains("ForEach(Self.entries(for: analysis), id: \\.view) { entry in"), "the items are the entries")
        XCTAssertTrue(control.contains("Text(entry.title).tag(entry.view).disabled(!entry.isEnabled)"),
                      "each item shows its entry's title and is disabled exactly when its entry is")
    }

    /// The words under a view whose product is not there yet are the owner's state, read by the pane's own call: the Masked
    /// Inverse waits by cause — nothing measured (a refused or peakless spot counts for nothing), measured spots none In
    /// Mask, a spot In Mask — and the pane's `missing(_:)` is the one `missingWords(for:view:)` the test reads. Red under
    /// (the review's mutants): the pane passing `hasMaskSpot` for `hasMeasuredSpot` (M-pane-mask), the reverse (M-pane-meas),
    /// or a constant (M-pane-false); `missingWords` reading "any spot" for `hasMeasuredSpot` (E-meas-nonempty); the pane
    /// calling `FFTPaneFormat.missing` itself, not `missingWords` (M-pane-bypass).
    @MainActor func testThePanesMissingWordsAreTheOwnersState() async throws {
        func words(_ analysis: FFTAnalysis) -> String {
            let w = FFTSourceImagePane.missingWords(for: analysis, view: .maskedInverse)
            return "\(w.title) | \(w.detail)"
        }
        let none = "No masked inverse yet | Click a spot in the transform, then keep it in the mask."
        XCTAssertEqual(words(owner()), none, "nothing measured")

        let refusing = ownerRefusingSomeSpots()
        refusing.setRegion(FFTAnalysisTests.regionA, committed: true)
        refusing.show(FFTAnalysisTests.plant(), contentVersion: 1)
        try await until("the spectrum") { refusing.isSpectrumCurrent }
        refusing.measureSpot(row: 31, col: 33)
        refusing.measureSpot(row: 29, col: 44)
        try await until("both answers") {
            refusing.spots.count == 2 && refusing.spots.allSatisfy { if case .measuring = $0.outcome { false } else { true } }
        }
        XCTAssertEqual(words(refusing), none, "only a refused and a peakless spot: still nothing measured")

        let (analysis, spot) = try await ownerWithASpot()
        XCTAssertEqual(words(analysis), "Computing the masked inverse… | ", "a measured spot In Mask")
        analysis.setInMask(spot, false)
        XCTAssertEqual(words(analysis), "No masked inverse yet | Tick a spot's checkbox in the Spots section to put it in the mask.",
                       "measured, none In Mask: the words name the checkbox the Spots section draws")
        XCTAssertEqual(FFTSourceImagePane.missingWords(for: analysis, view: .absf).title, "No filtered image yet")

        let pane = squeezed(try source("macTEM/UI/FFTSourceImagePane.swift"))
        XCTAssertTrue(pane.contains("let words = Self.missingWords(for: analysis, view: view)"), "the pane draws the words the test reads")
        XCTAssertFalse(pane.replacingOccurrences(of: "return FFTPaneFormat.missing(view, isWorking: working,", with: "")
            .contains("FFTPaneFormat.missing("), "and calls FFTPaneFormat.missing nowhere else")
    }

    // MARK: C8 — the radial chart's decade labels

    /// The chart labels only the decades `FFTRoomFormat.powerAxisMarks` chooses: rendered for spans of 2 to 14 decades, it
    /// draws one horizontal grid line per chosen decade, at least `minimumLabelSpacing` apart, and ONE label per line in the
    /// strip right of the plot, centred on its line and no taller than a number — where Charts' own marks put a line and a
    /// label on every decade (10 over nine decades, their labels overprinted). A grid line is a pixel row of the plot inked
    /// across nine tenths of it (the plot is the chart's left four fifths); the strip starts where the first line, tick
    /// included, ends; a label is a run of inked rows in the strip from just above the plot's top to its bottom, the plot's
    /// rows read from the x axis's dashed grid lines.
    /// Red under (the review's mutants): the y axis's marks left to Charts (X01/M8d, the finding's defect; also X02-X05, X22);
    /// grid lines at the chosen decades with a label on every decade (X06); the labels removed (X07); labels in a 30 pt font
    /// (X09); a mark beyond the chosen ones (X12). Not caught, judged benign: a label drawn twice on itself (X10: the label's
    /// ink is darker, its place and size are the same).
    /// Known flake, Gate D 2026-10-14: rendering the real chart in a fresh process traps in Charts ("Duplicate keys of type
    /// 'HashableText'") in about 0.3 to 1 % of processes, because `FFTRadialChart` gives `.value(…)` an interpolated
    /// LocalizedStringKey as its x title; a String there takes another overload and traps in none of 2400 processes. Land this
    /// test with that change, not before.
    @MainActor func testTheRadialChartDrawsALineAndALabelOnlyAtTheChosenDecades() throws {
        let scale = 2.0
        for (lowest, highest) in [(1.5e4, 8e5), (1.5e4, 8e10), (1.5e3, 8e11), (1.5e3, 8e14), (3e-4, 9e2), (2e2, 3e15)] {
            let samples = (0..<40).map { i in
                FFTRoomFormat.ChartSample(bin: i + 1, q: 0.05 * Double(i + 1), mean: lowest * pow(highest / lowest, Double(i) / 39),
                                          count: 8)
            }
            let marks = FFTRoomFormat.powerAxisMarks(samples)
            let content = FFTRadialChart(samples: samples, label: "nm\u{207B}\u{00B9}", binWidth: 0.05)
                .frame(width: 300).background(Color.white).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            let image = try XCTUnwrap(renderer.cgImage, "the chart renders")
            let raster = try XCTUnwrap(Raster(image), "the render has pixels")
            let lines = raster.gridLines(plotFraction: 0.8)
            let span = "\(lowest) … \(highest)"
            XCTAssertEqual(lines.count, marks.count, "\(span): one line per chosen decade \(marks), lines at \(lines) px")
            for (a, b) in zip(lines, lines.dropFirst()) {
                XCTAssertGreaterThanOrEqual((b - a) / scale, FFTRoomFormat.minimumLabelSpacing, "\(span): lines at \(lines) px")
            }
            guard let strip = raster.labelRuns(lines: lines) else {
                XCTFail("\(span): no plot or label strip found, lines at \(lines) px")
                continue
            }
            XCTAssertEqual(strip.count, marks.count, "\(span): one label per chosen decade, labels at \(strip) px")
            for (run, line) in zip(strip, lines) {
                XCTAssertLessThanOrEqual(abs(run.centre - line), Self.labelCentringTolerance * scale,
                                         "\(span): the label \(run) is centred on its line at \(line) px")
                XCTAssertLessThanOrEqual(run.height, Self.labelHeightCap * scale, "\(span): a label is as tall as a number: \(run)")
            }
        }
    }

    /// How far a label's centre may be from its grid line, in points: measured 0.25 pt at most on the unmutated chart (eight spans).
    static let labelCentringTolerance = 1.5
    /// The tallest a label may be, in points: a caption-size number with its superscript stays under it; two labels merged
    /// by overprinting, or a 30-pt font, do not.
    static let labelHeightCap = 12.0

    /// An image's pixels, white where it is transparent, with the two detectors the chart test reads them by.
    struct Raster {
        let width: Int, height: Int
        private let rgba: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            self.rgba = rgba
        }

        /// Whether the pixel is lighter than `cut` in no channel: ink (the grid is pale, a label dark).
        func isInked(row: Int, column: Int, cut: UInt8 = 250) -> Bool {
            let i = (row * width + column) * 4
            return min(rgba[i], rgba[i + 1], rgba[i + 2]) < cut
        }

        /// The rows (pixel centres, top down) where a horizontal line crosses the left `plotFraction` of the image: runs of
        /// rows at least nine tenths of whose pixels there are not white, each run one line.
        func gridLines(plotFraction: Double) -> [Double] {
            let columns = Int(Double(width) * plotFraction)
            var runs: [Double] = []
            var runStart: Int?
            for row in 0...height {
                var inked = 0
                if row < height { for column in 0..<columns where isInked(row: row, column: column) { inked += 1 } }
                let isLine = row < height && Double(inked) >= 0.9 * Double(columns)
                if isLine, runStart == nil { runStart = row }
                if !isLine, let start = runStart {
                    runs.append(Double(start + row - 1) / 2)
                    runStart = nil
                }
            }
            return runs
        }

        /// The labels of the y axis: runs of inked rows (darker than a grid line) right of the first line's end — the pale run
        /// from the middle of the plot to the right, its tick included — from just above the plot's top to its bottom, the plot's
        /// rows being those of the dashed x grid lines (columns left of that edge inked on a third of the rows between the first
        /// and last line, followed up and down across the dashes' gaps). Each run as its centre and height in pixels, top
        /// down; nil when there are fewer than two lines, no line reaches the middle, or no x grid line is found.
        func labelRuns(lines: [Double]) -> [(centre: Double, height: Double)]? {
            guard let first = lines.first, let last = lines.last, first < last else { return nil }
            let row = Int(first)
            var edge = width / 2
            guard isInked(row: row, column: edge) else { return nil }
            while edge + 1 < width, isInked(row: row, column: edge + 1) { edge += 1 }
            let from = Int(first), to = Int(last)
            let gap = 12   // pixels: wider than a dash's gap, narrower than the space to the x axis's numbers
            var top = Int.max, bottom = Int.min
            for column in 0..<edge {
                var inked = 0
                for r in from...to where isInked(row: r, column: column, cut: 254) { inked += 1 }
                guard Double(inked) >= (1.0 / 3.0) * Double(to - from + 1) else { continue }
                var up = from, down = to
                var blank = 0
                for r in stride(from: from, through: 0, by: -1) {
                    if isInked(row: r, column: column, cut: 254) { up = r; blank = 0 } else { blank += 1; if blank > gap { break } }
                }
                blank = 0
                for r in to..<height {
                    if isInked(row: r, column: column, cut: 254) { down = r; blank = 0 } else { blank += 1; if blank > gap { break } }
                }
                top = min(top, up)
                bottom = max(bottom, down)
            }
            guard top <= from, bottom >= to else { return nil }
            let windowTop = max(0, top - 8)
            var runs: [(centre: Double, height: Double)] = []
            var start: Int?
            for r in windowTop..<bottom {
                var on = false
                for column in (edge + 1)..<width where isInked(row: r, column: column, cut: 200) { on = true; break }
                if on, start == nil { start = r }
                if !on, let s = start { runs.append((Double(s + r - 1) / 2, Double(r - s))); start = nil }
            }
            if let s = start { runs.append((Double(s + bottom - 1) / 2, Double(bottom - s))) }
            return runs
        }
    }

    // MARK: C14 — the spoken units at their call sites

    /// Each Region field is titled with its spoken title ("Left in pixels") and nothing else speaks for it, so the kit's field
    /// names the unit once, in words; the row beside it shows the plain title and the field shows its unit "px"; and the
    /// inspector draws the Region fields through this row alone. (A hosted SwiftUI field exposes no accessibility tree to
    /// read, so the row's source is read; the drive hears it.) Red under (the review's mutants): the field titled with the
    /// row's title — "Left, px", the finding's defect (W1, Z3); the inspector drawing its own field and leaving the row unused
    /// (X1); an `accessibilityLabel` over the spoken title (X2, X5); the row combined into one element (X4); the field's
    /// unit changed (X3).
    func testTheRegionFieldsAreTitledWithTheirSpokenTitles() throws {
        let inspector = try source("macTEM/UI/FFTRoomInspector.swift")
        let declared = try declaration("private struct FFTRegionFieldRow: View {", in: inspector)
        let row = squeezed(declared)
        XCTAssertTrue(row.contains("OptionalNumericField(title: field.spokenTitle,"), "the field speaks the spoken title")
        XCTAssertFalse(row.contains("OptionalNumericField(title: field.title"), "not the row's title")
        XCTAssertTrue(row.contains("InspectorRow(field.title)"), "the row shows the plain title")
        XCTAssertTrue(row.contains("unit: \"px\""), "the field shows its unit, px")
        XCTAssertEqual(row.components(separatedBy: ".accessibility").count - 1, 1, "only the identifier modifies the field: \(row)")
        XCTAssertTrue(row.contains(".accessibilityIdentifier(field.identifier)"))
        let rest = squeezed(inspector.replacingOccurrences(of: declared, with: ""))
        XCTAssertTrue(rest.contains("FFTRegionFieldRow(field: field, value: region.map(field.value(of:)))"),
                      "the inspector draws the Region fields through the row")
        XCTAssertFalse(rest.contains("OptionalNumericField(title: field.title"), "and through no field of its own")
    }

    /// The transform's footer draws `FFTSpectrumBar`, whose body is the spoken bar — `FFTSpectrumLayout.spokenBar` ("Scale
    /// bar, 20 per nanometre") as its one accessibility label over the bar's children ignored — and the shared `ScaleBar`
    /// appears nowhere else in the pane; nothing after the footer hides or relabels it. Red under (the review's mutants): the
    /// footer back to a bare `ScaleBar` ("20 nm⁻¹", the finding's defect: W2, W3, Z1, Z2, Y4, Y6); the bar's body the bare
    /// bar with the spoken one unused (Y1); a second label over the spoken one (Y2, Y5); the footer hidden from
    /// accessibility (Y3).
    func testTheTransformsFooterDrawsTheBarThatSpeaksItsUnit() throws {
        let pane = try source("macTEM/UI/FFTSpectrumImagePane.swift")
        let declared = try declaration("struct FFTSpectrumBar: View {", in: pane)
        let bar = squeezed(declared)
        XCTAssertTrue(bar.contains("var body: some View { if let spoken = FFTSpectrumLayout.spokenBar(unitsPerPoint: unitsPerPoint, label: label) {"),
                      "the bar's body is the spoken bar")
        XCTAssertTrue(bar.contains(".accessibilityElement(children: .ignore) .accessibilityLabel(spoken) } else {"))
        XCTAssertEqual(bar.components(separatedBy: ".accessibility").count - 1, 2, "one element, one label, nothing over them: \(bar)")
        let rest = squeezed(pane.replacingOccurrences(of: declared, with: ""))
        XCTAssertTrue(rest.contains("PaneFooter { FFTSpectrumBar(unitsPerPoint: bar.unitsPerPoint, label: bar.label) }"),
                      "the footer's bar is the spoken one")
        XCTAssertTrue(rest.contains("trailing: { FFTRefusalNote(analysis: analysis) } } .frame(width: box.width, height: box.height)"),
                      "nothing modifies the footer after it")
        XCTAssertFalse(rest.contains("ScaleBar("), "no bare ScaleBar elsewhere in the pane")
    }

    /// Gate D (fft-chart-trap-gate-d-2026-10-14.md): an interpolated string literal given to a Charts `.value(…)` takes the
    /// LocalizedStringKey overload and traps Charts' layout in ~1 % of fresh processes ("Duplicate keys of type 'HashableText'").
    /// A title with `\(…)` goes through a String variable. Probabilistic, so pinned at the source, not by rendering.
    func testNoChartsValueTitleIsAnInterpolatedLiteral() throws {
        let ui = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("macTEM/UI")
        let files = try FileManager.default.contentsOfDirectory(at: ui, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"\.value\(\s*"[^"\n]*\\\("#)
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("import Charts") else { continue }
            checked += 1
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            let hits = pattern.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
            XCTAssertEqual(hits, 0, "\(file.lastPathComponent): .value(\"…\\(…)…\") in Charts code; use a String variable")
        }
        XCTAssertGreaterThanOrEqual(checked, 2, "the pin found no Charts files: it checks nothing")
    }

    // MARK: The Settings tab's order (the Export placement fix, 2026-10-15)

    /// Export is the last section of the Settings tab (control placement standard): plain buttons at the end of the column.
    /// Red under: Export back after Calibration or anywhere but last.
    func testExportSitsLast() {
        for measured in [false, true] {
            let order = FFTRoomSections.order(hasMeasuredSpot: measured)
            XCTAssertEqual(order.first, .calibration, "Calibration stays first (measured: \(measured))")
            XCTAssertEqual(order.last, .export, "Export is the last section (measured: \(measured)): \(order)")
        }
    }

    /// Every section once, and Masked Inverse only with a measured spot. Red under: a section dropped, listed twice, or Masked
    /// Inverse shown without a spot.
    func testOrderListsEverySectionOnce() {
        let withSpot = FFTRoomSections.order(hasMeasuredSpot: true)
        XCTAssertEqual(withSpot.count, FFTRoomSections.Section.allCases.count)
        XCTAssertEqual(Set(withSpot), Set(FFTRoomSections.Section.allCases))
        let without = FFTRoomSections.order(hasMeasuredSpot: false)
        XCTAssertEqual(Set(without), Set(FFTRoomSections.Section.allCases).subtracting([.maskedInverse]))
        XCTAssertEqual(without.count, withSpot.count - 1)
        XCTAssertEqual(withSpot.last, .export)
        XCTAssertEqual(withSpot[1], .display, "Display is second (control placement §2)")
        XCTAssertLessThan(try XCTUnwrap(withSpot.firstIndex(of: .spots)), try XCTUnwrap(withSpot.firstIndex(of: .maskedInverse)))
    }

    /// The tab draws the list (`FFTRoomSections.order`, asked with the owner's own `hasMeasuredSpot`), not a hand-written one; each
    /// section is drawn by its own view, the full line; and the Export pull-down row is gone. Red under: a fixed run of
    /// sections, a constant for the predicate, two views swapped, a section drawn by the wrong view.
    func testTheSettingsTabDrawsTheOrderAndHasNoExportSection() throws {
        let squeezed = try Self.squeezedUI("FFTRoomInspector.swift")
        XCTAssertTrue(squeezed.contains("FFTRoomSections.order(hasMeasuredSpot: analysis.hasMeasuredSpot)"), "the tab asks for the order with the real predicate")
        XCTAssertTrue(squeezed.contains("ForEach(sections, id: \\.self)"), "and iterates it")
        XCTAssertFalse(squeezed.contains("FFTExportRow"), "the pull-down row is gone")
        XCTAssertFalse(squeezed.contains("InspectorAdaptiveMenu"), "no pull-down of actions in the inspector")
        let views: [FFTRoomSections.Section: String] = [
            .calibration: "ImageRoomCalibrationSection(image: image)",
            .export: "FFTExportSection(analysis: analysis)",
            .region: "FFTRegionSection(image: image, analysis: analysis)",
            .spots: "FFTSpotsSection(image: image, analysis: analysis)",
            .radialProfile: "FFTRadialProfileSection(image: image, analysis: analysis)",
            .maskedInverse: "FFTMaskSection(analysis: analysis)",
            .filters: "FFTFiltersSection(image: image, analysis: analysis)",
            .display: "FFTDisplaySection(analysis: analysis)",
        ]
        XCTAssertEqual(Set(views.keys), Set(FFTRoomSections.Section.allCases), "the table names every section")
        for (section, view) in views {
            XCTAssertTrue(squeezed.contains("case .\(section): \(view) "), "\(section) is drawn by \(view)")
        }
        XCTAssertTrue(try Self.squeezedUI("FFTRoomInspector.swift").contains("if analysis.hasMeasuredSpot { InspectorSection(\"Masked Inverse\")"),
                      "the Masked Inverse section's own guard is the owner's predicate")
    }

    /// A source file of macTEM/UI with its whitespace squeezed to single spaces (and a trailing space, so a line's end matches).
    static func squeezedUI(_ name: String) throws -> String {
        let ui = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("macTEM/UI")
        let text = try String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
    }
}
