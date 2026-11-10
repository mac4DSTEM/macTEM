//
//  RoomRequirements.swift
//  Role: what the shown room's verb still waits for, as the inspector's Requirements section lists it (mac4DSTEM's `RequirementsSection`,
//        macTEM#396). Each row is read from the same blocker that disables the toolbar verb (`RoomPrimaryAction`), so the list can never
//        disagree with the gate. A room that is busy, opening or has nothing open lists nothing: running is not a requirement, and an
//        empty room's inspector already says what to open.
//

import TEMCore
import TEMSession

/// One thing the room's verb waits for: the sentence, where in this room it is fixed, and the room to open when the fix is elsewhere.
nonisolated struct RoomRequirement: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var hint: String?
    var opens: WorkspaceArea?
}

enum RoomRequirements {
    @MainActor
    static func unmet(_ appState: AppState) -> [RoomRequirement] {
        switch appState.navigation.workspaceArea {
        case .patterns:
            let session = appState.ebsd
            guard session.hasDataset, !session.isBusy, let refusal = session.processingRefusal else { return [] }
            return [RoomRequirement(id: "patterns.process", title: refusal.sentence, hint: "Set under \(refusal.stage.title).")]
        case .indexing:
            let session = appState.indexing
            guard session.hasDataset, !session.patterns.isOpening, !session.isIndexing else { return [] }
            if session.patterns.isProcessing {
                return [RoomRequirement(id: "indexing.processing", title: "The Patterns room is processing the scan; Index waits for it.",
                                        opens: .patterns)]
            }
            guard let refusal = session.refusal else { return [] }
            return [RoomRequirement(id: "indexing.index", title: refusal)]
        case .maps:
            let session = appState.maps
            guard session.hasMap, !session.isBusy, let blocker = session.segmentBlocker else { return [] }
            return [RoomRequirement(id: "maps.segment", title: blocker)]
        case .eels:
            let session = appState.eels
            guard session.hasImage, !session.isBusy, let blocker = session.fitBlocker else { return [] }
            return [RoomRequirement(id: "eels.fit", title: blocker, hint: "Fit runs once this is done; the other stages run without it.")]
        default:
            return []
        }
    }
}
