//
//  ResultsRoomState.swift
//  Role: the Results room's own state (V1-10 slice 3, archive: results-room-design-2026-10-15.md, section 4): which rows are
//        selected and which groups are shown. Window-wide and not saved; composed by `AppState` as `ImageRoomTools` is. The
//        room has no data of its own: the rows are `ResultsLedger`'s, derived from the file's owners on every read, and this
//        holds only ids (`ResultRow.id`, stable while a measurement stands).
//
//        A FILE SWITCH resets the selection (`attach`); a row that has gone (a mark removed, a spot cleared) simply no
//        longer matches, and the Info tab says so by showing nothing selected.
//

import Foundation
import Observation
import TEMCore

/// One group of the table: its rows, in the ledger's order.
struct ResultsSection: Identifiable {
    let group: ResultRow.Group
    let rows: [ResultRow]

    var id: ResultRow.Group { group }
}

@Observable
final class ResultsRoomState {
    /// The selected rows' ids (a Table's own selection; ⌘C copies them).
    var selection: Set<ResultRow.ID> = []
    /// The groups the table lists; all of them until the user switches one off.
    var shownGroups = Set(ResultRow.Group.allCases)
    /// The file the selection belongs to.
    @ObservationIgnored private(set) var fileID: UUID?

    /// The room shows file `id`: a different file than before clears the selection.
    func attach(to id: UUID?) {
        guard id != fileID else { return }
        fileID = id
        selection = []
    }

    func isShown(_ group: ResultRow.Group) -> Bool { shownGroups.contains(group) }

    func setShown(_ group: ResultRow.Group, _ on: Bool) {
        if on { shownGroups.insert(group) } else { shownGroups.remove(group) }
    }

    /// The rows of the shown groups, in the ledger's order.
    func visible(_ rows: [ResultRow]) -> [ResultRow] { rows.filter { shownGroups.contains($0.group) } }

    /// The visible rows by group, in the order of `ResultRow.Group.allCases`, empty groups left out.
    func sections(_ rows: [ResultRow]) -> [ResultsSection] {
        ResultRow.Group.allCases.compactMap { group in
            guard shownGroups.contains(group) else { return nil }
            let inGroup = rows.filter { $0.group == group }
            return inGroup.isEmpty ? nil : ResultsSection(group: group, rows: inGroup)
        }
    }

    /// The row the Info tab describes: the one selected row, when exactly one is selected, still in the ledger and in a shown group
    /// (a row the table does not list is not described).
    func selected(in rows: [ResultRow]) -> ResultRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return visible(rows).first { $0.id == id }
    }

    /// The selected rows that are still there and shown, in the ledger's order.
    func selectedRows(in rows: [ResultRow]) -> [ResultRow] { visible(rows).filter { selection.contains($0.id) } }
}
