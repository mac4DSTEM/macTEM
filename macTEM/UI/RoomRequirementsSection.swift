//
//  RoomRequirementsSection.swift
//  Role: the Requirements section at the top of a room's Settings tab (mac4DSTEM's `RequirementsSection`, macTEM#396): each thing the
//        room's verb waits for, an orange status icon and its sentence, where in the room it is fixed, and a button when the fix is in
//        another room. Absent when nothing is missing. The rows are `RoomRequirements.unmet`, the toolbar verb's own blockers.
//

import ShellInspector
import SwiftUI

struct RoomRequirementsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let unmet = RoomRequirements.unmet(appState)
        if !unmet.isEmpty {
            InspectorSection("Requirements") {
                ForEach(unmet) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        InspectorWarning(item.title, systemImage: "exclamationmark.circle.fill", font: .subheadline)
                        if let hint = item.hint {
                            InspectorNote(hint)
                                .accessibilityIdentifier("requirement.\(item.id).hint")
                        }
                        if let room = item.opens {
                            InspectorActionRow {
                                Button("Open \(room.title)") { appState.selectWorkspace(room) }
                                    .help("Go to the \(room.title) room")
                                    .accessibilityIdentifier("requirement.\(item.id).action")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("requirement.\(item.id)")
                }
            }
            .accessibilityIdentifier("requirements")
        }
    }
}
