//
//  SEMReportPDF.swift
//  Role: the session report as one PDF: A4 pages, the text set by Core Text (so it is text in the file, searchable and sharp), the
//        tables ruled, each figure drawn from the PNG bytes its export wrote with its caption under it, and the title and page number
//        in the footer. Core Graphics and Core Text only, as mac4DSTEM's `FigureRendering.renderPDF` draws its figures; no AppKit,
//        so it runs in TEMCore off the main actor.
//
//        LAYOUT is a single column that flows down the page: a block that does not fit moves to the next page, a heading never stays
//        alone at a page's foot, a long paragraph or table continues on the next page (a table repeats its header there).
//
//        A MAP SMALLER than its place on the page (a 75 x 55 px orientation map drawn 290 pt wide) is enlarged by whole pixels before it
//        is embedded, so a viewer shows the map's pixels as squares instead of smoothing them, as the room's pane does.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO

package nonisolated enum SEMReportPDF {
    /// A4, in points.
    package static let pageSize = CGSize(width: 595.276, height: 841.89)
    /// The margin on every side.
    static let margin: CGFloat = 54
    /// The footer's baseline, above the page's bottom edge.
    static let footerBaseline: CGFloat = 30

    /// The PDF's bytes; nil only when Core Graphics cannot open a PDF context. `creator` names the app ("macEM 1.12.0"), `author` the
    /// person when the report names them.
    package static func data(of document: SEMReportDocument, creator: String, author: String? = nil) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        var info: [CFString: Any] = [kCGPDFContextCreator: creator, kCGPDFContextTitle: document.title]
        if let author, !author.isEmpty { info[kCGPDFContextAuthor] = author }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return nil }
        var page = PageWriter(context: context, footer: document.title, styles: Styles())
        page.begin()
        page.text(document.title, page.styles.title)
        if !document.subtitle.isEmpty { page.text(document.subtitle, page.styles.subtitle) }
        var figureNumber = 0
        for block in document.blocks {
            switch block {
            case .heading(let level, let text):
                page.text(text, level <= 2 ? page.styles.section : page.styles.subsection, keepWithNext: 3 * page.styles.body.lineHeight)
            case .paragraph(let text):
                page.text(text, page.styles.body)
            case .bullets(let items):
                for item in items { page.text("\u{2022}  " + item, page.styles.bullet) }
                page.space(page.styles.body.spaceAfter)
            case .table(let table):
                page.table(table)
            case .figure(let figure):
                figureNumber += 1
                page.figure(figure, number: figureNumber)
            }
        }
        page.end()
        context.closePDF()
        return data as Data
    }

    // MARK: - Styles

    /// One kind of text: its font, colour and the space around it.
    struct Style {
        let font: CTFont
        let color: CGColor
        let spaceBefore: CGFloat
        let spaceAfter: CGFloat
        /// Points the first line is indented by (a bullet's text keeps clear of the bullet only by its two spaces).
        var indent: CGFloat = 0

        var lineHeight: CGFloat { CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font) }

        func attributed(_ string: String) -> CFAttributedString? {
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
            return CFAttributedStringCreate(kCFAllocatorDefault, string as CFString, attributes as CFDictionary)
        }

        /// The one-line width of `string` in this style (a table column's natural width).
        func width(_ string: String) -> CGFloat {
            guard let attributed = attributed(string) else { return 0 }
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
        }
    }

    struct Styles {
        let title: Style
        let subtitle: Style
        let section: Style
        let subsection: Style
        let body: Style
        let bullet: Style
        let cell: Style
        let headerCell: Style
        let caption: Style
        let footer: Style

        init() {
            let ink = CGColor(gray: 0, alpha: 1)
            let secondary = CGColor(gray: 0.38, alpha: 1)
            title = Style(font: Self.font(.emphasizedSystem, 20), color: ink, spaceBefore: 0, spaceAfter: 4)
            subtitle = Style(font: Self.font(.system, 10), color: secondary, spaceBefore: 0, spaceAfter: 14)
            section = Style(font: Self.font(.emphasizedSystem, 14), color: ink, spaceBefore: 12, spaceAfter: 6)
            subsection = Style(font: Self.font(.emphasizedSystem, 11), color: ink, spaceBefore: 8, spaceAfter: 4)
            body = Style(font: Self.font(.system, 10), color: ink, spaceBefore: 0, spaceAfter: 6)
            bullet = Style(font: Self.font(.system, 10), color: ink, spaceBefore: 0, spaceAfter: 2, indent: 8)
            cell = Style(font: Self.font(.system, 8.5), color: ink, spaceBefore: 0, spaceAfter: 0)
            headerCell = Style(font: Self.font(.emphasizedSystem, 8.5), color: ink, spaceBefore: 0, spaceAfter: 0)
            caption = Style(font: Self.font(.system, 9), color: secondary, spaceBefore: 4, spaceAfter: 10)
            footer = Style(font: Self.font(.system, 8), color: secondary, spaceBefore: 0, spaceAfter: 0)
        }

        static func font(_ kind: CTFontUIFontType, _ size: CGFloat) -> CTFont {
            CTFontCreateUIFontForLanguage(kind, size, nil)
                ?? CTFontCreateWithName((kind == .emphasizedSystem ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        }
    }

    // MARK: - The page

    /// Writes blocks down the pages. `top` is the top of the free space in PDF points (y up from the page's bottom edge).
    struct PageWriter {
        let context: CGContext
        let footer: String
        let styles: Styles
        private(set) var pageNumber = 0
        private var top: CGFloat = 0
        /// Whether anything was drawn on this page yet (a block that does not fit an empty page is drawn anyway, cut).
        private var pageHasContent = false

        init(context: CGContext, footer: String, styles: Styles) {
            self.context = context
            self.footer = footer
            self.styles = styles
        }

        var contentWidth: CGFloat { SEMReportPDF.pageSize.width - 2 * SEMReportPDF.margin }
        var pageTop: CGFloat { SEMReportPDF.pageSize.height - SEMReportPDF.margin }
        var bottom: CGFloat { SEMReportPDF.margin }
        var remaining: CGFloat { top - bottom }

        mutating func begin() {
            context.beginPDFPage(nil)
            pageNumber += 1
            top = pageTop
            pageHasContent = false
            drawFooter()
        }

        mutating func end() { context.endPDFPage() }

        mutating func newPage() {
            end()
            begin()
        }

        mutating func space(_ points: CGFloat) {
            top = max(bottom, top - points)
        }

        private func drawFooter() {
            let line = footer.isEmpty ? "Page \(pageNumber)" : "\(footer) \u{00B7} page \(pageNumber)"
            guard let attributed = styles.footer.attributed(line) else { return }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: SEMReportPDF.margin, y: SEMReportPDF.footerBaseline)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }

        // MARK: Text

        /// `string` in `style`, wrapped to the column; a paragraph longer than the space left continues on the next page. `keepWithNext`
        /// is the room a heading wants below it, so it is not left alone at a page's foot.
        mutating func text(_ string: String, _ style: Style, keepWithNext: CGFloat = 0) {
            guard !string.isEmpty, let attributed = style.attributed(string) else { return }
            if pageHasContent { space(style.spaceBefore) }
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let length = CFAttributedStringGetLength(attributed)
            let width = contentWidth - style.indent
            var location = 0
            while location < length {
                let needed = Self.height(framesetter, from: location, width: width)
                // A heading, or what is left of a paragraph when less than two lines fit, starts a new page.
                let minimum = keepWithNext > 0 ? needed + keepWithNext : min(needed, 2 * style.lineHeight)
                if pageHasContent && minimum > remaining {
                    newPage()
                    continue
                }
                let height = min(needed, remaining)
                let rect = CGRect(x: SEMReportPDF.margin + style.indent, y: top - height, width: width, height: height)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), CGPath(rect: rect, transform: nil), nil)
                context.saveGState()
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                context.restoreGState()
                let shown = CTFrameGetVisibleStringRange(frame).length
                pageHasContent = true
                top -= height
                location += shown
                if shown == 0 { break }   // not even one line fits an empty page: nothing more can be drawn
                if location < length { newPage() }
            }
            space(style.spaceAfter)
        }

        /// The height `framesetter`'s text from `location` to its end takes at `width`, with a point of slack so the last line is not
        /// dropped by rounding.
        static func height(_ framesetter: CTFramesetter, from location: Int, width: CGFloat) -> CGFloat {
            let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: location, length: 0), nil,
                                                                    CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            return ceil(size.height) + 1
        }

        // MARK: Tables

        static let cellPaddingX: CGFloat = 4
        static let cellPaddingY: CGFloat = 3

        /// The table, ruled: the header on a light band, a hairline under each row; the header repeats on each new page.
        mutating func table(_ table: SEMReportTable) {
            let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
            guard columns > 0 else { return }
            let widths = columnWidths(table, columns: columns)
            if pageHasContent { space(4) }
            func padded(_ cells: [String]) -> [String] { cells + Array(repeating: "", count: max(0, columns - cells.count)) }
            let header = padded(table.header)
            let headerHeight = rowHeight(header, widths: widths, style: styles.headerCell)
            // The header and the first row stay together.
            let firstHeight = table.rows.first.map { rowHeight(padded($0), widths: widths, style: styles.cell) } ?? 0
            if pageHasContent && headerHeight + firstHeight > remaining { newPage() }
            drawRow(header, widths: widths, height: headerHeight, style: styles.headerCell, isHeader: true)
            for row in table.rows {
                let cells = padded(row)
                let height = rowHeight(cells, widths: widths, style: styles.cell)
                if height > remaining {
                    newPage()
                    drawRow(header, widths: widths, height: headerHeight, style: styles.headerCell, isHeader: true)
                }
                drawRow(cells, widths: widths, height: height, style: styles.cell, isHeader: false)
            }
            space(styles.body.spaceAfter + 4)
        }

        /// Each column's natural width (its widest cell on one line), shrunk to the page: columns narrower than an equal share keep
        /// their width, the rest share what is left in proportion to how much more they want.
        func columnWidths(_ table: SEMReportTable, columns: Int) -> [CGFloat] {
            var natural = Array(repeating: CGFloat(0), count: columns)
            for (index, text) in table.header.enumerated() {
                natural[index] = max(natural[index], styles.headerCell.width(text) + 2 * Self.cellPaddingX)
            }
            for row in table.rows {
                for (index, text) in row.enumerated() where index < columns {
                    natural[index] = max(natural[index], styles.cell.width(text) + 2 * Self.cellPaddingX)
                }
            }
            let total = natural.reduce(0, +)
            guard total > contentWidth else { return natural }
            let share = contentWidth / CGFloat(columns)
            var widths = natural.map { min($0, share) }
            let wants = zip(natural, widths).map { max(0, $0 - $1) }
            let wanted = wants.reduce(0, +)
            let left = contentWidth - widths.reduce(0, +)
            if wanted > 0 {
                for index in widths.indices { widths[index] += left * wants[index] / wanted }
            }
            return widths
        }

        func rowHeight(_ cells: [String], widths: [CGFloat], style: Style) -> CGFloat {
            var height = style.lineHeight
            for (text, width) in zip(cells, widths) where !text.isEmpty {
                guard let attributed = style.attributed(text) else { continue }
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                height = max(height, Self.height(framesetter, from: 0, width: max(1, width - 2 * Self.cellPaddingX)))
            }
            return min(height + 2 * Self.cellPaddingY, pageTop - bottom)
        }

        mutating func drawRow(_ cells: [String], widths: [CGFloat], height: CGFloat, style: Style, isHeader: Bool) {
            let tableWidth = widths.reduce(0, +)
            let rowRect = CGRect(x: SEMReportPDF.margin, y: top - height, width: tableWidth, height: height)
            context.saveGState()
            if isHeader {
                context.setFillColor(CGColor(gray: 0.93, alpha: 1))
                context.fill(rowRect)
            }
            context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: rowRect.minX, y: rowRect.minY))
            context.addLine(to: CGPoint(x: rowRect.maxX, y: rowRect.minY))
            context.strokePath()
            context.textMatrix = .identity
            var x = SEMReportPDF.margin
            for (text, width) in zip(cells, widths) {
                defer { x += width }
                guard !text.isEmpty, let attributed = style.attributed(text) else { continue }
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                let cellRect = CGRect(x: x + Self.cellPaddingX, y: rowRect.minY + Self.cellPaddingY,
                                      width: max(1, width - 2 * Self.cellPaddingX), height: max(1, height - 2 * Self.cellPaddingY))
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: cellRect, transform: nil), nil)
                CTFrameDraw(frame, context)
            }
            context.restoreGState()
            pageHasContent = true
            top -= height
        }

        // MARK: Figures

        /// The figure at the column's width (a small map at 60 % of it, enlarged by whole pixels), never taller than half the page,
        /// its caption under it; both move to the next page together when they do not fit.
        mutating func figure(_ figure: SEMReportFigure, number: Int) {
            let caption = "Figure \(number). " + figure.caption
            guard let image = Self.image(figure.png), image.width > 0, image.height > 0 else {
                text(caption + " (the figure's bytes could not be read)", styles.caption)
                return
            }
            let size = Self.drawnSize(pixelWidth: image.width, pixelHeight: image.height, column: contentWidth,
                                      maximumHeight: (pageTop - bottom) * 0.5)
            let captionHeight: CGFloat = {
                guard let attributed = styles.caption.attributed(caption) else { return 0 }
                return Self.height(CTFramesetterCreateWithAttributedString(attributed), from: 0, width: contentWidth)
            }()
            if pageHasContent { space(styles.caption.spaceBefore) }
            if pageHasContent && size.height + captionHeight + styles.caption.spaceBefore > remaining { newPage() }
            let embedded = Self.enlarged(image, toCover: size) ?? image
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(embedded, in: CGRect(x: SEMReportPDF.margin, y: top - size.height, width: size.width, height: size.height))
            context.restoreGState()
            pageHasContent = true
            top -= size.height
            text(caption, styles.caption)
        }

        /// The figure's size on the page: the column's width for a figure at least that wide in pixels at 2 px per point, 60 % of it
        /// for a smaller one (never smaller than its pixels at 1 px per point), the aspect kept, capped at `maximumHeight`.
        static func drawnSize(pixelWidth: Int, pixelHeight: Int, column: CGFloat, maximumHeight: CGFloat) -> CGSize {
            let w = CGFloat(pixelWidth), h = CGFloat(pixelHeight)
            var width = min(column, max(w / 2, min(column * 0.6, w * 8)))
            var height = width * h / w
            if height > maximumHeight {
                height = maximumHeight
                width = height * w / h
            }
            return CGSize(width: width, height: height)
        }

        static func image(_ png: Data) -> CGImage? {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        /// `image` enlarged by a whole factor (nearest neighbour) so it has at least two pixels per point of `size`; nil when it already
        /// has (or the factor would pass 8, or the copy cannot be made).
        static func enlarged(_ image: CGImage, toCover size: CGSize) -> CGImage? {
            let factor = Int((2 * size.width / CGFloat(image.width)).rounded(.up))
            guard factor >= 2, factor <= 8 else { return nil }
            let width = image.width * factor, height = image.height * factor
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
    }
}
