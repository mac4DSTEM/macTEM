//
//  DiffractionAnalysis.swift
//  Role: the Diffraction room's owner for one open file (design section 2): the centre, the calibration, the crystal, the rings and the
//        spots the user measured, and the readout the room and its exports show. It holds no pixels of the image (the room hands the
//        image to each action), so it stays while the item is cold.
//
//  Nothing here makes a number: `TEMCore/Diffraction` is DiffractoKit's ring fit, calibration, scale and indexing; this owner decides WHEN
//  to ask. A ring fit runs in a detached task, newest wins (a generation counter): its answer is dropped when a newer request was made
//  or the file's centre changed meanwhile. A ring or spot is indexed again at every read of `readout`, so a new crystal, tolerance or
//  scale re-indexes everything without a refit.
//

import Foundation
import Observation
import ImagoCore
import DiffractoCore
import DiffractoScattering
import DiffractoGeometry
import TEMCore

/// The crystal indexing is done against: a standard of the room, or one opened from a CIF.
package enum DiffractionCrystal: Sendable, Equatable {
    case preset(StandardCrystal)
    case cif(LoadedCrystal)

    package var name: String {
        switch self {
        case .preset(let s): s.name
        case .cif(let c): c.displayName
        }
    }
    package var structure: CrystalStructure {
        switch self {
        case .preset(let s): s.structure
        case .cif(let c): c.structure
        }
    }
    package var sha256: String? {
        if case .cif(let c) = self { return c.sha256 }
        return nil
    }
}

