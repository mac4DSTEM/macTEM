//
//  SEMSessionRow.swift
//  Role: one product of the window's SEM session as the Results room lists it and the session report sets it: the pattern dataset
//        opened, the processing run that landed, the virtual and quality maps, each indexing run, the orientation map on screen, the
//        SEM-EDS composition, each file a SEM room exported. A value: built by `SEMSessionLedger` (TEMSession) from what the rooms hold
//        and what the session record kept, never stored by the room and never recomputed (design export-and-reports §3, §4;
//        D-SEM-103, D-SEM-104).
//
//        THE STRINGS are the rooms' own: a count as the Indexing room's header spells it, a parameter in the inspector's words. A summary
//        statistic (the indexed fraction, the mean confidence index of the indexed points) is an aggregate of the numbers the run stored
//        and its CSV holds, never a second run.
//
//        A new product of the program is one more `Kind` and one more builder in the ledger; the report's sections take it by its kind
//        (the Maps room's grain statistics and texture joined so, macTEM#242).
//

import Foundation

/// A name and the text shown beside it: a parameter, a count, a fact of a file.
package nonisolated struct SEMSessionField: Sendable, Equatable, Hashable {
    package var name: String
    package var value: String

    package init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// One Output line a room logged, with the moment it was logged.
package nonisolated struct SEMLogLine: Sendable, Equatable {
    package var time: Date
    package var text: String

    package init(time: Date, text: String) {
        self.time = time
        self.text = text
    }
}

package nonisolated struct SEMSessionRow: Sendable, Equatable, Identifiable {
    /// What a row is; the Results room groups by it in this order, the report puts each in its section.
    package enum Kind: String, Sendable, Equatable, CaseIterable {
        case dataset, processing, scanMaps, indexing, orientationMap, grains, texture, composition, export

        /// The group's title in the Results room.
        package var title: String {
            switch self {
            case .dataset: "SEM data"
            case .processing: "Pattern processing"
            case .scanMaps: "Scan maps"
            case .indexing: "Indexing"
            case .orientationMap: "Orientation maps"
            case .grains: "Grains"
            case .texture: "Texture"
            case .composition: "SEM-EDS composition"
            case .export: "Exports"
            }
        }

        /// The room that made the row and where it is changed (the Results room changes nothing).
        package var room: String {
            switch self {
            case .dataset, .processing, .scanMaps: "Patterns"
            case .indexing: "Indexing"
            case .orientationMap, .grains, .texture: "Maps"
            case .composition: "EDS"
            case .export: "the room named in Source"
            }
        }
    }

    /// Stable while the product stands: "dataset", "processing", "indexing", "export:3".
    package let id: String
    package let kind: Kind
    /// The Result column: "patterns_v2.h5", "Hough indexing", "patterns_v2 indexed IPF-Z.png".
    package let label: String
    /// The Value column: the one line the room shows for it.
    package let value: String
    /// The Source column: the room and the file it was made from, "Indexing · patterns_v2.h5".
    package let source: String
    /// When it was made: the Output line that said so, or the export's moment; nil when the session did not log one.
    package let time: Date?
    /// Its parameters and numbers in the room's words (the Info tab, the report's tables).
    package let fields: [SEMSessionField]
    /// The methods that made it, in order (the Method column names the first; the report cites them all).
    package let methods: [SEMMethod]
    /// The file it was read from (a dataset, a map) or written to (an export).
    package let file: URL?
    /// The picture an export wrote (a PNG), drawn into the report.
    package let figure: SEMReportFigure?
    /// The Output lines the run logged, in order.
    package let log: [SEMLogLine]

    package init(id: String, kind: Kind, label: String, value: String, source: String, time: Date? = nil, fields: [SEMSessionField] = [],
                 methods: [SEMMethod] = [], file: URL? = nil, figure: SEMReportFigure? = nil, log: [SEMLogLine] = []) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.source = source
        self.time = time
        self.fields = fields
        self.methods = methods
        self.file = file
        self.figure = figure
        self.log = log
    }

    /// The Method column: the first method's short name, or what an export is.
    package var methodTitle: String { methods.first?.title ?? (kind == .export ? "Export" : "Read") }
}
