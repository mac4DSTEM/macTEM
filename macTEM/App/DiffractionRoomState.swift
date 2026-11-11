//
//  DiffractionRoomState.swift
//  Role: the Diffraction room's own state for the window: the status line's readout over the pattern. Window-wide and not
//        saved; composed by `AppState` as `ImageRoomTools` is. The pattern's view state (the tool, the zoom, the display) is
//        each open file's own (`DiffractionViewState`, TEMSession), beside its results (`DiffractionAnalysis`).
//

import Foundation
import Observation

@Observable
final class DiffractionRoomState {
    /// The status line's readout over the diffraction pattern (`DiffractionReadoutText`); nil when the pointer is elsewhere.
    var readout: String?
}
