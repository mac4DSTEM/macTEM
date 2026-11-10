//
//  KikuchiOverlayExport.swift
//  Role: `Pattern with overlay…` (docs/sem/design/simulation-overlay.md §4): the pattern as the pane shows it (its colormap, window and
//        gamma, through the Image room's exporter) enlarged by whole pixels so the drawing is legible, with the Kikuchi overlay drawn as
//        the pane draws it: the kinematical simulation at the Blend opacity when it is on, the band centre lines, the band edges when
//        `Band width` is on, the zone axes as rings, the {hkl} and [uvw] labels. The numbers are `KikuchiOverlay`'s (TEMCore); this only draws them. AppKit draws the text (`NSString.draw` in an
//        `NSGraphicsContext` on the bitmap), as SwiftUI has no off-screen text renderer that writes into a CGContext.
//

import AppKit
import Foundation
import ImageIO
import TEMCore

nonisolated enum KikuchiOverlayExport {
    /// The smallest side the figure is enlarged to (a 60 px pattern becomes 480 px): whole-pixel enlargement, at least 1.
    static let minimumSide = 480

    /// The enlargement of a `width` x `height` pattern.
    static func scale(width: Int, height: Int) -> Int {
        max(1, Int((Double(minimumSide) / Double(max(1, min(width, height)))).rounded(.up)))
    }

    /// The figure as PNG bytes: `patternPNG` (one pixel per detector pixel) enlarged by `scale(width:height:)` with the overlay drawn in
    /// `accent`, through the app's one encoder (`ImageExport.encodePNG`) with `fileName` as Title, macTEM as Software and what is
    /// drawn as Description; nil when the PNG cannot be read or written.
    @MainActor static func png(patternPNG: Data, fileName: String, overlay: KikuchiOverlay.Pattern, settings: KikuchiOverlay.Settings,
                               accent: CGColor = CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)) -> Data? {
        guard let source = CGImageSourceCreateWithData(patternPNG as CFData, nil),
              let pattern = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let s = scale(width: pattern.width, height: pattern.height)
        let width = pattern.width * s, height = pattern.height * s
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(pattern, in: CGRect(x: 0, y: 0, width: width, height: height))
        if settings.kinematical, let simulated = KikuchiOverlayLayer.simulatedImage(overlay) {
            // The kinematical simulation at the Blend opacity, as the pane draws it.
            context.setAlpha(CGFloat(settings.blend))
            context.draw(simulated, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.setAlpha(1)
        }
        // Flip to the image's frame (y down) so detector pixels map as the pane maps them: centre of pixel i at (i + 0.5) · s.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let k = CGFloat(s)
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (CGFloat(x) + 0.5) * k, y: (CGFloat(y) + 0.5) * k) }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let lineWidth = max(1.2, k * 0.2)

        let lines = CGMutablePath(), edges = CGMutablePath()
        for line in overlay.simulation.lines {
            let a = point(line.pixel[0], line.pixel[1]), b = point(line.pixel[2], line.pixel[3])
            if let (p, q) = clipped(a, b, to: rect) { lines.move(to: p); lines.addLine(to: q) }
            if settings.bandWidth {
                for edge in line.edges {
                    for run in edge.pixelRuns {
                        edges.addLines(between: run.map { point($0.x, $0.y) })
                    }
                }
            }
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for (path, width, alpha) in [(lines, lineWidth, CGFloat(1)), (edges, lineWidth * 0.6, CGFloat(0.85))] where !path.isEmpty {
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
            context.setLineWidth(width + 1.3)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(accent.copy(alpha: alpha) ?? accent)
            context.setLineWidth(width)
            context.strokePath()
        }

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let fontSize = max(10, k * 1.4)
        if settings.zoneAxes {
            for axis in overlay.simulation.zoneAxes {
                let c = point(axis.pixel.x, axis.pixel.y)
                guard rect.contains(c) else { continue }
                let r = max(3, k * 0.45)
                let ring = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                context.setFillColor(.white)
                context.fillEllipse(in: ring)
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.7))
                context.setLineWidth(1)
                context.strokeEllipse(in: ring)
                if settings.labels {
                    draw(KikuchiOverlay.millerText(axis.uvw, brackets: "[]"), centredAt: CGPoint(x: c.x, y: c.y - r - fontSize * 0.7),
                         size: fontSize * 0.85, color: .white, bold: false)
                }
            }
        }
        if settings.labels {
            let inner = rect.insetBy(dx: fontSize * 1.4, dy: fontSize * 0.8)
            for (line, label) in zip(overlay.simulation.lines, overlay.lineLabels) {
                let a = point(line.pixel[0], line.pixel[1]), b = point(line.pixel[2], line.pixel[3])
                guard let (_, q) = clipped(a, b, to: rect) else { continue }
                let at = CGPoint(x: min(max(q.x, inner.minX), inner.maxX), y: min(max(q.y, inner.minY), inner.maxY))
                draw(label, centredAt: at, size: fontSize, color: NSColor(cgColor: accent) ?? .systemBlue, bold: true)
            }
        }
        guard let image = context.makeImage() else { return nil }
        let description = "Kikuchi overlay of \(overlay.phase): \(overlay.drawnWords); "
            + "pattern enlarged \(s)x; macTEM"
        // A tEXt Description, as the Image room's PNGs carry theirs: ImageIO's PNG property would become an XMP packet instead.
        return try? ImageExport.encodePNG(image, title: fileName, software: "macTEM", description: description)
    }

    /// A label centred on `point` with a dark shadow, so it reads on any part of the pattern.
    @MainActor private static func draw(_ text: String, centredAt point: CGPoint, size: CGFloat, color: NSColor, bold: Bool) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: color, .shadow: shadow,
        ]
        let string = text as NSString
        let extent = string.size(withAttributes: attributes)
        string.draw(at: CGPoint(x: point.x - extent.width / 2, y: point.y - extent.height / 2), withAttributes: attributes)
    }

    /// The part of the segment a–b inside `rect` (Liang–Barsky), nil when it misses.
    static func clipped(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        var t0: CGFloat = 0, t1: CGFloat = 1
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                if t0 > t1 { return nil }
            }
        }
        return (CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy), CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy))
    }
}
