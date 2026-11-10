// macTEM's rooms, in the shape of mac4DSTEM's `WorkspaceArea`, conforming to the shell's `WorkspaceRoom`. Added (EDX room, owner 2026-10-21): a sixth room, `edx`, last so ⌘1…⌘5 keep their rooms. Added (EELS room, 2026-10-21): a seventh, `eels`, after it (⌘7).
// Added (SEM program, 2026-11-06, design D1): `patterns` before Results, so Results moves to ⌘7 now and to ⌘9 once Indexing and Maps are built.
// Added (SEM program, 2026-11-07, D-SEM-84): `indexing` after Patterns (⌘7); Results keeps ⌘9 from here on, the digit the Maps room leaves it.
// Added (P3-04, 2026-11-07, D-SEM-80): `maps` after Indexing (⌘8), Results keeps ⌘9.
// Changed (2026-11-10, Paul): the rooms are grouped into five workspaces (`WorkspaceGroup`) as mac4DSTEM's are; ⌘1…⌘5 go to the
// workspaces, and a room is reached as a part under its workspace.
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
    case indexing
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
        case .indexing: "Indexing"
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
        case .indexing: "Hough indexing of the scan: orientation maps, the solution at each point and its bands"
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
        case .indexing: "scope"
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

    /// The workspace this room is a part of (`WorkspaceGroup`): the sidebar lists the workspaces and, under the one in front, its parts.
    var group: WorkspaceGroup {
        switch self {
        case .image, .fft: .imaging
        case .edx, .eels: .spectroscopy
        case .diffraction: .diffraction
        case .patterns, .indexing, .maps: .ebsd
        case .results: .results
        }
    }
}

/// The sidebar's workspaces, in mac4DSTEM's shape (its Crystal Maps lists Strain, Orientation and Phase mapping under it): one row per
/// technique, ⌘1…⌘5 in list order, and the one in front lists its parts (the rooms, `WorkspaceArea`) in a section of its own. A
/// workspace of one room (Diffraction, Results) is that room, as mac4DSTEM's Prepare is. The rooms keep their content and their
/// identifiers (`workspace.<room>`); the workspaces only group them. Order: looking, then the spectra, then diffraction (Paul,
/// 2026-10-22), then the SEM work, Results last. Paul, 2026-11-10: "isnt this all part of ebsd" (Patterns, Indexing, Maps).
nonisolated enum WorkspaceGroup: String, CaseIterable, Identifiable, Sendable, WorkspaceRoom {
    case imaging
    case spectroscopy
    case diffraction
    case ebsd
    case results

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imaging: "Imaging"
        case .spectroscopy: "Spectroscopy"
        case .diffraction: "Diffraction"
        case .ebsd: "EBSD"
        case .results: "Results"
        }
    }

    var subtitle: String {
        switch self {
        case .imaging: "TEM and SEM images and their Fourier transform"
        case .spectroscopy: "EDS and EELS spectra and spectrum images"
        case .diffraction: WorkspaceArea.diffraction.subtitle
        case .ebsd: "EBSD and TKD: patterns, indexing and orientation maps"
        case .results: WorkspaceArea.results.subtitle
        }
    }

    var symbolName: String {
        switch self {
        case .imaging: "photo"
        case .spectroscopy: "waveform.path.ecg"
        case .diffraction: WorkspaceArea.diffraction.systemImage
        case .ebsd: "square.grid.3x3.square"
        case .results: WorkspaceArea.results.systemImage
        }
    }

    /// The rooms of this workspace, in the order the work goes.
    var parts: [WorkspaceArea] { WorkspaceArea.allCases.filter { $0.group == self } }

    /// Whether the sidebar lists the parts under it: a workspace of one room is that room.
    var hasParts: Bool { parts.count > 1 }

    /// The Go to <workspace> shortcut, ⌘1…⌘5 in list order. Derived, so the menu and the list cannot disagree.
    var shortcutDigit: Character { Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)) }
}

/// The navigation/selection seam: which room the user is in and which panes are visible — pure view-state,
/// no science. `AppState` holds it as `navigation` without forwarding properties. Orchestration stays on
/// `AppState` (`selectWorkspace`); this type only stores the answer. The panes (the process area and its fraction,
/// the sidebar and inspector intent, the width collapse) are ShellLayout's `PanelNavigation` (suite task 8, MacEMUI),
/// held as `panels`; the room is this app's.
@Observable
final class WorkspaceNavigation {
    var workspaceArea: WorkspaceArea = .image {
        didSet { lastRoom[workspaceArea.group] = workspaceArea }
    }

    /// The room each workspace was last in, so Go to EBSD comes back to Maps when Maps was where the person left it.
    @ObservationIgnored private(set) var lastRoom: [WorkspaceGroup: WorkspaceArea] = [:]

    /// The panes: the process area (Output), the sidebar and the inspector.
    let panels = PanelNavigation()
}
