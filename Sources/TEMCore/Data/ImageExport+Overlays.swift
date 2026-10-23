//
//  ImageExport+Overlays.swift
//  Role: what `ImageExport.render` draws over the pixels (V1-10 slice 1): the scale bar and the marks, through CoreGraphics
//        and CoreText, in export pixels. The numbers of the bar (its length, its label) are `ImageExport.scaleBarPlan`'s;
//        this file owns the GEOMETRY (the plate, where the label and the bar sit, whether it fits) and the drawing, so the
//        plan, the picture and the metadata all read one layout.
//
//  THE LOOK is the screen's, re-stated in export pixels (archive: export-design-2026-10-13.md, "What the PNG draws"):
//  `ScaleBar` (macTEM/UI/PaneOverlays.swift) — a label over a 2-pt bar, white on a black 45 % plate with 8-pt side and
//  5-pt vertical padding and 3 pt between, 4-pt corners, an 8-pt margin bottom-left — and `ImageMarksOverlay.draw`
//  (macTEM/UI/ImageRoomMarks.swift) in the UNSELECTED style: black 60 % under-stroke 2 pt wider than the yellow line,
//  rings of radius 3, a translucent band for a profile's width, a value label in a black 65 % box kept inside the image.
//  One screen point is `u` export pixels (`ScaleBarMath.overlayScale`). The marks are drawn first and the bar after, as on
//  the screen, where the footer sits above the marks' overlay.
//
//  EXACTNESS: the bar's fill has antialiasing OFF and an integer rectangle, so its white run is exactly `drawnPixels`
//  long (P3 reads it back); everything else is antialiased. Text is drawn without font smoothing and with unquantized
//  subpixel positions, so the same string at the same offset gives the same pixels whatever the user's "font smoothing"
//  preference is (`scaleBarLabelBitmap` is the unit test's handle on that).
//
//  FONTS: CoreText has no public monospaced-DESIGN system font (the screen's `.caption2.monospaced()` is SF Mono, reached
//  through AppKit's `monospacedSystemFont` or SwiftUI, neither of which TEMCore may import). The bar's label is set in the
//  user fixed-pitch font (`.userFixedPitch`, Menlo on this system); the marks' labels are the system font with monospaced
//  digits (kNumberSpacingType / kMonospacedNumbersSelector), as `.caption.monospacedDigit()`.
//

import ImagoCore
import CoreGraphics
import CoreText
import Foundation

extension ImageExport {

    // MARK: - Drawing context

