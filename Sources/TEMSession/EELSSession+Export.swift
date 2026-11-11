//
//  EELSSession+Export.swift
//  Role: the EELS room's CSV, MSA and method JSON exports (the Maps… figure is the app's `EELSSession.figureContent`), made from
//        what the room shows: the t/λ map's diagnostics CSV, the results table as a CSV (the selected region's rows, else the whole
//        map's, with the thickness line, the fit's method footer, its deconvolution and its fit quality), the shown spectrum as a CSV
//        and as an EMSA/MAS file, the kept regions' rows, and the method JSON (the t/λ map, or why there is none, with the Deconvolve
//        stage's record and the edge fit's parameters). The state they read is `EELSSession`'s (EELSSession.swift).
//
//  Nothing here makes a number: the texts are `EELSExports`', `EELSCompute`'s, `EELSRoomFormat`'s and `EELSDeconvolveCompute`'s
//  (TEMCore/EELS), written from the numbers the stages put on screen and, in the MSA file, the microscope values the file states
//  or the user typed (the stage tilt is the file's, which nothing computes with).
//

import Foundation
import SpectroEELS
import TEMCore

extension EELSSession {
    // MARK: Export

    package var diagnosticsCSV: String? { map.map { EELSCompute.diagnosticsCSV($0, fileName: fileName) } }
    /// The results table as the room shows it (the plot's region): nil before a fit.
    package var resultsCSV: String? {
        let rows = resultRows
        guard !rows.isEmpty, let plot else { return nil }
        let posix = Locale(identifier: "en_US_POSIX")
        let thickness = EELSRoomFormat.thicknessLine(plot.thickness, lambdaNM: map?.meanFreePathNM, lambdaSource: EELSRoomFormat.lambdaSource(meanFreePath),
                                                     locale: Locale(identifier: "en_US_POSIX"))
        return EELSExports.resultsCSV(rows, fileName: fileName, regionName: plot.regionName, thickness: thickness, method: recordedFitFooter,
                                      deconvolution: modelDeconvolution.map(Self.deconvolutionRecord),
                                      quality: resultQuality.map { EELSRoomFormat.fitQuality($0, locale: posix) })
    }

    /// The deconvolution as the results CSV records it: the line (its FWHM in en_US_POSIX, as `parameters` writes `fwhm_eV`), then its
    /// parameters as key=value.
    private static func deconvolutionRecord(_ d: EELSDeconvolutionResult) -> String {
        EELSDeconvolveCompute.recordLine(d) + "; " + EELSDeconvolveCompute.parameters(d).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
    /// The shown spectrum (the selected region's, else the whole map's), with the model where the fit holds one.
    package var spectrumCSV: String? { plot.map { EELSExports.spectrumCSV($0, fileName: fileName) } }
    /// The kept regions' rows; nil without a region.
    package var regionsCSV: String? { pinRows.isEmpty ? nil : EELSExports.regionsCSV(pinRows, fileName: fileName) }
    /// Whether there is a method to record: a thickness map, an edge fit, or a file with only a core loss (whose record says it has no thickness).
    package var hasMethodRecord: Bool { hasImage && (onlyCoreLoss || map != nil || model != nil) }
    /// The method JSON (`EELSCompute.methodJSON`), with its SHA-256. A file with only a core loss records no thickness map, in the Maps control's words.
    package var methodJSON: String? {
        guard hasMethodRecord, let image = source?.image else { return nil }
        let thickness = onlyCoreLoss ? nil : map
        let why = thickness == nil ? (onlyCoreLoss ? nil : failure) ?? mapsAvailability.disabledReason(.tOverLambda) : nil
        return EELSCompute.methodJSON(thickness, fileName: fileName, origin: source?.origin ?? "", width: image.nx, height: image.ny, thicknessUnavailable: why,
                                      deconvolution: stageRecord, fit: fitParameters)
    }
    /// The shown spectrum as an EMSA/MAS file (`EELSExports.spectrumMSA`): the core loss when the file has one, else the low loss, with the beam energy and
    /// the angles the room uses and the stage tilt the file states. Nil before there is a spectrum.
    package func spectrumMSA() throws -> Data? {
        guard let plot else { return nil }
        let microscope = EELSExports.MSAMicroscope(beamEnergyKeV: beamEnergyKeV, convergenceMrad: typedConvergenceMrad ?? source?.convergenceMrad,
                                                   collectionMrad: typedCollectionMrad ?? source?.collectionMrad, alphaTiltDegrees: source?.alphaTiltDegrees)
        return try EELSExports.spectrumMSA(plot, fileName: fileName, microscope: microscope)
    }

    /// The Deconvolve stage as the method JSON records it: the chosen method's result with its parameters and whether it is current; nil when Off or not run.
    private var stageRecord: [String: Any]? {
        guard deconvolutionChoice != .off, let d = deconvolution, d.choice.kind == deconvolutionChoice.kind else { return nil }
        var record = EELSDeconvolveCompute.parameters(d)
        record["state"] = deconvolveState.word
        return record
    }
}
