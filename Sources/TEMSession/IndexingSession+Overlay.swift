//
//  IndexingSession+Overlay.swift
//  Role: the simulation overlay in the Indexing room's pattern pane (docs/sem/design/simulation-overlay.md §2, §4; #201): the Kikuchi
//        simulation of the run's solution at the shown point, drawn over the pattern as indexed, so a wrong solution, PC or phase
//        shows as bands that miss. The numbers are the Patterns room's overlay (`KikuchiOverlay.pattern`, kikuchipy's on_detector,
//        parity `m6/geometrical-simulation-nickel`) fed with the solution's rotation and phase instead of the file's: the run's mean
//        projection centre (a refinement's refined PC at the point, D-SEM-109), the dataset's detector angles at the indexed
//        pattern's shape (binned when the pipeline bins). What is drawn
//        (Min d, Band width, Zone axes, Labels, Kinematical and Blend) is the Patterns room's Simulation section, one set of settings
//        for both panes. Bands and kinematical master patterns are made once per phase and spacing; the last overlay is kept. A
//        master pattern is made off the main actor (`KikuchiOverlay.kinematicalMaster`): the lines draw at once, and the simulation
//        joins them when the master lands (`overlayMastersLanded`), the same numbers as when the pane waited for it.
//

import Foundation
import TEMCore

/// A phase of a run and the spacing its bands are made down to: the overlay's cache key (a run's phases are values, not ids).
package nonisolated struct IndexingOverlayKey: Hashable, Sendable {
    var name: String
    var spaceGroup: Int
    var lattice: [Double]
    var minD: Double
}

/// What the last overlay was made from.
package nonisolated struct IndexingOverlayMemo: Equatable, Sendable {
    var position: EBSDPosition
    var quaternion: SIMD4<Double>
    var phase: IndexingOverlayKey
    var pc: SIMD3<Double>
    var rows: Int
    var columns: Int
    var bandWidth: Bool
    var kinematical: Bool
}

extension IndexingSession {
    /// The overlay at the pattern on screen while `showsSimulation` is on, or why there is none (a point without a solution); nil while
    /// it is off, before a run, or before the pattern shows.
    package var simulationOverlay: Result<KikuchiOverlay.Pattern, KikuchiOverlay.Absence>? {
        guard showsSimulation, let result, let position = patternPosition, let dataset = patterns.dataset,
              patternShape.rows > 0, patternShape.columns > 0 else { return nil }
        // Read so the pane draws again when a master pattern lands (the memo is dropped then).
        _ = overlayMastersLanded
        guard let meanPC = resultProjectionCenter else { return .failure(.noOrientations) }
        guard let solution = result.solution(at: position), solution.phase >= 0, let phase = result.phase(of: solution) else {
            return .failure(.notIndexed)
        }
        // A refinement under PC or Both draws each point at its refined PC, the one its orientation was fitted with (D-SEM-109).
        let pc = result.refinedProjectionCenter(at: position) ?? meanPC
        let settings = patterns.overlaySettings
        let kv = dataset.sem.beamEnergyKeV ?? 0
        let bandWidth = settings.bandWidth && kv > 0, kinematical = settings.kinematical && kv > 0
        let key = IndexingOverlayKey(name: phase.name, spaceGroup: phase.spaceGroup, lattice: phase.lattice, minD: settings.minDSpacing)
        let memo = IndexingOverlayMemo(position: position, quaternion: solution.quaternion, phase: key, pc: pc, rows: patternShape.rows,
                                       columns: patternShape.columns, bandWidth: bandWidth, kinematical: kinematical)
        if let kept = overlayMemo, kept.key == memo { return kept.value }
        let value: Result<KikuchiOverlay.Pattern, KikuchiOverlay.Absence>
        if let bands = overlayBandsFor(phase, key: key) {
            let detector = Self.indexedDetector(dataset.detector, rows: patternShape.rows, columns: patternShape.columns, pc: pc)
            let master: EBSDMasterPattern? = kinematical ? overlayMasters[key] : nil
            // Not made yet: the lines now, the simulation once the master lands.
            if kinematical, master == nil { makeOverlayMaster(key, phase: phase.crystalPhase, bands: bands, beamEnergyKeV: kv) }
            value = .success(KikuchiOverlay.pattern(phase: phase.name, rotation: solution.quaternion, bands: bands, detector: detector, pc: pc,
                                                    maxR: detector.rMax(pc), beamEnergyKeV: bandWidth ? kv : nil, master: master))
        } else {
            value = .failure(.noLattice(phase: phase.name))
        }
        overlayMemo = (memo, value)
        return value
    }

    /// The master patterns being made now, as one task that ends when they have all landed (at once when none is): what a test
    /// waits on before it reads the simulation.
    package func overlayMastersReady() -> Task<Void, Never> {
        let running = Array(overlayMasterTasks.values)
        return Task {
            for task in running { await task.value }
        }
    }

    /// Makes the kinematical master pattern of `key`'s phase off the main actor, once (a second ask while it is being made changes
    /// nothing); when it lands the memo goes and the overlay draws its simulation. A new dataset cancels it, and a cancelled one
    /// lands nothing.
    private func makeOverlayMaster(_ key: IndexingOverlayKey, phase: CrystalPhase, bands: KikuchiOverlay.Bands, beamEnergyKeV kv: Double) {
        guard overlayMasterTasks[key] == nil else { return }
        overlayMasterTasks[key] = Task { [weak self] in
            let made = await KikuchiOverlay.kinematicalMaster(bands, phase: phase, beamEnergyKeV: kv, picture: false)
            guard let self, !Task.isCancelled else { return }
            self.overlayMasterTasks[key] = nil
            self.overlayMasters[key] = made.master
            self.overlayMemo = nil
            self.overlayMastersLanded += 1
        }
    }

    /// The overlay's bands of a run's phase, made once per phase and spacing.
    private func overlayBandsFor(_ phase: IndexingPhase, key: IndexingOverlayKey) -> KikuchiOverlay.Bands? {
        if let cached = overlayBands[key] { return cached }
        let made = KikuchiOverlay.bands(for: phase.crystalPhase, minDSpacing: key.minD)
        overlayBands[key] = made
        return made
    }

    /// The dataset's detector at the indexed pattern's shape (`rows` x `columns`, binned when the pipeline bins) with the run's
    /// projection centre: the fractional (Bruker) PC and the angles do not change with binning.
    nonisolated static func indexedDetector(_ detector: EBSDDetectorGeometry, rows: Int, columns: Int, pc: SIMD3<Double>) -> EBSDDetectorGeometry {
        var out = detector
        if rows > 0, detector.rows > rows { out.binning = detector.binning * max(1, detector.rows / rows) }
        out.rows = rows
        out.columns = columns
        out.projectionCenters = [pc]
        return out
    }
}
