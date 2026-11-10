//
//  SEMEDSState.swift
//  Role: the EDS room's SEM additions for one SEM spectrum (an exspy/HyperSpy `.hspy` of signal type EDS_SEM, as the demo TM002): the
//        conditions the file states and exspy's line table (integration windows, background windows, raw and background-subtracted
//        counts) at the tutorial's widths, shown read-only in Info; the spectrum is quantified by the shared EDS room, with the file's
//        elements picked on open (D-SEM-107). The numbers are TEMCore's `SEMEDSLines` (the exspy port, parity in SEMEDSParityTests).
//        Composed by `AppState`; window-wide, not saved.
//        A file that is not an SEM `.hspy` clears it, and the inspector shows nothing of it.
//

import Foundation
import Observation
import ShellEDXModel
import SpectroCore
import TEMCore

@Observable
final class SEMEDSState {
    /// The file the table belongs to (the EDS room's source path), and what was read from it.
    private(set) var path: String?
    private(set) var spectrum: HyperSpySpectrumFile.Spectrum?
    /// The line table, recomputed whenever a choice below changes.
    private(set) var rows: [SEMEDSLines.LineRow] = []
    /// The sentence for a table that could not be made.
    private(set) var failure: String?

    /// exspy's tutorial: integration windows 2 FWHM wide, background windows 5 FWHM left and 2 FWHM right of the line, 1 FWHM wide.
    let integrationWidth = 2.0
    let backgroundLeft = 5.0
    let backgroundRight = 2.0

    var isSEMSpectrum: Bool { spectrum?.isSEM == true }

    /// Reads `path` when it is an SEM `.hspy` (off the main actor) and builds the table; anything else clears the state.
    func load(path newPath: String?) async {
        guard newPath != path else { return }
        path = newPath
        spectrum = nil; rows = []; failure = nil
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

    /// Picks the elements the file names (`Sample.elements`, exspy's list) in the shared EDS room, once the room is at rest after its open
    /// and Auto ID: an SEM spectrum is quantified by the room's own Quantify, as a TEM one is (D-SEM-107). Auto ID's picks stay; an
    /// element already picked is left as it is. Runs once per file (the caller's task is keyed by the path), so an element the person
    /// takes out is not put back.
    func pickFileElements(in session: EDXSession) async {
        guard isSEMSpectrum, let elements = spectrum?.elements, !elements.isEmpty else { return }
        await session.settled()
        guard session.source?.metadata.filePath == path else { return }
        for symbol in elements where !session.picks.contains(where: { $0.symbol == symbol }) { session.toggle(symbol) }
    }

    private func recompute() {
        guard let spectrum, spectrum.isSEM else { rows = []; return }
        let toKeV = spectrum.units.lowercased() == "kev" ? 1.0 : 0.001
        let axis = SEMEDSLines.Axis(offsetKeV: spectrum.offset * toKeV, scaleKeV: spectrum.scale * toKeV, size: spectrum.counts.count)
        do {
            rows = try SEMEDSLines.table(counts: spectrum.counts, axis: axis, elements: spectrum.elements, conditions: spectrum.conditions,
                                         integrationWidth: integrationWidth,
                                         backgroundLineWidth: (left: backgroundLeft, right: backgroundRight))
            failure = nil
        } catch {
            rows = []
            failure = error.localizedDescription
        }
    }

    @concurrent
    nonisolated private static func read(_ path: String) async throws -> HyperSpySpectrumFile.Spectrum {
        try HyperSpySpectrumFile.read(path: path)
    }
}
