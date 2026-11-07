// macTEM's rooms, in the shape of mac4DSTEM's `WorkspaceArea`, conforming to the shell's `WorkspaceRoom`. Added (EDX room, owner 2026-10-21): a sixth room, `edx`, last so ⌘1…⌘5 keep their rooms. Added (EELS room, 2026-10-21): a seventh, `eels`, after it (⌘7).
// Added (SEM program, 2026-11-06, design D1): `patterns` before Results, so Results moves to ⌘7 now and to ⌘9 once Indexing and Maps are built.
// Added (P3-04, 2026-11-07): `maps` after Patterns, where Indexing will sit before it; Maps and Results take the plan's fixed keys ⌘8 and
// ⌘9 now, ⌘7 waits for Indexing (D-SEM-80).
import ShellLayout
import SwiftUI

/// The six rooms 1.0 ships, in the order the work goes: the image, its transform, the spectrum images, the diffraction pattern,
/// the numbers. Prepare (calibration, stacks and alignment) was listed unbuilt until 1.0 and is gone (the owner, 2026-10-23).
nonisolated enum WorkspaceArea: String, CaseIterable, Identifiable, Sendable, WorkspaceRoom {
    case image
    case fft
    case edx
    case eels
    case diffraction
    case patterns
    case maps
    case results

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Image"
        case .fft: "FFT"
        case .diffraction: "Diffraction"
        case .results: "Results"
        case .edx: "EDS"
        case .eels: "EELS"
        case .patterns: "Patterns"
        case .maps: "Maps"
        }
    }

    var subtitle: String {
        switch self {
        case .image: "The calibrated image: contrast, distances, angles and profiles"
        case .fft: "Fourier transform, live FFT on a region, radial profile"
        case .diffraction: "Camera length, d-spacings, indexing and zone axis"
        case .results: "Review and export the numbers"
        case .edx: "Spectrum images: elements, maps, spectrum and composition"
        case .eels: "Low-loss spectrum images: thickness (t/λ) maps"
        case .patterns: "EBSD and TKD patterns: the scan, its mean-intensity map and the live pattern"
        case .maps: "Orientation maps: IPF and phase maps, the colour key and the pattern or unit cell at each point"
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .fft: "circle.grid.3x3"
        case .diffraction: "circle.dotted"
        case .results: "square.grid.2x2"
        case .edx: "waveform.path.ecg"
        case .eels: "chart.xyaxis.line"
        case .patterns: "square.grid.3x3.square"
        case .maps: "map"
        }
    }

    /// The shell's name for `systemImage` (`WorkspaceRoom`).
    var symbolName: String { systemImage }

    /// `WorkspaceRoom`: a room that is not built is listed dimmed and cannot be selected.
    var isAvailable: Bool { isBuilt }

    /// Whether the room exists yet. A room that is not built is listed, so the window shows where the app is
    /// going, and cannot be entered.
    var isBuilt: Bool { true }

    /// The Go to <room> shortcut: ⌘1…⌘6 in list order up to Patterns, then the SEM plan's fixed keys (D-SEM-80): Indexing ⌘7 (its
    /// room is the next to land), Maps ⌘8, Results ⌘9, so the keys do not move again when Indexing arrives.
    var shortcutDigit: Character {
        switch self {
        case .maps: "8"
        case .results: "9"
        default: Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))
        }
    }
}

/// The navigation/selection seam: which room the user is in and which panes are visible — pure view-state,
/// no science. `AppState` holds it as `navigation` without forwarding properties. Orchestration stays on
/// `AppState` (`selectWorkspace`); this type only stores the answer. The panes (the process area and its fraction,
/// the sidebar and inspector intent, the width collapse) are ShellLayout's `PanelNavigation` (suite task 8, MacEMUI),
/// held as `panels`; the room is this app's.
@Observable
final class WorkspaceNavigation {
    var workspaceArea: WorkspaceArea = .image

    /// The panes: the process area (Output), the sidebar and the inspector.
    let panels = PanelNavigation()
}
