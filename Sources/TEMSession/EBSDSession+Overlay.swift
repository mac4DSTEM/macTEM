//
//  EBSDSession+Overlay.swift
//  Role: the Patterns room's simulation overlay (docs/sem/design/simulation-overlay.md §2, §4): on or off, its settings, and the
//        geometrical Kikuchi simulation of the shown pattern's orientation (`KikuchiOverlay`, TEMCore). The overlay follows the pattern
//        pane: the position whose pattern is on screen (the hovered one while the pointer is on the map), so a grain boundary shows as the
//        bands jumping. One position's simulation is well under a millisecond in release; the last one is kept, the bands per phase
//        and the scan's r_max per dataset.
//

import Foundation
import TEMCore

extension EBSDSession {
    /// Turns the overlay on or off.
    package func setOverlayOn(_ on: Bool) {
        overlayOn = on
    }

    /// New settings; a new minimum spacing remakes the bands.
    package func setOverlaySettings(_ settings: KikuchiOverlay.Settings) {
        if settings.minDSpacing != overlaySettings.minDSpacing { overlayBands = [:]; overlayMemo = nil }
        overlaySettings = settings
    }

    /// Whether the dataset carries orientations the overlay can draw.
    package var canOverlay: Bool { dataset?.crystalMap != nil }

    /// The overlay at the pattern on screen while it is on, or why there is none; nil while it is off or before a pattern shows.
    package var overlay: Result<KikuchiOverlay.Pattern, KikuchiOverlay.Absence>? {
        guard overlayOn, let dataset, let position = patternPosition else { return nil }
        let minD = overlaySettings.minDSpacing
        if let memo = overlayMemo, memo.position == position, memo.minD == minD { return memo.value }
        let maxR = overlayMaxR ?? KikuchiOverlay.scanMaxR(dataset)
        overlayMaxR = maxR
        let value = KikuchiOverlay.pattern(dataset, at: position, maxR: maxR) { id, phase in
            if let cached = overlayBands[id] { return cached }
            let made = KikuchiOverlay.bands(for: phase, minDSpacing: minD)
            overlayBands[id] = made
            return made
        }
        overlayMemo = (position, minD, value)
        return value
    }

    /// Forgets the overlay's caches (a new dataset, or none); on or off and the settings stay the user's.
    func resetOverlay() {
        overlayBands = [:]
        overlayMaxR = nil
        overlayMemo = nil
    }
}
