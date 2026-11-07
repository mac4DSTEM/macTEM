//
//  EBSDSession+Overlay.swift
//  Role: the Patterns room's simulation overlay (docs/sem/design/simulation-overlay.md §2, §4): on or off, its settings, and the
//        geometrical Kikuchi simulation of the shown pattern's orientation (`KikuchiOverlay`, TEMCore). The overlay follows the pattern
//        pane: the position whose pattern is on screen (the hovered one while the pointer is on the map), so a grain boundary shows as the
//        bands jumping. One position's simulation is well under a millisecond in release; the last one is kept, the bands per phase
//        and the scan's r_max per dataset. `Kinematical` adds the point's kinematical simulation (the phase's kinematical master
//        pattern, made once per phase and spacing, put on the detector) and the master pattern's picture. `Band width` adds the band edges at the Bragg angle for the file's beam energy (#201).
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
        if settings.minDSpacing != overlaySettings.minDSpacing {
            overlayBands = [:]; overlayMasters = [:]; overlayPictures = [:]; overlayMemo = nil
        }
        overlaySettings = settings
    }

    /// Whether the band edges can be drawn: the file states its beam energy.
    package var canDrawBandWidth: Bool { (dataset?.sem.beamEnergyKeV ?? 0) > 0 }

    /// The shown overlay as CSV (`KikuchiOverlay.csv`); nil while there is none.
    package var overlayCSV: String? {
        guard case .success(let pattern)? = overlay else { return nil }
        return KikuchiOverlay.csv(pattern)
    }

    /// Whether the dataset carries orientations the overlay can draw.
    package var canOverlay: Bool { dataset?.crystalMap != nil }

    /// The overlay at the pattern on screen while it is on, or why there is none; nil while it is off or before a pattern shows.
    package var overlay: Result<KikuchiOverlay.Pattern, KikuchiOverlay.Absence>? {
        guard overlayOn, let dataset, let position = patternPosition else { return nil }
        let minD = overlaySettings.minDSpacing, bandWidth = overlaySettings.bandWidth
        let kinematical = overlaySettings.kinematical && canDrawBandWidth
        if let memo = overlayMemo, memo.position == position, memo.minD == minD, memo.bandWidth == bandWidth, memo.kinematical == kinematical {
            return memo.value
        }
        let kv = dataset.sem.beamEnergyKeV ?? 0
        let maxR = overlayMaxR ?? KikuchiOverlay.scanMaxR(dataset)
        overlayMaxR = maxR
        let master: ((Int, CrystalPhase, KikuchiOverlay.Bands) -> EBSDMasterPattern?)? = kinematical ? { id, phase, bands in
            if let cached = self.overlayMasters[id] { return cached }
            let made = KikuchiOverlay.masterPattern(bands, phase: phase, beamEnergyKeV: kv)
            self.overlayMasters[id] = made
            return made
        } : nil
        let value = KikuchiOverlay.pattern(dataset, at: position, maxR: maxR, beamEnergyKeV: bandWidth ? dataset.sem.beamEnergyKeV : nil,
                                           master: master) { id, phase in
            if let cached = overlayBands[id] { return cached }
            let made = KikuchiOverlay.bands(for: phase, minDSpacing: minD)
            overlayBands[id] = made
            return made
        }
        overlayMemo = (position, minD, bandWidth, kinematical, value)
        return value
    }

    /// The kinematical master pattern of the shown point's phase as a picture (the upper hemisphere, stereographic, every band
    /// intensity 1): its side and row-major values; nil unless Kinematical is on and the point has bands.
    package var overlayMasterPicture: (side: Int, values: [Double], phase: String)? {
        guard overlaySettings.kinematical, canDrawBandWidth, let dataset, let map = dataset.crystalMap, let position = patternPosition else { return nil }
        let index = position.index(columns: dataset.scanColumns)
        guard map.allPhaseIDs.indices.contains(index) else { return nil }
        let id = map.allPhaseIDs[index]
        guard let phase = map.phases[id: id], let cached = overlayBands[id], let bands = cached else { return nil }
        let picture = overlayPictures[id] ?? KikuchiOverlay.masterPatternPicture(bands, beamEnergyKeV: dataset.sem.beamEnergyKeV ?? 0)
        overlayPictures[id] = picture
        return (Int(Double(picture.count).squareRoot().rounded()), picture, phase.name)
    }

    /// Forgets the overlay's caches (a new dataset, or none); on or off and the settings stay the user's.
    func resetOverlay() {
        overlayMasters = [:]
        overlayPictures = [:]
        overlayBands = [:]
        overlayMaxR = nil
        overlayMemo = nil
    }
}
