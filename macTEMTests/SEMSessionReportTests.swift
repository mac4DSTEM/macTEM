//
//  SEMSessionReportTests.swift
//  The SEM session report (P8-02, design export-and-reports §4, D-SEM-103) on a planted session: the Markdown is pinned whole (a golden
//  of every section, the figure linked by its name next to the report, the files without a picture in a table, the methods of the kept
//  sections with their literature, the versions); the PDF is text with every heading, the figure drawn once and the pages numbered; a
//  section switched off is left out with its methods; the outline counts what each section would hold; the versions are the lock's
//  and Package.resolved's.
//  Red before the report: no `SEMSessionReport`. Red under: a section out of order; a figure embedded in the Markdown or linked by its
//  full path beside the report; the methods of a section switched off still cited; a kit updated without its line in `builtWith`.
//

import CoreGraphics
import Foundation
import PDFKit
import TEMCore
import XCTest
@testable import macTEM

nonisolated final class SEMSessionReportTests: XCTestCase {
    /// 2026-11-07 16:42:00 UTC.
    private static let t0 = Date(timeIntervalSince1970: 1_794_069_720)
    private static let folder = URL(fileURLWithPath: "/data/nickel", isDirectory: true)

    private static func png() throws -> Data {
        try XCTUnwrap(PatternsRoomState.mixPNG(rgba: [UInt8](repeating: 200, count: 16), width: 2, height: 2, fileName: "patterns_v2.h5"))
    }

    /// A session: the dataset, a processing run, a Hough run, a map PNG and an .ang written next to the data.
    private static func rows() throws -> [SEMSessionRow] {
        let figureFile = folder.appendingPathComponent("patterns_v2 indexed IPF-Z.png")
        return [
            SEMSessionRow(id: "dataset", kind: .dataset, label: "patterns_v2.h5", value: "HDF5 · 55 × 75 of 60 × 60", source: "Patterns",
                          time: t0, fields: [SEMSessionField("Step", "1.5 µm × 1.5 µm"), SEMSessionField("Beam", "20 kV")],
                          methods: [.patternReading], file: folder.appendingPathComponent("patterns_v2.h5")),
            SEMSessionRow(id: "processing", kind: .processing, label: "Pattern processing", value: "Static background · Dynamic background",
                          source: "Patterns · patterns_v2.h5", time: t0.addingTimeInterval(60),
                          fields: [SEMSessionField("Static background", "Subtract · The file's"), SEMSessionField("State", "Current")],
                          methods: [.staticBackground, .dynamicBackground],
                          log: [SEMLogLine(time: t0.addingTimeInterval(60), text: "Processed 4125 patterns in 1.2 s · 59.4 MB in memory")]),
            SEMSessionRow(id: "indexing", kind: .indexing, label: "Hough indexing", value: "4,125 of 4,125 indexed · ni",
                          source: "Indexing · patterns_v2.h5", time: t0.addingTimeInterval(120),
                          fields: [SEMSessionField("Indexed", "4,125 of 4,125"), SEMSessionField("Mean CI", "0.9 over the indexed points")],
                          methods: [.houghIndexing]),
            SEMSessionRow(id: "export:0", kind: .export, label: "patterns_v2 indexed IPF-Z.png", value: "Map PNG, 2 × 2 px",
                          source: "Indexing · patterns_v2.h5", time: t0.addingTimeInterval(180), fields: [SEMSessionField("Layer", "IPF-Z")],
                          methods: [.houghIndexing, .ipfColours], file: figureFile,
                          figure: SEMReportFigure(png: try png(), pixelWidth: 2, pixelHeight: 2, caption: "", file: figureFile)),
            SEMSessionRow(id: "export:1", kind: .export, label: "patterns_v2 indexed.ang", value: "EDAX ANG", source: "Indexing · patterns_v2.h5",
                          time: t0.addingTimeInterval(190), methods: [.houghIndexing, .angWriter],
                          file: folder.appendingPathComponent("patterns_v2 indexed.ang")),
        ]
    }

    private static let context = SEMSessionReport.Context(date: t0.addingTimeInterval(200), software: "macEM 9.9.9 (1)",
                                                          packages: [SEMSessionField("FormatoKit", "0.12.1")],
                                                          timeZone: TimeZone(identifier: "UTC")!)

    private static func options(_ format: SEMSessionReport.Format, _ sections: Set<SEMSessionReport.Section> = Set(SEMSessionReport.Section.allCases)) -> SEMSessionReport.Options {
        SEMSessionReport.Options(title: "Nickel session", sections: sections, format: format)
    }

    // MARK: - Markdown

    /// The whole Markdown of the planted session, section by section.
    func testTheMarkdownOfAPlantedSessionIsTheGolden() throws {
        let document = SEMSessionReport.document(try Self.rows(), options: Self.options(.markdown), context: Self.context)
        let text = SEMReportMarkdown.text(of: document, directory: Self.folder)
        let methods = [SEMMethod.patternReading, .staticBackground, .dynamicBackground, .houghIndexing, .ipfColours, .angWriter].map { m in
            "### \(m.title)\n\n\(m.sentence) Parity reference: \(m.parityReference).\n\n" + m.references.map { "- " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        let references = SEMReferenceVersions.pinned.map { "| \($0.name) \($0.version) | parity reference (tools/parity/sem) |" }
            .joined(separator: "\n")
        let expected = """
        # Nickel session

        2026-11-07 16:45 · macEM 9.9.9 (1)

        ## Opened files

        | File | Room | Contents | Folder |
        |---|---|---|---|
        | patterns_v2.h5 | Patterns | HDF5 · 55 × 75 of 60 × 60 | /data/nickel |

        ## Calibration

        ### patterns_v2.h5

        HDF5 · 55 × 75 of 60 × 60 (16:42:00)

        | Parameter | Value |
        |---|---|
        | Step | 1.5 µm × 1.5 µm |
        | Beam | 20 kV |

        ## Processing

        ### Pattern processing

        Static background · Dynamic background (16:43:00)

        | Parameter | Value |
        |---|---|
        | Static background | Subtract · The file's |
        | State | Current |

        - 16:43:00  Processed 4125 patterns in 1.2 s · 59.4 MB in memory

        ## Indexing

        ### Hough indexing

        4,125 of 4,125 indexed · ni (16:44:00)

        | Parameter | Value |
        |---|---|
        | Indexed | 4,125 of 4,125 |
        | Mean CI | 0.9 over the indexed points |

        ## Figures

        ![Figure 1](patterns_v2%20indexed%20IPF-Z.png)

        Figure 1. patterns_v2 indexed IPF-Z.png: Map PNG, 2 × 2 px. Indexing · patterns_v2.h5 · Layer IPF-Z · written 16:45:00.

        ### Files written

        | File | What | From | Time |
        |---|---|---|---|
        | patterns_v2 indexed.ang | EDAX ANG | Indexing · patterns_v2.h5 | 16:45:10 |

        ## Methods and references

        \(methods)

        ## Versions

        | Package | Role |
        |---|---|
        | macEM 9.9.9 (1) | the app that made this report |
        | FormatoKit 0.12.1 | a Swift package the app is built with |
        \(references)

        """
        XCTAssertEqual(text, expected)
        XCTAssertEqual(document.sectionTitles, ["Opened files", "Calibration", "Processing", "Indexing", "Figures", "Methods and references", "Versions"])
    }

    /// Written somewhere else than the figures, the Markdown links each figure by its file URL; a pipe in a cell is escaped.
    func testAFigureInAnotherFolderIsLinkedByItsURLAndPipesAreEscaped() throws {
        let document = SEMSessionReport.document(try Self.rows(), options: Self.options(.markdown), context: Self.context)
        let text = SEMReportMarkdown.text(of: document, directory: URL(fileURLWithPath: "/elsewhere", isDirectory: true))
        XCTAssertTrue(text.contains("![Figure 1](file:///data/nickel/patterns_v2%20indexed%20IPF-Z.png)"), text)
        let table = SEMReportTable(header: ["a"], rows: [["x | y"]])
        let piped = SEMReportMarkdown.text(of: SEMReportDocument(title: "t", subtitle: "", blocks: [.table(table)]), directory: nil)
        XCTAssertTrue(piped.contains("| x \\| y |"), piped)
    }

    // MARK: - Choices

    /// A section switched off is left out, and so are the methods only it used; the outline counts what each section would hold.
    func testASectionSwitchedOffIsLeftOutWithItsMethods() throws {
        let rows = try Self.rows()
        let document = SEMSessionReport.document(rows, options: Self.options(.markdown, [.indexing, .methods]), context: Self.context)
        XCTAssertEqual(document.sectionTitles, ["Indexing", "Methods and references"])
        var cited: [String] = []
        var inMethods = false
        for block in document.blocks {
            guard case .heading(let level, let text) = block else { continue }
            if level == 2 { inMethods = text == "Methods and references" } else if inMethods { cited.append(text) }
        }
        XCTAssertEqual(cited, [SEMMethod.houghIndexing.title], "only the kept rows' methods are cited")
        XCTAssertEqual(SEMSessionReport.document(rows, options: Self.options(.pdf, []), context: Self.context).blocks, [])
        let outline = SEMSessionReport.outline(rows)
        XCTAssertEqual(outline[.openedFiles], 1)
        XCTAssertEqual(outline[.processing], 1)
        XCTAssertEqual(outline[.maps], 0)
        XCTAssertEqual(outline[.figures], 2)
        XCTAssertEqual(outline[.methods], 6)
        XCTAssertEqual(SEMSessionReport.defaultTitle(rows), "patterns_v2 session report")
        XCTAssertEqual(SEMSessionReport.defaultTitle([]), "SEM session report")
    }

    // MARK: - PDF

    /// The PDF is text: every heading the journey reads, the title in its info; the figure is drawn once; a long report flows onto
    /// numbered pages.
    func testThePDFIsTextWithItsHeadingsAndDrawsTheFigure() throws {
        let document = SEMSessionReport.document(try Self.rows(), options: Self.options(.pdf), context: Self.context)
        let data = try XCTUnwrap(SEMReportPDF.data(of: document, creator: "macEM 9.9.9 (1)"))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(pdf.string)
        for heading in ["Processing", "Indexing", "Methods and references", "Versions", "Nickel session"] {
            XCTAssertTrue(text.contains(heading), heading)
        }
        XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Nickel session")
        var images = 0
        for index in 0..<pdf.pageCount {
            if let page = pdf.page(at: index)?.pageRef { images += Self.imageCount(page) }
        }
        XCTAssertGreaterThanOrEqual(images, 1, "the map PNG is drawn in the PDF")

        let long = SEMReportDocument(title: "Long", subtitle: "", blocks: (0..<120).map { .paragraph("Paragraph \($0) of the long report.") })
        let pages = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(SEMReportPDF.data(of: long, creator: "macEM"))))
        XCTAssertGreaterThanOrEqual(pages.pageCount, 2)
        XCTAssertTrue(pages.string?.contains("page 2") == true, "the footer numbers the pages")
        XCTAssertTrue(pages.string?.contains("Paragraph 119") == true, "the last paragraph is on a page")
    }

    /// The image XObjects of a page's resources.
    private static func imageCount(_ page: CGPDFPage) -> Int {
        guard let dictionary = page.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return 0 }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return 0 }
        return CGPDFDictionaryGetCount(objects)
    }

    // MARK: - Versions

    /// The report's versions are the parity lock's and Package.resolved's: a kit update or a re-pinned reference changes the line here in
    /// the same pull request.
    func testTheVersionsAreTheLockAndPackageResolved() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let lock = try String(contentsOf: root.appendingPathComponent("tools/parity/sem/requirements.lock"), encoding: .utf8)
        var locked: [String: String] = [:]
        for line in lock.split(separator: "\n") {
            let parts = line.components(separatedBy: "==")
            if parts.count == 2 { locked[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        for (name, version) in SEMReferenceVersions.pinned {
            XCTAssertEqual(locked[name.lowercased()], version, "\(name) in tools/parity/sem/requirements.lock")
        }
        for path in ["Package.resolved", "macTEM.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
            var resolved: [String: String] = [:]
            for pin in pins {
                if let identity = pin["identity"] as? String, let state = pin["state"] as? [String: Any], let version = state["version"] as? String {
                    resolved[identity.lowercased()] = version
                }
            }
            for field in SEMReferenceVersions.builtWith {
                XCTAssertEqual(resolved[field.name.lowercased()], field.value, "\(field.name) in \(path): update SEMReferenceVersions.builtWith with the kit")
            }
            XCTAssertEqual(Set(resolved.keys), Set(SEMReferenceVersions.builtWith.map { $0.name.lowercased() }), "every package the app is built with is listed")
        }
    }
}
