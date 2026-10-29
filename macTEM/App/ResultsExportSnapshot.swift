//
//  ResultsExportSnapshot.swift
//  Role: what Export Results… takes from the selected file when its panel opens (V1-10 slice 3, archive: results-room-design-
//        2026-10-15.md, section 5): every finished measurement as `ResultRow`s (`ResultsLedger`, ALL groups: the Show switches
//        filter the table, not the file), the file's source as the file states it, the session sentence, the name and the
//        words. As `ExportSnapshot` does for the other rooms: a Sendable value taken once; the write that follows runs off the
//        main actor on it, through the one hand-over `write(to:)` that the panel only calls.
//

import Foundation
import TEMCore
import TEMSession

/// Everything Export Results… needs.
nonisolated struct ExportResultsSnapshot: Sendable {
    let rows: [ResultRow]
    let source: ExportSource
    /// The Image room's state line for the file's marks ("Not saved…", "Saved at 14:03…").
    let session: String
    let defaultName: String
    let directory: URL?
    let message: String

    nonisolated func write(to url: URL) async throws {
        try await ResultsCSV.export(rows, source: source, session: session, to: url)
    }
}

extension SessionTailInput {
    /// The tail's input from the file's own owners: one place, for the Image room's tail and for the Results room's sentence.
    init(item: OpenItem) {
        let measurements = item.measurements
        self.init(fileName: item.sessionFileName, sidecar: measurements.sidecar, notes: measurements.notes,
                  needsAccess: item.sidecarNeedsAccess,
                  newerVersion: measurements.lineage.isReadOnly ? measurements.lineage.fileVersion : nil,
                  hasMarks: !measurements.marks.isEmpty, isDirty: measurements.isDirty, canSave: item.canSave,
                  isSaving: item.isSaving, savedAt: item.lastSavedAt, recording: measurements.recordingRefusal)
    }
}

extension ExportSnapshot {
    /// The sentence that says where the file's marks are kept: the first line of the Image room's tail, else the Results
    /// room's own words for a file with no mark.
    static func sessionSentence(of item: OpenItem) -> String {
        ResultsFormat.session(firstLine: SessionFormat.tail(SessionTailInput(item: item)).lines.first?.text)
    }

    /// Export Results… for a file's owners; nil when it has no finished measurement or no pixels.
    static func resultsSnapshot(of item: OpenItem, software: String = softwareName()) -> ExportResultsSnapshot? {
        guard let image = item.session.image else { return nil }
        let rows = ResultsLedger.rows(of: item)
        guard !rows.isEmpty else { return nil }
        let groups = ResultRow.Group.allCases.filter { group in rows.contains { $0.group == group } }
        return ExportResultsSnapshot(
            rows: rows, source: ExportSource(image: image, software: software), session: sessionSentence(of: item),
            defaultName: ResultsFormat.exportName(fileName: image.fileName),
            directory: item.url.deletingLastPathComponent(),
            message: ResultsFormat.exportMessage(rows: rows.count, groups: groups))
    }

    /// The window's selected item's: an export is of the file on screen, never of another open one.
    static func resultsSnapshot(in openItems: OpenItems, software: String = softwareName()) -> ExportResultsSnapshot? {
        openItems.selected.flatMap { resultsSnapshot(of: $0, software: software) }
    }
}
