//
//  AgentSettingsView.swift
//  Role: macTEM's Settings window (⌘,), which has one pane so far: Agents, the agent door's switch (`MacTEMAgentDoor`). The
//        section itself is MacEMUI's (`AgentDoorSettingsSection`), the same in both apps; this view keeps the preference and
//        opens or closes the door when it changes.
//

import ShellAgentDoor
import SwiftUI

struct AgentSettingsView: View {
    @AppStorage(MacTEMAgentDoor.enabledKey) private var enabled = false

    var body: some View {
        Form {
            AgentDoorSettingsSection(door: MacTEMAgentDoor.shared, isOn: $enabled,
                                     canSee: "the open files, the image as Export Image draws it, the results and the Output lines")
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { _, now in MacTEMAgentDoor.shared.setEnabled(now) }
        .accessibilityIdentifier("settings.agents")
    }
}
