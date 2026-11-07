//
//  IndexingSimulationOverlay.swift
//  Role: the Indexing room's Simulation section (docs/sem/design/simulation-overlay.md §3, after the method's section and before
//        Export, closed by default; #201): the overlay of the run's solution over the pattern as indexed, on or off, with the
//        settings the Patterns room's Simulation section shares (Min d, Band width, Zone axes, Labels, Kinematical and Blend). The layer
//        is `KikuchiOverlayLayer` (PatternsSimulationOverlay.swift) in the pattern pane; the numbers are
//        `IndexingSession.simulationOverlay`'s (TEMSession).
//

import SwiftUI
import TEMCore
import TEMSession

struct IndexingSimulationSection: View {
    let session: IndexingSession

    private var summary: String? {
        guard session.showsSimulation, let overlay = session.simulationOverlay else { return nil }
        switch overlay {
        case .success(let p):
            return "\(p.phase): \(p.simulation.lines.count) bands, \(p.simulation.zoneAxes.count) zone axes on this pattern, from the run's solution here and its mean projection centre."
        case .failure(let absence):
            return absence.sentence + " at this point."
        }
    }

    var body: some View {
        let patterns = session.patterns
        SimulationOverlayControls(prefix: "indexing", isOn: session.showsSimulation, setOn: { session.showsSimulation = $0 },
                                  settings: patterns.overlaySettings, setSettings: { patterns.setOverlaySettings($0) },
                                  canOverlay: session.result != nil, canDrawBandWidth: patterns.canDrawBandWidth, masterPicture: nil,
                                  unavailable: "Index the scan first: the overlay draws the run's solution at each point.",
                                  summary: summary)
    }
}
