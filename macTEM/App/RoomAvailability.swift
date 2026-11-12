//
//  RoomAvailability.swift
//  Role: which rooms the window's documents fill. The FILE decides, not the room the person is in (`FileInventory`): once anything is
//        open, a room with data for it is enabled, and every other is disabled with a one-line reason; with nothing open every room
//        stays enterable (the welcome canvas and the rooms' own Open buttons). Switching rooms never reloads or drops data: the sessions
//        (`OpenItems`, `edx`, `eels`, `ebsd`, `maps`) are the window's, not the room's.
//

import Foundation
import TEMSession
import ShellEDXModel

/// What the window holds, as plain values.
nonisolated struct RoomHoldings: Equatable, Sendable {
    /// Open files with an image to draw (the Image, FFT, Diffraction and Results rooms).
    var images = false
    /// A spectrum image, or one opening, in the EDS room.
    var eds = false
    /// A spectrum image, or one opening, in the EELS room.
    var eels = false
    /// An EBSD or TKD pattern dataset, or one opening, in the Patterns room (the Indexing room reads the same dataset).
    var ebsd = false
    /// An orientation map (an `.ang`, `.ctf`, map-only `.h5oina` or orix `.h5` alone, or an EBSD dataset's crystal map), or one opening, in the Maps room.
    var maps = false
    /// Every open image is the HAADF (or another image) of a spectrum-image file: a scan image, never a diffraction pattern.
    var imagesAreSpectrumCompanions = false
    /// The SEM rooms hold something the Results room lists (a pattern dataset, an orientation map, an SEM spectrum's line table): the
    /// Results room's session rows and report (D-SEM-103), with or without an image.
    var semResults = false

    var hasDocument: Bool { images || eds || eels || ebsd || maps }
}

nonisolated enum RoomAvailability {
    /// Why `area` cannot be entered now, or nil when it can.
    static func reason(_ area: WorkspaceArea, holdings: RoomHoldings) -> String? {
        guard holdings.hasDocument else { return nil }
        switch area {
        case .edx: return holdings.eds ? nil : "No file open holds an EDS spectrum image"
        case .eels: return holdings.eels ? nil : "No file open holds an EELS spectrum image"
        case .patterns, .indexing: return holdings.ebsd ? nil : "No file open holds EBSD patterns"
        case .maps: return holdings.maps ? nil : "No file open holds an orientation map"
        case .diffraction:
            guard holdings.images else { return "No file open holds an image" }
            return holdings.imagesAreSpectrumCompanions ? "The open images belong to a spectrum image, not a diffraction pattern" : nil
        case .results: return holdings.images || holdings.semResults ? nil : "No file open holds an image or an SEM result"
        case .image, .fft: return holdings.images ? nil : "No file open holds an image"
        }
    }

    /// The room to be in when the one shown has just lost its data: the first that can be entered, in list order.
    static func fallback(holdings: RoomHoldings) -> WorkspaceArea? {
        WorkspaceArea.allCases.first { reason($0, holdings: holdings) == nil }
    }
}

/// The documents the process area (the Output pane) sits under, as plain values: an image that is open and read, the EDS and EELS
/// rooms' spectrum images, the Patterns room's dataset (the Indexing room reads it too) and the Maps room's map.
nonisolated struct ProcessAreaDocuments: Equatable, Sendable {
    var image = false
    var eds = false
    var eels = false
    var dataset = false
    var map = false

    /// Whether the process area has a document to sit under in `room`: the room's own document (a spectrum image, the dataset or the
    /// map, which need no open image; alignment design: Output is available there too), else an image. The pane opens on it and
    /// View > Show Output (⌃⌘L) is on with it, so the menu item is never dimmed where the pane works (mac4DSTEM's one rule for both).
    func has(in room: WorkspaceArea) -> Bool {
        switch room {
        case .edx: eds
        case .eels: eels
        case .patterns, .indexing: dataset
        case .maps: map
        case .image, .fft, .diffraction, .results: image
        }
    }
}

extension AppState {
    /// What the process area sits under now. An image still loading is none: the area is shut while it loads.
    var processAreaDocuments: ProcessAreaDocuments {
        ProcessAreaDocuments(image: hasImage && !imageSession.isLoading, eds: edx.hasImage, eels: eels.hasImage,
                             dataset: ebsd.hasDataset, map: maps.hasMap)
    }

    /// Whether the process area has a document to sit under in the room shown: the pane's rule (`WorkspaceView`) and View > Show
    /// Output's.
    var processAreaHasDocument: Bool { processAreaDocuments.has(in: navigation.workspaceArea) }

    var roomHoldings: RoomHoldings {
        RoomHoldings(images: !openItems.items.isEmpty,
                     eds: edx.hasImage || edx.isOpening,
                     eels: eels.hasImage || eels.isOpening,
                     ebsd: ebsd.hasDataset || ebsd.isOpening,
                     maps: maps.hasMap || maps.isOpening,
                     imagesAreSpectrumCompanions: !openItems.items.isEmpty && openItems.items.allSatisfy { spectrumCompanionImages.contains($0.url) },
                     semResults: SEMSessionLedger.hasRows(self))
    }

    func roomUnavailableReason(_ area: WorkspaceArea) -> String? {
        RoomAvailability.reason(area, holdings: roomHoldings)
    }

    /// Why no room of `group` can be entered now (the first room's reason), or nil when one can.
    func workspaceUnavailableReason(_ group: WorkspaceGroup) -> String? {
        group.parts.contains { roomUnavailableReason($0) == nil } ? nil : group.parts.first.flatMap(roomUnavailableReason)
    }

    /// A room that has lost its data (the last image closed while in FFT, a spectrum image closed) gives way to one that has some.
    func reconcileRoom() {
        let holdings = roomHoldings
        guard RoomAvailability.reason(navigation.workspaceArea, holdings: holdings) != nil,
              let next = RoomAvailability.fallback(holdings: holdings) else { return }
        navigation.workspaceArea = next
    }
}