    /// An sRGB, 8-bit, no-alpha bitmap (noneSkipLast, 4 bytes a pixel, `width * 4` bytes a row) with a top-left origin:
    /// drawing at (x, y) lands in row y, so memory row j IS image row j, and the PNG's row 0 is the image's row 0.
    /// The settings are the ones the drawing is deterministic under (see the file header).
    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        return context
    }

    // MARK: - Text

    /// One line of text laid out by CoreText: what a plate or a box is sized from, and what is drawn.
    struct TextLine {
        let line: CTLine
        /// The typographic width and the font's ascent and descent for this line, in export pixels.
        let width: Double
        let ascent: Double
        let descent: Double
        /// The line's box rounded UP to whole pixels (the plate is sized from these).
        var boxWidth: Int { Int(width.rounded(.up)) }
        var boxHeight: Int { Int((ascent + descent).rounded(.up)) }
    }

    /// `string` set in `font`, white. `nil` only if CoreFoundation cannot make the attributed string.
    static func textLine(_ string: String, font: CTFont) -> TextLine? {
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: white]
        guard let attributed = CFAttributedStringCreate(kCFAllocatorDefault, string as CFString,
                                                        attributes as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return TextLine(line: line, width: Double(width), ascent: Double(ascent), descent: Double(descent))
    }

    /// The scale bar's font at `u` export pixels per point: 10·u, fixed pitch.
    /// DEVIATION from the screen's `.caption2.monospaced()` (SF Mono): CoreText offers no public monospaced-design system
    /// font and TEMCore may not import AppKit or SwiftUI, so this is the user fixed-pitch font (Menlo on this system).
    static func scaleBarFont(overlayScale u: Int) -> CTFont {
        let size = CGFloat(10 * u)
        return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil) ?? CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
    }

    /// The marks' labels' font: the system font at 10·u with monospaced digits, so a value changing its digits does not
    /// change the box (`.caption.monospacedDigit()` on the screen).
    static func markFont(overlayScale u: Int) -> CTFont {
        let size = CGFloat(10 * u)
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let features: [[CFString: Int]] = [[kCTFontFeatureTypeIdentifierKey: Int(kNumberSpacingType),
                                            kCTFontFeatureSelectorIdentifierKey: Int(kMonospacedNumbersSelector)]]
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: features] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    /// Draws `text` with its baseline at `baseline` and its left edge at `x`. The context is flipped (top-left origin), so
    /// the text matrix flips the glyphs back upright.
    static func draw(_ text: TextLine, in context: CGContext, x: Double, baseline: Double) {
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(text.line, context)
        context.textMatrix = .identity
    }

    // MARK: - The scale bar

    /// Where every part of the bar sits, in export pixels (y down). `nil` from `barLayout` means the plate does not fit.
    struct BarLayout {
        /// The black plate, origin (m, H − m − plateH).
        let plate: CGRect
        let cornerRadius: Double
        let text: TextLine
        /// The label box's left edge (= the bar's `x0`) and top.
        let labelX: Double
        let labelTop: Double
        /// The bar: integer edges, `drawnPixels` wide, 2·u tall.
        let barX: Int
        let barTop: Int
        let barWidth: Int
        let barHeight: Int
    }

    /// The layout of `plan`'s bar on a `width` × `height` image, or nil when its plate is wider than W/2 or taller than H/3
    /// (then neither plate nor bar is drawn, and the caller says so).
    ///
    /// m = 8u from the left and bottom edges; plate (max(labelW, drawn) + 16u) × (labelH + 3u + 2u + 10u); the bar at
    /// x0 = m + 8u with its top at H − m − 5u − 2u; the label's box sits 3u above the bar, left-aligned at x0.
    static func barLayout(for plan: ScaleBarPlan, width: Int, height: Int) -> BarLayout? {
        let u = plan.overlayScale
        guard u >= 1, plan.drawnPixels >= 1,
              let text = textLine(plan.label, font: scaleBarFont(overlayScale: u)) else { return nil }
        let plateWidth = max(text.boxWidth, plan.drawnPixels) + 16 * u
        let plateHeight = text.boxHeight + 3 * u + 2 * u + 10 * u
        guard Double(plateWidth) <= Double(width) / 2, Double(plateHeight) <= Double(height) / 3 else { return nil }
        let margin = 8 * u
        let barTop = height - margin - 5 * u - 2 * u
        return BarLayout(plate: CGRect(x: margin, y: height - margin - plateHeight, width: plateWidth, height: plateHeight),
                         cornerRadius: Double(4 * u), text: text,
                         labelX: Double(margin + 8 * u), labelTop: Double(barTop - 3 * u - text.boxHeight),
                         barX: margin + 8 * u, barTop: barTop, barWidth: plan.drawnPixels, barHeight: 2 * u)
    }

    /// Draws the plate, the label and the bar. The bar's fill is opaque white, antialiasing OFF, an integer rectangle: its
    /// run of exact white is `barWidth` pixels, which is what the PNG's metadata states and P3 reads back.
    static func drawScaleBar(_ layout: BarLayout, in context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
        context.addPath(CGPath(roundedRect: layout.plate, cornerWidth: layout.cornerRadius,
                               cornerHeight: layout.cornerRadius, transform: nil))
        context.fillPath()
        draw(layout.text, in: context, x: layout.labelX, baseline: layout.labelTop + layout.text.ascent)
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: layout.barX, y: layout.barTop, width: layout.barWidth, height: layout.barHeight))
        context.restoreGState()
    }

    /// The scale bar's label alone, white on black, through the SAME text routine and context settings as the render, laid
    /// out as in the plate (its box at an integer origin): `width` × `height` pixels of RGB, row-major. For a unit test to
    /// compare against the crop of a real export (a black image under the plate stays black), pixel for pixel.
    package static func scaleBarLabelBitmap(_ label: String, overlayScale u: Int) -> (width: Int, height: Int, rgb: [UInt8])? {
        guard u >= 1, let text = textLine(label, font: scaleBarFont(overlayScale: u)),
              text.boxWidth >= 1, text.boxHeight >= 1,
              let context = makeContext(width: text.boxWidth, height: text.boxHeight),
              let data = context.data else { return nil }
        let width = text.boxWidth, height = text.boxHeight
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for pixel in 0..<(width * height) {
            bytes[4 * pixel] = 0; bytes[4 * pixel + 1] = 0; bytes[4 * pixel + 2] = 0; bytes[4 * pixel + 3] = 255
        }
        draw(text, in: context, x: 0, baseline: text.ascent)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        let rowBytes = context.bytesPerRow
        for row in 0..<height {
            for column in 0..<width {
                let source = row * rowBytes + 4 * column, target = 3 * (row * width + column)
                rgb[target] = bytes[source]; rgb[target + 1] = bytes[source + 1]; rgb[target + 2] = bytes[source + 2]
            }
        }
        return (width, height, rgb)
    }

    // MARK: - The marks

    /// Whether `drawMarks` draws a mark: at least two points, every coordinate finite. The metadata lists exactly the marks
    /// this lets through (a mark it refuses is counted in `marks_skipped`), so the Description says what the PNG shows.
    static func isDrawn(_ mark: Mark) -> Bool {
        (mark.kind == .spot ? mark.points.count == 1 : mark.points.count >= 2)
            && mark.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    /// Every mark in the unselected style, in order: the profile's band, the black under-stroke, the yellow line, a ring at
    /// each point, then the value label. A mark that `isDrawn` refuses (a non-finite coordinate, fewer than two points) is
    /// skipped: nothing meaningful to draw.
    /// An image point (x, y) is drawn at (x + 0.5, y + 0.5): the centre of pixel (row y, column x) is at integers.
    static func drawMarks(_ marks: [Mark], in context: CGContext, width: Int, height: Int, overlayScale u: Int) {
        let scale = Double(u)
        let yellow = CGColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1)
        let underStroke = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)
        let font = markFont(overlayScale: u)
        context.saveGState()
        defer { context.restoreGState() }
        for mark in marks {
            guard isDrawn(mark) else { continue }
            let points = mark.points.map { CGPoint(x: $0.x + 0.5, y: $0.y + 0.5) }

            if mark.kind == .profile, mark.width > 1, points.count == 2 {
                let dx = points[1].x - points[0].x, dy = points[1].y - points[0].y
                let length = hypot(dx, dy)
                if length > 0 {
                    let half = Double(mark.width) / 2
                    let nx = -dy / length * half, ny = dx / length * half
                    context.setFillColor(CGColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 0.18))
                    context.beginPath()
                    context.addLines(between: [CGPoint(x: points[0].x + nx, y: points[0].y + ny),
                                               CGPoint(x: points[1].x + nx, y: points[1].y + ny),
                                               CGPoint(x: points[1].x - nx, y: points[1].y - ny),
                                               CGPoint(x: points[0].x - nx, y: points[0].y - ny)])
                    context.closePath()
                    context.fillPath()
                }
            }

            context.setLineCap(.round)
            context.setLineJoin(.round)
            // (A spot has one point: `addLines` makes a lone move-to, which strokes nothing.)
            for (colour, lineWidth) in [(underStroke, 3.5 * scale), (yellow, 1.5 * scale)] {
                context.setStrokeColor(colour)
                context.setLineWidth(lineWidth)
                context.beginPath()
                context.addLines(between: points)
                context.strokePath()
            }
            // A spot is one ring of the FFT pane's radius (7 points, `FFTSpotMarkers.ringRadius`); the others have a small ring per point.
            let ringRadius = (mark.kind == .spot ? 7.0 : 3.0) * scale
            for point in points {
                let ring = CGRect(x: point.x - ringRadius, y: point.y - ringRadius, width: 2 * ringRadius, height: 2 * ringRadius)
                for (colour, lineWidth) in [(underStroke, 3 * scale), (yellow, 1.5 * scale)] {
                    context.setStrokeColor(colour)
                    context.setLineWidth(lineWidth)
                    context.strokeEllipse(in: ring)
                }
            }

            // The label sits beside its anchor: a segment's midpoint, an angle's vertex; kept inside the image so a mark
            // near an edge still shows its value.
            let anchor: CGPoint?
            switch mark.kind {
            case .angle:
                anchor = points.count == 3 ? points[1] : nil
            case .spot:
                anchor = points.count == 1 ? CGPoint(x: points[0].x + 4 * scale, y: points[0].y - 4 * scale) : nil
            case .distance, .profile:
                anchor = points.count == 2 ? CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2) : nil
            }
            guard let anchor, !mark.label.isEmpty, let text = textLine(mark.label, font: font) else { continue }
            let boxWidth = Double(text.boxWidth) + 8 * scale, boxHeight = Double(text.boxHeight) + 2 * scale
            let x = min(max(anchor.x + 6 * scale, 2 * scale), max(Double(width) - boxWidth - 2 * scale, 2 * scale))
            let y = min(max(anchor.y - boxHeight - 6 * scale, 2 * scale), max(Double(height) - boxHeight - 2 * scale, 2 * scale))
            let radius = min(4 * scale, boxWidth / 2, boxHeight / 2)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65))
            context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: boxWidth, height: boxHeight),
                                   cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            draw(text, in: context, x: x + 4 * scale, baseline: y + scale + text.ascent)
        }
    }
}
