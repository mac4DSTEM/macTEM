//
//  EBSDSession+Overlay.swift
//  Role: the Patterns room's simulation overlay (docs/sem/design/simulation-overlay.md §2, §4): on or off, its settings, and the
//        geometrical Kikuchi simulation of the shown pattern's orientation (`KikuchiOverlay`, TEMCore). The overlay follows the pattern
//        pane: the position whose pattern is on screen (the picked one), so a grain boundary crossed by a drag shows as the
//        bands jumping. One position's simulation is well under a millisecond in release; the last one is kept, the bands per phase
//        and the scan's r_max per dataset. `Kinematical` adds the point's kinematical simulation (the phase's kinematical master
//        pattern, made once per phase and spacing, put on the detector) and the master pattern's picture. `Band width` adds the band edges at the Bragg angle for the file's beam energy (#201).
//
//  The master pattern (kikuchipy's band rule on the 401 × 401 Lambert grid of both hemispheres, over every band) and its picture are
//  made off the main actor (`KikuchiOverlay.kinematicalMaster`), once per phase and spacing: the lines draw at once, and the
//  simulation joins them when its master lands (`overlayMastersLanded`), the same numbers as when the pane waited for it.
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
            cancelOverlayMasters()
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
        // Read so the pane draws again when a master pattern lands (the memo is dropped then).
        _ = overlayMastersLanded
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
            // Not made yet: the lines now, the simulation once the master lands.
            self.makeOverlayMaster(id, phase: phase, bands: bands, beamEnergyKeV: kv)
            return nil
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
    /// intensity 1): its side and row-major values; nil unless Kinematical is on and the point has bands, and until it has landed.
    package var overlayMasterPicture: (side: Int, values: [Double], phase: String)? {
        guard overlaySettings.kinematical, canDrawBandWidth, let dataset, let map = dataset.crystalMap, let position = patternPosition else { return nil }
        _ = overlayMastersLanded
        let index = position.index(columns: dataset.scanColumns)
        guard map.allPhaseIDs.indices.contains(index) else { return nil }
        let id = map.allPhaseIDs[index]
        guard let phase = map.phases[id: id], let cached = overlayBands[id], let bands = cached else { return nil }
        guard let picture = overlayPictures[id] else {
            makeOverlayMaster(id, phase: phase, bands: bands, beamEnergyKeV: dataset.sem.beamEnergyKeV ?? 0)
            return nil
        }
        return (Int(Double(picture.count).squareRoot().rounded()), picture, phase.name)
    }

    /// Whether a kinematical master pattern is being made: the overlay has its lines but not yet its simulation.
    package var isMakingOverlayMaster: Bool { !overlayMasterTasks.isEmpty }

    /// The master patterns being made now, as one task that ends when they have all landed (at once when none is): what a test
    /// waits on before it reads the simulation.
    package func overlayMastersReady() -> Task<Void, Never> {
        let running = Array(overlayMasterTasks.values)
        return Task {
            for task in running { await task.value }
        }
    }

    /// Makes phase `id`'s kinematical master pattern and its picture off the main actor, once (a second ask while it is being made
    /// changes nothing); when they land the memo goes and the overlay draws its simulation. A new spacing or dataset cancels it, and
    /// a cancelled one lands nothing.
    private func makeOverlayMaster(_ id: Int, phase: CrystalPhase, bands: KikuchiOverlay.Bands, beamEnergyKeV kv: Double) {
        guard overlayMasterTasks[id] == nil else { return }
        overlayMasterTasks[id] = Task { [weak self] in
            let made = await KikuchiOverlay.kinematicalMaster(bands, phase: phase, beamEnergyKeV: kv, picture: true)
            guard let self, !Task.isCancelled else { return }
            self.overlayMasterTasks[id] = nil
            self.overlayMasters[id] = made.master
            if let picture = made.picture { self.overlayPictures[id] = picture }
            self.overlayMemo = nil
            self.overlayMastersLanded += 1
        }
    }

    /// Drops the master patterns being made: none of them lands.
    private func cancelOverlayMasters() {
        for task in overlayMasterTasks.values { task.cancel() }
        overlayMasterTasks = [:]
    }

    /// Forgets the overlay's caches (a new dataset, or none); on or off and the settings stay the user's.
    func resetOverlay() {
        cancelOverlayMasters()
        overlayMasters = [:]
        overlayPictures = [:]
        overlayBands = [:]
        overlayMaxR = nil
        overlayMemo = nil
    }
}
