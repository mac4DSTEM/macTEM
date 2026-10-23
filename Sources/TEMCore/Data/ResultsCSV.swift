//
//  ResultsCSV.swift
//  Role: every finished measurement of one file as ONE tidy CSV (V1-10 slice 3; archive: roadmap-registrations-2026-10-15.md "Slice 3, the Results room and one
//        tidy CSV", clauses R-P1 and R-P2; archive: results-room-design-2026-10-15.md, section 5): a `# key: value` header,
//        then `group,id,label,quantity,value,unit,text,validation,lineage` and one line per quantity of each `ResultRow`.
//        Pure text; `export` writes it through `ExportFile.write` off the main actor. One long format because rows differ in
//        columns and a script wants one shape.
//
//  The file is ImagoKit's `TidyResultsCSV` (ImagoCore 0.5.0: header, `%.17g` numbers, RFC 4180 cells, the unvalidated clause);
//  what stays here is the rows' conversion, the title and the sentences only the app can claim.
//
//  THE VALIDATION: the `validation` column holds the product's own constant (`ResultRow.Product.validation`), and the header
//  holds one `# validation (<product>): ...` line for each product present, the same constant; when the file's reader notes say
//  "unvalidated", both carry `unvalidatedClause` after it. No sentence is authored here.
//

import Foundation
import ImagoCore

package nonisolated enum ResultsCSV {
    /// Added to every validation sentence when the file's reader notes say it is unvalidated.
    package static let unvalidatedClause = TidyResultsCSV.unvalidatedClause

    package static let columns = TidyResultsCSV.columns

    /// The whole file (UTF-8, LF), or nil without a row. `session` is the sentence that says where the file's marks are kept
    /// ("Not saved…", "Saved at 14:03…"); `source` states the file and its calibration as the file does.
    package static func text(_ rows: [ResultRow], source: ExportSource, session: String) -> String? {
        let kitRows = rows.map { row in
            TidyResultsCSV.Row(group: row.group.rawValue, id: row.id, label: row.label, product: row.product.rawValue,
                               entries: row.entries.map { TidyResultsCSV.Entry($0.name, $0.value, unit: $0.unit, text: $0.text) },
                               refusal: row.refusal, lineage: row.lineage)
        }
        let validations = ResultRow.Product.allCases.map { (product: $0.rawValue, sentence: $0.validation) }
        do {
            return try TidyResultsCSV.text(
                kitRows, source: source, title: "macTEM results", session: session,
                descriptionLines: [
                    "# points: x1, y1, x2, y2, ... are image pixels (x column, y row, pixel centres at integers); an angle's vertex "
                        + "is point 2; click and centroid are bins of the centred spectrum; region is in image pixels",
                    "# units: lengths in the file's unit as the file states it (a Velox metre axis stays in metres), px for pixels",
                ],
                validations: validations,
                lineageLine: "# lineage: a mark's node id in the session record once saved, empty before and for FFT spots (not recorded)")
        } catch {
            preconditionFailure("every ResultRow.Product has a validation sentence: \(error)")
        }
    }

    /// Renders and writes off the main actor (`ExportFile.write`); throws `ExportFile.Failure.noResults` for no row.
    @concurrent package static func export(_ rows: [ResultRow], source: ExportSource, session: String, to url: URL) async throws {
        guard let text = text(rows, source: source, session: session) else { throw ExportFile.Failure.noResults }
        try ExportFile.write(Data(text.utf8), to: url)
    }
}
