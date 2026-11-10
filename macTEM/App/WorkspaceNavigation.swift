// macTEM's rooms, in the shape of mac4DSTEM's `WorkspaceArea`, conforming to the shell's `WorkspaceRoom`. Added (EDX room, owner 2026-10-21): a sixth room, `edx`, last so ⌘1…⌘5 keep their rooms. Added (EELS room, 2026-10-21): a seventh, `eels`, after it (⌘7).
// Added (SEM program, 2026-11-06, design D1): `patterns` before Results, so Results moves to ⌘7 now and to ⌘9 once Indexing and Maps are built.
// Added (SEM program, 2026-11-07, D-SEM-84): `indexing` after Patterns (⌘7); Results keeps ⌘9 from here on, the digit the Maps room leaves it.
// Added (P3-04, 2026-11-07, D-SEM-80): `maps` after Indexing (⌘8), Results keeps ⌘9.
// Changed (2026-11-10, Paul): the rooms are grouped into five workspaces (`WorkspaceGroup`) as mac4DSTEM's are; ⌘1…⌘5 go to the
// workspaces, and a room is reached as a part under its workspace.
// Added (2026-11-08): `DocumentTarget`, the document the room shows, which File > Close (⌘W) and Show in Finder act on.
import Foundation
import ShellEDXModel
import ShellLayout
import SpectroCore
import SwiftUI
import TEMSession

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

/// The document the room shows, which File > Close (⌘W) and Show in Finder act on: the selected image in the image rooms, the
/// Patterns room's dataset in Patterns and Indexing (Indexing runs on it), the map in Maps, the spectrum image in EDS and EELS. ⌘W
/// acted on the selected image in every room before, so in Maps it closed an image that was not shown and the dataset, the map or the
/// spectrum image could never be closed. Pure, so a test pins it.
nonisolated enum DocumentTarget: Equatable, Sendable {
    case image
    case ebsdDataset
    case orientationMap
    case eds
    case eels

    /// What `area` shows, given what the window holds; nil when it shows nothing (⌘W then closes the window, as the system's would).
    static func of(area: WorkspaceArea, hasImage: Bool, hasDataset: Bool, hasMap: Bool, hasEDS: Bool, hasEELS: Bool) -> DocumentTarget? {
        switch area {
        case .image, .fft, .diffraction, .results: return hasImage ? .image : nil
        case .patterns, .indexing: return hasDataset ? .ebsdDataset : nil
        case .maps: return hasMap ? .orientationMap : nil
        case .edx: return hasEDS ? .eds : nil
        case .eels: return hasEELS ? .eels : nil
        }
    }

    /// The File menu's ⌘W item for it.
    var closeTitle: String {
        switch self {
        case .image: "Close Image"
        case .ebsdDataset: "Close Dataset"
        case .orientationMap: "Close Map"
        case .eds, .eels: "Close Spectrum Image"
        }
    }
}

/// What File > Close (⌘W) and Close Window (⇧⌘W) act on, from the window that is key. The File menu's Close is replaced (it closes
/// the document the room shows), so a window the replacement did not know of could not be closed from the keyboard: the Objects
/// window (`ParticleTableWindow`), which holds no document, is now closed by both while it is key, as the system's Close would. In
/// the image window ⌘W closes the document the room shows (`DocumentTarget`), or the window when it shows none, and ⇧⌘W the window.
/// With no macTEM window key neither acts. Pure, so a test pins it.
nonisolated enum CloseCommand: Equatable, Sendable {
    case document(DocumentTarget)
    case imageWindow
    case objectsWindow
    case unavailable

    /// File > Close (⌘W).
    static func close(objectsWindowKey: Bool, imageWindowFocused: Bool, shown: DocumentTarget?) -> CloseCommand {
        if objectsWindowKey { return .objectsWindow }
        guard imageWindowFocused else { return .unavailable }
        if let shown { return .document(shown) }
        return .imageWindow
    }

    /// File > Close Window (⇧⌘W).
    static func closeWindow(objectsWindowKey: Bool, imageWindowFocused: Bool) -> CloseCommand {
        if objectsWindowKey { return .objectsWindow }
        return imageWindowFocused ? .imageWindow : .unavailable
    }

    /// The ⌘W item's title: the document's ("Close Image", "Close Dataset", …), else "Close".
    var closeTitle: String {
        if case .document(let target) = self { return target.closeTitle }
        return "Close"
    }
}

extension AppState {
    /// The document the room shows (`DocumentTarget.of`), nil when it shows none.
    var documentTarget: DocumentTarget? {
        DocumentTarget.of(area: navigation.workspaceArea, hasImage: openItems.selected != nil, hasDataset: ebsd.hasDataset,
                          hasMap: maps.hasMap, hasEDS: edx.hasImage, hasEELS: eels.hasImage)
    }

    /// Show in Finder's file: the shown document's (an Indexing run handed to Maps is the dataset's), nil when it has none (a generated demo).
    var documentURL: URL? {
        guard let target = documentTarget else { return nil }
        switch target {
        case .image: return openItems.selected.map(\.url).flatMap { DemoDocuments.isDemo($0) ? nil : $0 }
        case .ebsdDataset: return ebsd.document?.url
        case .orientationMap: return maps.document?.url
        case .eds: return Self.fileURL(path: edx.source?.metadata.filePath ?? "")
        case .eels: return Self.fileURL(path: eels.filePath)
        }
    }

    /// ⌘W on `target`: the selected image through `requestClose` (unsaved marks ask first); the Patterns room's dataset, with the
    /// Indexing room's run and the dataset's maps (`ebsd.onClose`); every map the Maps room holds; the spectrum image, with the SEM
    /// line table read from it. The room then gives way to one with data (`reconcileRoom`).
    func closeDocument(_ target: DocumentTarget) {
        switch target {
        case .image: requestCloseSelected()
        case .ebsdDataset: ebsd.close()
        case .orientationMap: maps.close()
        case .eds:
            edx.close()
            Task { await semEDS.load(path: nil) }
        case .eels: eels.close()
        }
    }

    /// A reader's path as a file URL; nil for "" (a document made in memory).
    private static func fileURL(path: String) -> URL? {
        path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