@Observable
package final class DiffractionAnalysis {
    // The facts
    package private(set) var centre: DiffractionCentre?
    package private(set) var crystal: DiffractionCrystal = .preset(StandardCrystals.all[0])
    /// The standard a ring is calibrated on, and the index of its family in the list (the nearest few families).
    package private(set) var standard: StandardCrystal = StandardCrystals.all[0]
    package var familyIndex = 0
    package private(set) var kMax: Double = 3
    package var tolerancePercent: Double = 1
    package private(set) var ringCalibration: DiffractionCalibration?
    package private(set) var calibratedFamily: String?
    package var typedDeltaQ: Double?
    package var typedBeamKV: Double?
    package var pitchMM: Double?
    package private(set) var rings: [MeasuredRing] = []
    package private(set) var spots: [MeasuredSpot] = []
    /// The ring or spot added last (a click, or a ring fit that landed): the room selects it. Selection itself is view state.
    package private(set) var lastAdded: UUID?
    package private(set) var isFitting = false
    package private(set) var failure: String?
    /// A CIF the kit refused, in its words.
    package private(set) var cifRefusal: String?
    /// Why the crystal has no list: a CIF refusal, else the kit's refusal to build the kinematic list at this k_max.
    package var crystalFailure: String? { cifRefusal ?? listResult().failure }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fitTask: Task<Void, Never>?
    @ObservationIgnored private var listCache: (key: String, list: KinematicReflectionList?, failure: String?)?
    @ObservationIgnored private var familiesCache: [String: [(name: String, d: Double, family: ReflectionFamily)]] = [:]
    @ObservationIgnored private var readoutCache: (key: ReadoutKey, rows: [DiffractionReadoutRow])?
    @ObservationIgnored private var boundSize: (Int, Int)?

    package init() {}

    // MARK: Binding to the image

    /// Sets the starting centre and k_max from the image the first time it is seen (and again for a different size).
    package func bind(_ image: CalibratedImage) {
        guard boundSize?.0 != image.width || boundSize?.1 != image.height else { return }
        boundSize = (image.width, image.height)
        centre = .imageCentre(width: image.width, height: image.height)
        let dq = fileDeltaQ(image) ?? 0.0125
        setKMax(min(4, max(0.5, (Double(min(image.width, image.height)) / 2 * dq * 10).rounded() / 10)))
    }

    package func fileDeltaQ(_ image: CalibratedImage) -> Double? { DiffractionCalibration.fileDeltaQ(image.x) }

    // MARK: Calibration

    /// The scale in use: a ring fit on a standard, else the file's reciprocal axis, else a typed Δq; nil with none.
    package func calibration(for image: CalibratedImage) -> DiffractionCalibration? {
        if let ringCalibration { return ringCalibration }
        if let dq = fileDeltaQ(image) { return DiffractionCalibration(source: .fileAxis, deltaQ: dq, ring: nil) }
        if let dq = typedDeltaQ, dq > 0 { return DiffractionCalibration(source: .typed, deltaQ: dq, ring: nil) }
        return nil
    }

    /// Δq_fit / Δq_file − 1 in percent, when both exist.
    package func fitVersusFilePercent(for image: CalibratedImage) -> Double? {
        guard let ring = ringCalibration, let file = fileDeltaQ(image) else { return nil }
        let v = RingScale.fitVersusFile(fitDeltaQ: ring.deltaQ, fileDeltaQ: file)
        return v.isFinite ? 100 * v : nil
    }

    /// The beam energy in volts: the file's, else the typed kV.
    package func volts(for image: CalibratedImage) -> Double? {
        if let v = image.voltage, v > 0 { return v }
        if let kv = typedBeamKV, kv > 0 { return kv * 1000 }
        return nil
    }

    package var ringCalibrationExists: Bool { ringCalibration != nil }

    package func clearCalibration() { ringCalibration = nil; calibratedFamily = nil }

    // MARK: Centre

    package func setCentre(row: Double, column: Double) {
        guard row.isFinite, column.isFinite else { return }
        centre = DiffractionCentre(row: row, column: column, source: .typed)
    }

    /// Takes the fitted ring's centre as the pattern's (offered, never applied by itself).
    package func useCentre(ofRing id: UUID) {
        guard let fit = rings.first(where: { $0.id == id })?.fit?.fit else { return }
        centre = DiffractionCentre(row: fit.centerQX, column: fit.centerQY, source: .ring)
    }

    // MARK: Crystal

    package func setCrystal(_ new: DiffractionCrystal) {
        crystal = new
        cifRefusal = nil
        if case .preset(let s) = new { standard = s }
    }

    package func setStandard(_ new: StandardCrystal) {
        standard = new
        familyIndex = 0
        if case .preset = crystal { crystal = .preset(new) }
    }

    package func crystalRefused(_ words: String) { cifRefusal = words }

    /// k_max in Å⁻¹, kept in the kit's range.
    package func setKMax(_ value: Double) {
        guard value.isFinite else { return }
        kMax = min(max(value, 0.2), 4)
    }

    package func setTolerance(percent: Double) {
        guard percent.isFinite else { return }
        tolerancePercent = max(percent, 0.01)
    }

    /// The kinematic list of the crystal at the current k_max and why there is none. Cached by crystal and k_max; it writes no observed state, so a
    /// view body may call it (the build runs on the first call after the crystal or k_max changed).
    private func listResult() -> (list: KinematicReflectionList?, failure: String?) {
        let key = "\(crystal.name)|\(crystal.sha256 ?? "")|\(kMax)"
        if let listCache, listCache.key == key { return (listCache.list, listCache.failure) }
        let built: (list: KinematicReflectionList?, failure: String?)
        do { built = (try DiffractionCompute.list(of: crystal.structure, kMax: kMax), nil) }
        catch { built = (nil, error.localizedDescription) }
        listCache = (key, built.list, built.failure)
        return built
    }

    package func list() -> KinematicReflectionList? { listResult().list }

    /// The standard's first families (the ones a ring is picked from): name, d. Cached by standard and k_max.
    package func standardFamilies() -> [(name: String, d: Double, family: ReflectionFamily)] {
        let reach = max(kMax, 2.5)
        let key = "\(standard.name)|\(reach)"
        if let hit = familiesCache[key] { return hit }
        guard let list = try? DiffractionCompute.list(of: standard.structure, kMax: reach) else { return [] }
        let families = list.families.prefix(6).map { (name: DiffractionCompute.familyName($0.family), d: $0.family.d, family: $0.family) }
        familiesCache[key] = families
        return families
    }

    // MARK: Rings

    /// Fits the ring in the annulus; with `calibrate`, also calibrates against that family of the standard. Newest wins.
    @discardableResult
    package func fitRing(image: CalibratedImage, inner: Double, outer: Double, calibrateOn family: ReflectionFamily? = nil) -> Task<Void, Never>? {
        guard let centre, inner.isFinite, outer.isFinite, outer > inner, inner > 0 else { return nil }
        generation += 1
        let gen = generation
        fitTask?.cancel()
        failure = nil
        isFitting = true
        let pattern = DiffractionCompute.pattern(of: image)
        let volts = volts(for: image), pitch = pitchMM
        let standardName = standard.name
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = DiffractionCompute.fitRing(pattern: pattern, centre: centre, inner: inner, outer: outer, isCancelled: { Task.isCancelled })
            if Task.isCancelled { return }
            await self?.landRing(result, inner: inner, outer: outer, family: family, standard: standardName, volts: volts, pitch: pitch, generation: gen)
        }
        fitTask = task
        return task
    }

    private func landRing(_ result: (fit: RingRadiusFit?, refusal: String?), inner: Double, outer: Double, family: ReflectionFamily?,
                          standard name: String, volts: Double?, pitch: Double?, generation gen: Int) {
        guard gen == generation else { return }
        isFitting = false
        var refusal = result.refusal
        var calibrating = false
        if let family, let fit = result.fit, refusal == nil {
            do {
                let calibrated = try DiffractionCompute.calibrate(fit, d: family.d, volts: volts, pitchMM: pitch)
                if let ring = calibrated.calibration {
                    ringCalibration = DiffractionCalibration(source: .ringFit(standard: name, family: DiffractionCompute.familyName(family)),
                                                             deltaQ: ring.deltaQ, ring: ring)
                    calibratedFamily = DiffractionCompute.familyName(family)
                    calibrating = true
                } else {
                    refusal = calibrated.refusals.first?.reason ?? "the ring could not calibrate the scale"
                }
            } catch {
                refusal = error.localizedDescription
            }
        } else if family != nil, refusal == nil, result.fit == nil {
            refusal = "no ring was fitted"
        }
        if calibrating { for i in rings.indices { rings[i].isCalibrating = false } }
        let ring = MeasuredRing(innerRadius: inner, outerRadius: outer, fit: result.fit, refusal: refusal, isCalibrating: calibrating)
        rings.append(ring)
        lastAdded = ring.id
        if let refusal { failure = refusal }
    }

    package func stop() {
        fitTask?.cancel(); fitTask = nil
        generation += 1
        isFitting = false
    }

    // MARK: Spots

    /// A click on the pattern: the centre is refined (the kit's `PatternSpot.refine`), and the spot is listed with its radius and indexing.
    package func addSpot(image: CalibratedImage, row: Double, column: Double) {
        let refined = PatternSpot.refine(pattern: DiffractoGeometry.DiffractionPattern(width: image.width, height: image.height, pixels: image.pixels),
                                         row: row, column: column)
        let spot: MeasuredSpot
        if let refined {
            spot = MeasuredSpot(clickRow: row, clickColumn: column, row: refined.row, column: refined.column, radius: nil, refusal: nil)
        } else {
            spot = MeasuredSpot(clickRow: row, clickColumn: column, row: nil, column: nil, radius: nil, refusal: "no signal near the click")
        }
        spots.append(spot)
        lastAdded = spot.id
    }

    package func remove(_ id: UUID) {
        rings.removeAll { $0.id == id }
        spots.removeAll { $0.id == id }
        if ringCalibration != nil, !rings.contains(where: \.isCalibrating) { clearCalibration() }
    }

    package func removeAll() {
        stop()
        rings = []; spots = []; lastAdded = nil; clearCalibration(); failure = nil
    }

    // MARK: The readout

    /// Everything the rows are made from. The rows are made again only when one of these differs from the last time, so a render the results did
    /// not cause (a zoom, a hover, a selection) costs a comparison and no indexing.
    private struct ReadoutKey: Equatable {
        var centre: DiffractionCentre?
        var crystal: DiffractionCrystal
        var kMax: Double
        var tolerancePercent: Double
        var ringCalibration: DiffractionCalibration?
        var typedDeltaQ: Double?
        var typedBeamKV: Double?
        var pitchMM: Double?
        var rings: [MeasuredRing]
        var spots: [MeasuredSpot]
        var fileName: String
        var width: Int
        var height: Int
        var voltage: Double?
        var axis: AxisCalibration?
    }

    /// Every ring and spot as a row, indexed against the crystal now (the last answer again while nothing it depends on changed).
    package func readout(image: CalibratedImage) -> [DiffractionReadoutRow] {
        let key = ReadoutKey(centre: centre, crystal: crystal, kMax: kMax, tolerancePercent: tolerancePercent, ringCalibration: ringCalibration,
                             typedDeltaQ: typedDeltaQ, typedBeamKV: typedBeamKV, pitchMM: pitchMM, rings: rings, spots: spots,
                             fileName: image.fileName, width: image.width, height: image.height, voltage: image.voltage, axis: image.x)
        if let readoutCache, readoutCache.key == key { return readoutCache.rows }
        let rows = makeReadout(image: image)
        readoutCache = (key, rows)
        return rows
    }

    private func makeReadout(image: CalibratedImage) -> [DiffractionReadoutRow] {
        let calibration = calibration(for: image)
        let list = list()
        let calibratingEllipse = rings.first(where: \.isCalibrating)?.ellipse
        var out: [DiffractionReadoutRow] = []
        func row(id: UUID, kind: DiffractionReadoutRow.Kind, number: Int, radius: Double?, calibrating: Bool, refusal: String?) -> DiffractionReadoutRow {
            guard let radius else {
                return DiffractionReadoutRow(id: id, kind: kind, number: number, radiusPx: nil, q: nil, d: nil, family: nil, dListed: nil,
                                             deltaPercent: nil, oddsText: nil, verdict: refusal ?? "no radius", validation: RingIndexing.validation)
            }
            guard let calibration else {
                return DiffractionReadoutRow(id: id, kind: kind, number: number, radiusPx: radius, q: nil, d: nil, family: nil, dListed: nil,
                                             deltaPercent: nil, oddsText: nil, verdict: "no scale yet: calibrate a ring or type Δq",
                                             validation: RingIndexing.validation)
            }
            let q = calibration.q(radius: radius)
            guard q.isFinite, q > 0 else {
                return DiffractionReadoutRow(id: id, kind: kind, number: number, radiusPx: radius, q: nil, d: nil, family: nil, dListed: nil,
                                             deltaPercent: nil, oddsText: nil, verdict: "radius outside the scale", validation: RingIndexing.validation)
            }
            guard let list else {
                return DiffractionReadoutRow(id: id, kind: kind, number: number, radiusPx: radius, q: q, d: 1 / q, family: nil, dListed: nil,
                                             deltaPercent: nil, oddsText: nil, verdict: crystalFailure ?? "no crystal list", validation: RingIndexing.validation)
            }
            let indexing = IndexingDisplay.index(q: q, tolerancePercent: tolerancePercent, in: list)
            return DiffractionReadoutRow(id: id, kind: kind, number: number, radiusPx: radius, q: q, d: 1 / q,
                                         family: indexing.family.map { DiffractionCompute.familyName($0) }, dListed: indexing.dListed,
                                         deltaPercent: indexing.deltaPercent, oddsText: indexing.assignment == nil ? nil : indexing.oddsText,
                                         verdict: indexing.verdict, validation: indexing.validation, isCalibrating: calibrating)
        }
        for (i, ring) in rings.enumerated() {
            out.append(row(id: ring.id, kind: .ring, number: i + 1, radius: ring.radius, calibrating: ring.isCalibrating,
                           refusal: ring.refusal))
        }
        if let centre {
            for (i, spot) in spots.enumerated() {
                let radius = spot.row.flatMap { r in spot.column.map { c in DiffractionCompute.radius(row: r, column: c, centre: centre, ellipse: calibratingEllipse) } }
                out.append(row(id: spot.id, kind: .spot, number: i + 1, radius: radius, calibrating: false, refusal: spot.refusal))
            }
        }
        return out
    }

    // MARK: Export and Results

    package func exportHeader(image: CalibratedImage) -> DiffractionExportHeader {
        let calibration = calibration(for: image)
        let c = centre ?? .imageCentre(width: image.width, height: image.height)
        return DiffractionExportHeader(
            fileName: image.fileName, centreRow: c.row, centreColumn: c.column,
            centreSource: { switch c.source { case .fileCentre: "the image centre"; case .typed: "typed"; case .ring: "a fitted ring" } }(),
            calibration: calibration?.sourceText ?? "none", deltaQ: calibration?.deltaQ, wavelengthAngstroms: calibration?.ring?.wavelengthAngstroms,
            lengthPixels: calibration?.ring?.lengthPixels, lengthMM: calibration?.ring?.lengthMillimetres,
            fitVersusFilePercent: fitVersusFilePercent(for: image), crystal: crystal.name, crystalSHA256: crystal.sha256, kMax: kMax,
            tolerancePercent: tolerancePercent)
    }

    package func exportText(image: CalibratedImage) -> String {
        DiffractionExport.text(rows: readout(image: image), header: exportHeader(image: image))
    }

    /// The Results room's rows: one calibration row when a standard fit set the scale, one row per ring and spot.
    package func resultRows(image: CalibratedImage) -> [ResultRow] {
        var out: [ResultRow] = []
        if let calibration = ringCalibration, case .ringFit(let standard, let family) = calibration.source, let ring = calibration.ring {
            out.append(.calibration(id: "calibration", label: "Calibration", standard: standard, family: family, d: ring.d, radius: ring.radius,
                                    deltaQ: ring.deltaQ, wavelength: ring.wavelengthAngstroms, lengthPixels: ring.lengthPixels,
                                    lengthMM: ring.lengthMillimetres, fitVersusFilePercent: fitVersusFilePercent(for: image)))
        }
        for r in readout(image: image) {
            let refusal = r.d == nil ? r.verdict : nil
            out.append(.ring(id: "diffraction:\(r.id.uuidString)", label: "\(r.kind == .ring ? "Ring" : "Spot") \(r.number)", radius: r.radiusPx, q: r.q,
                             d: r.d, family: r.family, dListed: r.dListed, deltaPercent: r.deltaPercent, odds: r.oddsText, verdict: r.verdict, refusal: refusal))
        }
        return out
    }

    /// Cancels work and lets go (the file closed).
    package func close() { stop() }
}
