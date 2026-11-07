//
//  SEMReportDocument.swift
//  Role: the session report as a list of blocks (headings, paragraphs, tables, figures), the one value both writers take:
//        `SEMReportMarkdown` sets it as Markdown, `SEMReportPDF` as pages. What goes in it is `SEMSessionReport`'s choice; this
//        file only says what a report is made of. A value: Sendable, so the PDF is drawn off the main actor.
//
//        No number is made here: every cell is a string the room already showed or exported (design export-and-reports §4).
//

import Foundation
import ImageIO

package nonisolated struct SEMReportDocument: Sendable, Equatable {
    /// One piece of the report, in reading order.
    package enum Block: Sendable, Equatable {
        /// A section title: level 2 for a section ("Indexing"), 3 for a part of one ("Hough, 14:02").
        case heading(level: Int, text: String)
        case paragraph(String)
        /// A list, one line per item.
        case bullets([String])
        case table(SEMReportTable)
        case figure(SEMReportFigure)
    }

    /// The report's title (the first line, the PDF's title).
    package var title: String
    /// The line under the title: the date, the app and its version, the author when the person chose to name them.
    package var subtitle: String
    package var blocks: [Block]

    package init(title: String, subtitle: String, blocks: [Block]) {
        self.title = title
        self.subtitle = subtitle
        self.blocks = blocks
    }

    /// The section headings, in order: what the Report section's outline lists and a test reads.
    package var sectionTitles: [String] {
        blocks.compactMap { block -> String? in
            if case .heading(let level, let text) = block, level == 2 { return text }
            return nil
        }
    }

    /// The figures, in order.
    package var figures: [SEMReportFigure] {
        blocks.compactMap { block -> SEMReportFigure? in
            if case .figure(let figure) = block { return figure }
            return nil
        }
    }
}

/// A table: one header row and the rows under it, every cell a string as shown on screen.
package nonisolated struct SEMReportTable: Sendable, Equatable {
    package var header: [String]
    package var rows: [[String]]

    package init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    /// A two-column table of names and values (a stage's parameters, a file's facts).
    package init(fields: [SEMSessionField], nameHeader: String = "Parameter", valueHeader: String = "Value") {
        self.init(header: [nameHeader, valueHeader], rows: fields.map { [$0.name, $0.value] })
    }
}

/// A figure the session exported: the bytes as written (a PNG), its size in pixels, the caption that says what it shows, and the file
/// it was written to (the Markdown report links it; the PDF draws the bytes).
package nonisolated struct SEMReportFigure: Sendable, Equatable {
    package var png: Data
    package var pixelWidth: Int
    package var pixelHeight: Int
    package var caption: String
    /// Where the export wrote it; nil when the place is not known (a figure kept only in memory).
    package var file: URL?

    package init(png: Data, pixelWidth: Int, pixelHeight: Int, caption: String, file: URL?) {
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.caption = caption
        self.file = file
    }

    /// A figure of PNG bytes as an export wrote them, its size read from the file (ImageIO); nil when the bytes are not an image.
    package init?(png: Data, caption: String, file: URL?) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        self.init(png: png, pixelWidth: width, pixelHeight: height, caption: caption, file: file)
    }
}
