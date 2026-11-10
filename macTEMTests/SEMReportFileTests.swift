//
//  SEMReportFileTests.swift
//  The session report as a file (`SEMReportFile`, #341): the name it is saved under (the title, without the characters a file
//  name cannot hold, and a fallback when nothing is left), the content type the save panel takes for each format, and the line
//  the status bar shows once it is written.
//  Red under: a slash, colon or backslash left in the name, an empty name, another fallback, "1 sections" or "1 figures", a
//  changed word in the line.
//

import XCTest
import UniformTypeIdentifiers
import TEMCore
@testable import macTEM

nonisolated final class SEMReportFileTests: XCTestCase {

    /// A report of `sections` level-2 headings and `figures` figures, with a part heading and a paragraph that count as neither.
    private static func document(sections: Int, figures: Int) -> SEMReportDocument {
        var blocks: [SEMReportDocument.Block] = []
        for section in 0..<sections {
            blocks.append(.heading(level: 2, text: "Section \(section + 1)"))
            blocks.append(.heading(level: 3, text: "A part"))
            blocks.append(.paragraph("Words."))
        }
        for figure in 0..<figures {
            blocks.append(.figure(SEMReportFigure(png: Data(), pixelWidth: 1, pixelHeight: 1, caption: "Figure \(figure + 1)", file: nil)))
        }
        return SEMReportDocument(title: "Report", subtitle: "", blocks: blocks)
    }

    /// A slash, a colon and a backslash each become a hyphen; the blanks around the title go; everything else stays.
    func testTheFileNameIsTheTitleWithoutWhatAFileNameCannotHold() {
        XCTAssertEqual(SEMReportFile.stem("a/b:c"), "a-b-c")
        XCTAssertEqual(SEMReportFile.stem("a\\b"), "a-b")
        XCTAssertEqual(SEMReportFile.stem("  Nickel 12:30 \n"), "Nickel 12-30")
        XCTAssertEqual(SEMReportFile.stem("patterns_v2 session report"), "patterns_v2 session report")
        XCTAssertEqual(SEMReportFile.stem("Ni (α) – scan 3"), "Ni (α) – scan 3")
    }

    /// A title of nothing, or of blanks alone, falls back to a name that says what the file is.
    func testAnEmptyTitleFallsBackToSEMSessionReport() {
        XCTAssertEqual(SEMReportFile.stem(""), "SEM session report")
        XCTAssertEqual(SEMReportFile.stem("  "), "SEM session report")
        XCTAssertEqual(SEMReportFile.stem(" \n\t "), "SEM session report")
    }

    /// A PDF report is saved as a PDF; a Markdown report as a type other than PDF that takes the `.md` extension.
    func testTheContentTypeFollowsTheFormat() {
        XCTAssertEqual(SEMReportFile.contentType(.pdf), UTType.pdf)
        let markdown = SEMReportFile.contentType(.markdown)
        XCTAssertNotEqual(markdown, UTType.pdf)
        XCTAssertTrue(markdown.tags[.filenameExtension]?.contains("md") == true, "\(markdown.identifier) does not take .md")
        for format in SEMSessionReport.Format.allCases {
            let type = SEMReportFile.contentType(format)
            XCTAssertTrue(type.tags[.filenameExtension]?.contains(format.fileExtension) == true,
                          "\(type.identifier) does not take .\(format.fileExtension)")
        }
    }

    /// The status line counts the report's sections and figures, each in the singular for one.
    func testTheDoneLineCountsSectionsAndFiguresInWords() {
        XCTAssertEqual(SEMReportFile.doneLine(name: "patterns_v2 session report.pdf", document: Self.document(sections: 7, figures: 3)),
                       "Exported patterns_v2 session report.pdf \u{2014} 7 sections, 3 figures")
        XCTAssertEqual(SEMReportFile.doneLine(name: "r.md", document: Self.document(sections: 1, figures: 1)),
                       "Exported r.md \u{2014} 1 section, 1 figure")
        XCTAssertEqual(SEMReportFile.doneLine(name: "r.md", document: Self.document(sections: 0, figures: 0)),
                       "Exported r.md \u{2014} 0 sections, 0 figures")
        XCTAssertEqual(SEMReportFile.doneLine(name: "r.pdf", document: Self.document(sections: 1, figures: 2)),
                       "Exported r.pdf \u{2014} 1 section, 2 figures")
    }
}
