//
//  SEMEDSState.swift
//  Role: the EDS room's SEM additions for one SEM spectrum (an exspy/HyperSpy `.hspy` of signal type EDS_SEM, as the demo TM002): the
//        conditions the file states, exspy's line table (integration windows, background windows, raw and background-subtracted counts)
//        and the Cliff-Lorimer composition from typed k-factors. The numbers are TEMCore's `SEMEDSLines` (the exspy port, parity in
//        SEMEDSParityTests); this holds only the person's choices and the last result. Composed by `AppState`; window-wide, not saved.
//        A file that is not an SEM `.hspy` clears it, and the inspector shows nothing of it.
//

import Foundation
import Observation
import TEMCore

@Observable
final class SEMEDSState {
    /// The file the table belongs to (the EDS room's source path), and what was read from it.
    private(set) var path: String?
    private(set) var spectrum: HyperSpySpectrumFile.Spectrum?
    /// The line table, recomputed whenever a choice below changes.
    private(set) var rows: [SEMEDSLines.LineRow] = []
    /// The sentence for a table or a quantification that could not be made.
    private(set) var failure: String?
    /// The Cliff-Lorimer result for the k-factors in effect when Quantify was pressed; stale once a window or a k-factor changes.
    private(set) var composition: [SEMEDSLines.Composition]?
    private(set) var compositionIsStale = false

    /// exspy's tutorial: integration windows 2 FWHM wide, background windows 5 FWHM left and 2 FWHM right of the line, 1 FWHM wide.
    var backgroundWindows = true { didSet { recompute() } }
    var integrationWidth = 2.0 { didSet { recompute() } }
    var backgroundLeft = 5.0 { didSet { recompute() } }
    var backgroundRight = 2.0 { didSet { recompute() } }
    /// k-factors by line (`Mn_La`); a line without one has none typed and Quantify waits for it.
    private(set) var kFactors: [String: Double] = [:]

    var isSEMSpectrum: Bool { spectrum?.isSEM == true }

    /// The k-factors in the table's order, or nil while one is missing.
    var kFactorsInOrder: [Double]? {
        let ks = rows.map { kFactors[$0.line] }
        return ks.contains(where: { $0 == nil }) ? nil : ks.compactMap { $0 }
    }

    var quantifyDisabledReason: String? {
        if rows.count < 2 { return "Cliff-Lorimer needs at least two lines." }
        if kFactorsInOrder == nil { return "Type a k-factor for every line." }
        return nil
    }

    /// Reads `path` when it is an SEM `.hspy` (off the main actor) and builds the table; anything else clears the state.
    func load(path newPath: String?) async {
        guard newPath != path else { return }
        path = newPath
        spectrum = nil; rows = []; failure = nil; composition = nil; compositionIsStale = false; kFactors = [:]
        guard let newPath, HyperSpySpectrumFile.isHyperSpyFile(path: newPath) else { return }
        do {
            let read = try await Self.read(newPath)
            guard path == newPath else { return }
            spectrum = read.isSEM ? read : nil
            recompute()
        } catch {
            guard path == newPath else { return }
            failure = error.localizedDescription
        }
    }

    func setKFactor(_ value: Double, for line: String) {
        guard value.isFinite, value > 0 else { return }
        kFactors[line] = value
        if composition != nil { compositionIsStale = true }
    }

    func quantify() {
        guard let ks = kFactorsInOrder else { return }
        do {
            composition = try SEMEDSLines.quantify(rows, kFactors: ks)
            compositionIsStale = false
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func recompute() {
        guard let spectrum, spectrum.isSEM else { rows = []; return }
        let toKeV = spectrum.units.lowercased() == "kev" ? 1.0 : 0.001
        let axis = SEMEDSLines.Axis(offsetKeV: spectrum.offset * toKeV, scaleKeV: spectrum.scale * toKeV, size: spectrum.counts.count)
        do {
            rows = try SEMEDSLines.table(counts: spectrum.counts, axis: axis, elements: spectrum.elements, conditions: spectrum.conditions,
                                         integrationWidth: integrationWidth,
                                         backgroundLineWidth: backgroundWindows ? (left: backgroundLeft, right: backgroundRight) : nil)
            failure = nil
        } catch {
            rows = []
            failure = error.localizedDescription
        }
        if composition != nil { compositionIsStale = true }
    }

    @concurrent
    nonisolated private static func read(_ path: String) async throws -> HyperSpySpectrumFile.Spectrum {
        try HyperSpySpectrumFile.read(path: path)
    }
}
