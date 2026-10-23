//
//  CalibratedImage+Micrograph.swift
//  Role: the seam between macTEM's image and ImagoKit's (ADR 027). The kit's FFT, spectrum, profile, spot, masked-inverse and
//        filter functions read a `Micrograph`: the same Float32 pixels and the same per-axis calibration, without the file's
//        name, source, voltage and notes. The axes ARE the kit's `AxisCalibration`; it computes nothing, rounds nothing and guesses no unit.
//

import Foundation
import ImagoCore
import ImagoFFT

nonisolated extension CalibratedImage {
    /// The kit's image of these pixels and axes. `CalibratedImage` already holds the invariants `Micrograph` checks
    /// (positive size, `width * height` pixels), so the initialiser cannot throw.
    package var micrograph: Micrograph {
        do {
            return try Micrograph(width: width, height: height, pixels: pixels, x: x, y: y)
        } catch {
            preconditionFailure("CalibratedImage holds a size Micrograph refuses: \(error)")
        }
    }
}

nonisolated extension SpectrumValues {
    /// The values as Float32 pixels for drawing: a Float32 product as it is, a Float64 one rounded (as the kit's
    /// `HRTEMFilter.outputs` rounds). The room computes in the kit's default precision, `.float32`, so it never rounds.
    package var float32Values: [Float] {
        switch self {
        case .float32(let values): values
        case .float64(let values): values.map { Float($0) }
        }
    }
}
