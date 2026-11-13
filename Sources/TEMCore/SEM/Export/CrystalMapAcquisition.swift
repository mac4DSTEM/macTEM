//
//  CrystalMapAcquisition.swift
//  Role: what the session knows about how a crystal map was acquired and made, for the .ang and .ctf headers (macEM#616): the
//        pattern centre, working distance, magnification, beam energy and sample tilt where the session has them, and the software
//        that wrote the file. A field the session does not know stays nil and the writer puts the format's own "unknown" (0).
//

import Foundation

package nonisolated struct CrystalMapAcquisition: Sendable, Equatable {
    /// The pattern centre in EDAX TSL's convention (x*, y*, z*), as the .ang header states it.
    package var patternCentreTSL: SIMD3<Double>?
    package var workingDistanceMM: Double?
    package var magnification: Double?
    package var beamEnergyKeV: Double?
    package var sampleTiltDegrees: Double?
    /// "macEM 2.1.0 (42) with FormatoKit 0.15.0, ImagoKit 0.9.2, ...": the build that wrote the file.
    package var software: String?

    package init(patternCentreTSL: SIMD3<Double>? = nil, workingDistanceMM: Double? = nil, magnification: Double? = nil,
                 beamEnergyKeV: Double? = nil, sampleTiltDegrees: Double? = nil, software: String? = nil) {
        self.patternCentreTSL = patternCentreTSL; self.workingDistanceMM = workingDistanceMM; self.magnification = magnification
        self.beamEnergyKeV = beamEnergyKeV; self.sampleTiltDegrees = sampleTiltDegrees; self.software = software
    }

    /// From a dataset and the pattern centre a run used (Bruker convention): the header the file carries and the detector's tilt.
    package init(dataset: EBSDDataset, projectionCenterBruker pc: SIMD3<Double>?, software: String?) {
        let finite = { (v: Double?) -> Double? in v.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        let tsl = pc.flatMap { p -> SIMD3<Double>? in
            let c = dataset.detector.center(p, in: .tsl)
            return c.x.isFinite && c.y.isFinite && c.z.isFinite ? c : nil
        }
        self.init(patternCentreTSL: tsl, workingDistanceMM: finite(dataset.sem.workingDistanceMM),
                  magnification: finite(dataset.sem.magnification), beamEnergyKeV: finite(dataset.sem.beamEnergyKeV),
                  sampleTiltDegrees: dataset.detector.sampleTilt.isFinite ? dataset.detector.sampleTilt : nil, software: software)
    }

    /// The names and versions of the Swift packages the app is built with ("FormatoKit 0.15.0, ImagoKit 0.9.2, ...").
    package static var kitVersions: String { SEMMethod.builtWith.map { "\($0.name) \($0.value)" }.joined(separator: ", ") }

    /// A number for a header: an integer without decimals, else up to 6 significant digits; 0 for none.
    package static func headerNumber(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        return String(format: "%.6g", v)
    }
}
