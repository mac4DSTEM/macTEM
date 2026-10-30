//
//  FFTExport.swift
//  Role: the writers of the FFT room's export (V1-10 slice 2, archive: fft-export-design-2026-10-14.md): the radial profile
//        as a CSV, the measured spots as a CSV, and what the transform's PNG adds to `ImageExport` (its source with the
//        frequency steps as "axes", and its Description's "fft" block). Values in, text or bytes out; the app's snapshot
//        (macTEM/App/ExportSnapshot.swift) gathers the values from the room's owners when the panel opens.
//
//        EXACT: every number the products hold is written `%.17g` (`CSVText.number`), so a reader's `float()` is the
//        in-memory Double bit for bit; a "shown" column is that Double times the factor the app shows it with
//        (`FFTUnits`), one multiplication, restated by a reader. (No angle column: deferred, a derived number to be registered as tier 1.)
//
//        WHAT THE NUMBERS ARE: the transform and the radial profile are of the region's pixels as read, with NO window and
//        the mean NOT removed (`PowerSpectrum`); only the spot estimator works on a Hann-windowed, mean-removed copy
//        (`SpotMeasurement`). Each header says which.
//

import Foundation
import ImagoCore
import ImagoFFT

package nonisolated enum FFTExport {

    // MARK: The sentences

    package static let displayNote = "picture: v = log10(|F|^2 / (W*H)^2) per bin, the DC bin masked, normalised over the finite range, "
        + "then the window shown, grey, gamma 1"
    package static let transformValidation = "the transform compared with numpy 2.5.4 (ImagoKit's parity tests); display "
        + "rendering: log scaling, window, 8-bit grey, not intensities; the scale bar's length checked against its label (export-parity)"
    package static let profileValidation = "the radial profile compared with numpy 2.5.4 (ImagoKit's parity tests); "
        + "the calibration as the file states it"
    package static let spotsValidation = "the spot centroid compared with planted spots (ImagoKit's parity tests); the "
        + "calibration as the file states it"
    package static let lineage = "none \u{2014} the FFT room's state carries no lineage id; the region, spots and parameters "
        + "above stand in"

    // MARK: The transform's PNG

    /// The source `ImageExport.render` takes for the transform: the spectrum's own size, and the frequency steps in the
    /// shown unit as its "axes", so the scale bar is the screen's rule applied to |q|.
    package static func transformSource(_ h: FFTExportHeader) -> ExportSource {
        let ux = FFTUnits.spectrumUnit(h.unitsX), uy = FFTUnits.spectrumUnit(h.unitsY)
        return ExportSource(software: h.software, fileName: h.fileName, object: h.object, width: h.spectrumWidth,
                            height: h.spectrumHeight,
                            x: AxisCalibration(scale: h.spacingX * ux.factor, unit: ux.label, origin: 0),
                            y: AxisCalibration(scale: h.spacingY * uy.factor, unit: uy.label, origin: 0),
                            notes: h.notes)
    }

    /// The Description's "fft" block and the two sentences that replace the image export's.
    package static func transformProvenance(_ h: FFTExportHeader, spotsDrawn: Int) -> ImageExport.Provenance {
        let aspect = (Double(h.spectrumWidth) * h.spacingX) / (Double(h.spectrumHeight) * h.spacingY)
        return ImageExport.Provenance(
            fields: [
                "subject": FFTExportText.subject(crop: h.crop, imageWidth: h.imageWidth, imageHeight: h.imageHeight),
                "space": "reciprocal",
                "image": "\(h.imageWidth) x \(h.imageHeight) px",
                "file_x_scale": h.x.map { $0.isCalibrated ? "\($0.scale) \($0.unit) per px" : "none" } ?? "none",
                "file_y_scale": h.y.map { $0.isCalibrated ? "\($0.scale) \($0.unit) per px" : "none" } ?? "none",
                "dq_x": "\(CSVText.number(h.spacingX)) \(h.unitsX) per bin",
                "dq_y": "\(CSVText.number(h.spacingY)) \(h.unitsY) per bin",
                "transform": FFTExportText.transformNote,
                "display": displayNote,
                "pane_aspect": CSVText.number(aspect),
                "aspect_note": "the PNG is the bins, one square pixel each; the pane draws width*dq_x : height*dq_y (pane_aspect = "
                    + "the ratio); anisotropic compares dq_x with dq_y, which differ with the size alone",
                "spots_drawn": String(spotsDrawn),
            ],
            validation: transformValidation, lineage: lineage)
    }
}

// MARK: - The CSV writers (ImagoFFT's `RadialProfileCSV` and `SpotsCSV`)

extension RadialProfileCSV {
    /// The whole file (UTF-8, LF), or nil when no bin outside the DC holds a pixel (the chart draws none either).
    package nonisolated static func text(_ profile: RadialProfile, header h: FFTExportHeader) -> String? {
        text(profile, header: h, title: "macTEM radial profile", validation: FFTExport.profileValidation, lineage: FFTExport.lineage)
    }

    @concurrent package static func export(_ profile: RadialProfile, header: FFTExportHeader, to url: URL) async throws {
        guard let text = text(profile, header: header) else { throw ExportFile.Failure.noSamples }
        try ExportFile.write(Data(text.utf8), to: url)
    }
}

extension SpotsCSV {
    /// The whole file (UTF-8, LF), or nil without a row. `omitted`: spots in the list that have no numbers (measuring,
    /// refused, no peak, or of another region). `notes`: further sentences (the accuracy by size) written verbatim.
    package nonisolated static func text(rows: [Row], omitted: Int, maskRadius: Double, maskEdge: Double, notes: [String],
                                         header h: FFTExportHeader) -> String? {
        text(rows: rows, omitted: omitted, maskRadius: maskRadius, maskEdge: maskEdge, notes: notes, header: h,
             title: "macTEM spots", validation: FFTExport.spotsValidation, lineage: FFTExport.lineage)
    }

    @concurrent package static func export(rows: [Row], omitted: Int, maskRadius: Double, maskEdge: Double, notes: [String],
                                           header: FFTExportHeader, to url: URL) async throws {
        guard let text = text(rows: rows, omitted: omitted, maskRadius: maskRadius, maskEdge: maskEdge, notes: notes,
                              header: header) else { throw ExportFile.Failure.noSpots }
        try ExportFile.write(Data(text.utf8), to: url)
    }
}
