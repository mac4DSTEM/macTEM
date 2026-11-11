//
//  DiffractionExport.swift
//  Role: the Diffraction room's readout as one CSV (design section 6): comment lines (file, centre and where it came from, the
//        calibration and its source, the crystal and its sha256, k_max, the tolerance) then one row per ring or spot.
//        Pure text; the numbers are what `DiffractionReadout` rows hold, which are the kit's. The text cells are RFC 4180 and the file
//        and crystal names each stay on their header line (ImagoKit's `CSVText.quoted` and `CSVText.headerValue`).
//

import Foundation
import ImagoCore

/// One line of the readout: a ring or a spot with what the kit says about it.
package nonisolated struct DiffractionReadoutRow: Sendable, Equatable, Identifiable {
    package enum Kind: String, Sendable { case ring, spot }
    package let id: UUID
    package let kind: Kind
    package var number: Int
    package var radiusPx: Double?
    package var q: Double?
    /// Å, measured: 1/q.
    package var d: Double?
    package var family: String?
    package var dListed: Double?
    package var deltaPercent: Double?
    package var oddsText: String?
    package var verdict: String
    package var validation: String
    package var isCalibrating: Bool

    package init(id: UUID, kind: Kind, number: Int, radiusPx: Double?, q: Double?, d: Double?, family: String?, dListed: Double?,
                 deltaPercent: Double?, oddsText: String?, verdict: String, validation: String, isCalibrating: Bool = false) {
        self.id = id; self.kind = kind; self.number = number; self.radiusPx = radiusPx; self.q = q; self.d = d
        self.family = family; self.dListed = dListed; self.deltaPercent = deltaPercent; self.oddsText = oddsText
        self.verdict = verdict; self.validation = validation; self.isCalibrating = isCalibrating
    }
}

package nonisolated struct DiffractionExportHeader: Sendable, Equatable {
    package var fileName: String
    package var centreRow: Double
    package var centreColumn: Double
    package var centreSource: String
    package var calibration: String
    package var deltaQ: Double?
    package var wavelengthAngstroms: Double?
    package var lengthPixels: Double?
    package var lengthMM: Double?
    package var fitVersusFilePercent: Double?
    package var crystal: String
    package var crystalSHA256: String?
    package var kMax: Double
    package var tolerancePercent: Double
    package init(fileName: String, centreRow: Double, centreColumn: Double, centreSource: String, calibration: String, deltaQ: Double?,
                 wavelengthAngstroms: Double?, lengthPixels: Double?, lengthMM: Double?, fitVersusFilePercent: Double?, crystal: String,
                 crystalSHA256: String?, kMax: Double, tolerancePercent: Double) {
        self.fileName = fileName; self.centreRow = centreRow; self.centreColumn = centreColumn; self.centreSource = centreSource
        self.calibration = calibration; self.deltaQ = deltaQ; self.wavelengthAngstroms = wavelengthAngstroms
        self.lengthPixels = lengthPixels; self.lengthMM = lengthMM; self.fitVersusFilePercent = fitVersusFilePercent
        self.crystal = crystal; self.crystalSHA256 = crystalSHA256; self.kMax = kMax; self.tolerancePercent = tolerancePercent
    }
}

package nonisolated enum DiffractionExport {
    package static let columns = "kind,number,R_px,q_per_A,d_A,family,d_listed_A,delta_percent,odds,verdict,calibrating"

    package static func text(rows: [DiffractionReadoutRow], header h: DiffractionExportHeader) -> String {
        func g(_ v: Double?) -> String { v.map { String(format: "%.9g", $0) } ?? "" }
        // A CIF whose data block names nothing, or only a VESTA placeholder, gives the crystal its file's base name, which may hold a line break.
        let crystal = CSVText.headerValue(h.crystal) + (h.crystalSHA256.map { " sha256 \($0)" } ?? "")
        var lines = [
            "# macEM diffraction readout",
            "# file: \(CSVText.headerValue(h.fileName))",
            "# centre: row \(g(h.centreRow)), column \(g(h.centreColumn)) (\(h.centreSource))",
            "# calibration: \(h.calibration); delta_q \(g(h.deltaQ)) per A per px; wavelength \(g(h.wavelengthAngstroms)) A; L \(g(h.lengthPixels)) px; L \(g(h.lengthMM)) mm; fit versus file \(g(h.fitVersusFilePercent)) %",
            "# crystal: \(crystal); k_max \(g(h.kMax)) per A; tolerance \(g(h.tolerancePercent)) % of q",
        ]
        lines.append(columns)
        for r in rows {
            lines.append([r.kind.rawValue, "\(r.number)", g(r.radiusPx), g(r.q), g(r.d), CSVText.quoted(r.family ?? ""), g(r.dListed),
                          g(r.deltaPercent), CSVText.quoted(r.oddsText ?? ""), CSVText.quoted(r.verdict),
                          r.isCalibrating ? "yes" : ""].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
