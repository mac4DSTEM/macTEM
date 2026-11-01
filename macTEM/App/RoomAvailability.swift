//
//  RoomAvailability.swift
//  Role: which rooms the window's documents fill. The FILE decides, not the room the person is in (`FileInventory`): once anything is
//        open, a room with data for it is enabled, and every other is disabled with a one-line reason; with nothing open every built room
//        stays enterable (the welcome canvas and the rooms' own Open buttons). Switching rooms never reloads or drops data: the sessions
//        (`OpenItems`, `edx`, `eels`) are the window's, not the room's.
//

import Foundation
import TEMCore
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
    /// Every open image is the HAADF (or another image) of a spectrum-image file: a scan image, never a diffraction pattern.
    var imagesAreSpectrumCompanions = false

    var hasDocument: Bool { images || eds || eels }
}

nonisolated enum RoomAvailability {
    /// Why `area` cannot be entered now, or nil when it can.
    static func reason(_ area: WorkspaceArea, holdings: RoomHoldings) -> String? {
        guard area.isBuilt else { return "Not built yet" }
        guard holdings.hasDocument else { return nil }
        switch area {
        case .edx: return holdings.eds ? nil : "No file open holds an EDS spectrum image"
        case .eels: return holdings.eels ? nil : "No file open holds an EELS spectrum image"
        case .diffraction:
            guard holdings.images else { return "No file open holds an image" }
            return holdings.imagesAreSpectrumCompanions ? "The open images belong to a spectrum image, not a diffraction pattern" : nil
        case .image, .fft, .results: return holdings.images ? nil : "No file open holds an image"
        }
    }

    /// The room to be in when the one shown has just lost its data: the first that can be entered, in list order.
    static func fallback(holdings: RoomHoldings) -> WorkspaceArea? {
        WorkspaceArea.allCases.first { reason($0, holdings: holdings) == nil }
    }
}

extension AppState {
    var roomHoldings: RoomHoldings {
        RoomHoldings(images: !openItems.items.isEmpty,
                     eds: edx.hasImage || edx.isOpening,
                     eels: eels.hasImage || eels.isOpening,
                     imagesAreSpectrumCompanions: !openItems.items.isEmpty && openItems.items.allSatisfy { spectrumCompanionImages.contains($0.url) })
    }

    func roomUnavailableReason(_ area: WorkspaceArea) -> String? {
        RoomAvailability.reason(area, holdings: roomHoldings)
    }

    /// A room that has lost its data (the last image closed while in FFT, a spectrum image closed) gives way to one that has some.
    func reconcileRoom() {
        let holdings = roomHoldings
        guard RoomAvailability.reason(navigation.workspaceArea, holdings: holdings) != nil,
              let next = RoomAvailability.fallback(holdings: holdings) else { return }
        navigation.workspaceArea = next
    }
}
