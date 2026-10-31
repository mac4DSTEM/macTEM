//
//  ResultsLedger.swift
//  Role: every finished measurement of one open file, as `ResultRow`s for the Results room. DERIVED, NEVER STORED: each call reads the owners — the
//        marks (`ImageMeasurements`) and the FFT spots (`FFTAnalysis`) — and builds the rows again, so a mark moved, a spot
//        re-measured or a file closed is the next call's answer and no copy can go stale. It makes no number: TEMCore's
//        builders (`ResultRow`) take the owners' values and the file's axes.
//
//        ORDER is creation order inside a group (the marks as the owner lists them, the spots as the FFT room numbered them),
//        never sorted by value; groups follow `ResultRow.Group.allCases`. A spot still measuring is absent (it has no
//        result yet); a refused one, or one with no peak, is listed with its reason (a refusal is a result a reader needs). A
//        mark drawn and not yet saved is listed (its `lineage` is nil until the record has its node). The calibration and the
//        rings join when the Diffraction room exists: the group enum is the one place to add them, and `rows` switches over it
//        exhaustively, so a group without a source does not compile.
//

import Foundation
import ImagoCore
import SpectroEDX
import TEMCore

package enum ResultsLedger {

    /// The EDS room's finished fit of one region of this file: the window holds one EDS document, so the app hands it in only when it
    /// is this file's (`AppState.edsFitBelongs`).
    package struct EDSResults {
        package let regionName: String
        package let fit: PooledQuantification

        package init(regionName: String, fit: PooledQuantification) {
            self.regionName = regionName
            self.fit = fit
        }
    }

    /// The selected file's rows; none while the file holds no pixels (cold, or still being read).
    package static func rows(of item: OpenItem, eds: EDSResults? = nil) -> [ResultRow] {
        guard let image = item.session.image else { return [] }
        return rows(image: image, measurements: item.measurements, analysis: item.fft, diffraction: item.diffraction, eds: eds)
    }

    /// All the rows of `image`'s owners, group by group.
    package static func rows(image: CalibratedImage, measurements: ImageMeasurements, analysis: FFTAnalysis,
                             diffraction: DiffractionAnalysis? = nil, eds: EDSResults? = nil) -> [ResultRow] {
        let diffractionRows = diffraction?.resultRows(image: image) ?? []
        return ResultRow.Group.allCases.flatMap { group -> [ResultRow] in
            switch group {
            case .marks: markRows(image: image, measurements: measurements)
            case .spots: spotRows(image: image, analysis: analysis)
            case .calibration: diffractionRows.filter { $0.group == .calibration }
            case .rings: diffractionRows.filter { $0.group == .rings }
            case .eds: eds.map(edsRows) ?? []
            }
        }
    }

    // MARK: Marks

    private static func markRows(image: CalibratedImage, measurements: ImageMeasurements) -> [ResultRow] {
        var counts: [ImageMark.Kind: Int] = [:]
        return measurements.marks.compactMap { mark in
            counts[mark.kind, default: 0] += 1
            let id = "mark:\(mark.id.uuidString)"
            let label = "\(name(mark.kind)) \(counts[mark.kind] ?? 0)"
            let lineage = measurements.nodeID(of: mark.id)
            let p = mark.points
            guard p.count == mark.kind.pointCount else { return nil }
            switch mark.kind {
            case .distance:
                return .distance(id: id, label: label, a: p[0], b: p[1], x: image.x, y: image.y, lineage: lineage)
            case .angle:
                return .angle(id: id, label: label, a: p[0], vertex: p[1], c: p[2], x: image.x, y: image.y, lineage: lineage)
            case .profile:
                return .profile(id: id, label: label, a: p[0], b: p[1], width: mark.width, x: image.x, y: image.y,
                                lineage: lineage)
            }
        }
    }

    private static func name(_ kind: ImageMark.Kind) -> String {
        switch kind {
        case .distance: "Distance"
        case .angle: "Angle"
        case .profile: "Profile"
        }
    }

    // MARK: EDS

    /// One row per element of the fit, in the fit's order.
    private static func edsRows(_ eds: EDSResults) -> [ResultRow] {
        eds.fit.rows.map { row in
            .edsComposition(id: "eds:\(eds.regionName):\(row.element):\(row.groupID)", row: row, regionName: eds.regionName,
                            abundanceRefusal: eds.fit.abundanceRefusal, abundanceCaveat: eds.fit.abundanceCaveat)
        }
    }

    // MARK: FFT spots

    private static func spotRows(image: CalibratedImage, analysis: FFTAnalysis) -> [ResultRow] {
        analysis.spots.compactMap { spot in
            let id = "spot:\(spot.id.uuidString)"
            // The region the spot's own spectrum was transformed from (its key), not the region the room shows now.
            let region = spot.spectrumKey.crop.map { ResultRow.Region(col: $0.col, row: $0.row, width: $0.width, height: $0.height) }
                ?? ResultRow.Region(col: 0, row: 0, width: image.width, height: image.height)
            switch spot.outcome {
            case .measuring:
                return nil
            case .measured(let measured):
                return .spot(id: id, number: spot.number, measured: measured, region: region)
            case .refused(let failure):
                return .unmeasuredSpot(id: id, number: spot.number, clickRow: spot.row, clickCol: spot.col, region: region,
                                       reason: ResultRow.reason(failure))
            }
        }
    }
}
