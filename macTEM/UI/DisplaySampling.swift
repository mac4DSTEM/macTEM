//
//  DisplaySampling.swift
//  Role: a calibration as it is SHOWN. A file that states its pixel size in metres (the Velox and FEI SEM TIFF
//        conventions) is shown in nm, µm or mm: a TEM pixel of 4.46179e-11 m otherwise prints as
//        "0,0000000000446179 m/px" and its scale bar as "1e-08 m" (the shell drive, 2026-10-12). Display only:
//        `CalibratedImage` keeps the file's value and unit, and every other unit passes through unchanged, spelled
//        by `UnitDisplay.label`. The rescaling is ImagoKit's `ScaleBarMath.shown`.
//

import ImagoCore
import Foundation
#if canImport(TEMCore)
import TEMCore
#endif

nonisolated enum DisplaySampling {
    /// The spellings of the metre a file writes ("m" in Velox XML and FEI INI text).
    static func isMetres(_ unit: String) -> Bool { LengthUnit.nanometres(per: unit) == 1e9 }

    /// The unit a length of `metres` reads in: nm below 1 µm, µm below 1 mm, mm above (ImagoKit's `ScaleBarMath.shown` on a
    /// 1 m/px axis: its scale is the factor, its unit the label).
    static func unit(forMetres metres: Double) -> (perMetre: Double, label: String) {
        if metres == 0 { return (1e9, "nm") }
        let metre = ScaleBarMath.shown(AxisCalibration(scale: 1, unit: "m"), reference: abs(metres))
        return metre.isCalibrated && metre.unit != "m" ? (metre.scale, metre.unit) : (1e3, "mm")
    }

    /// A sampling row's axis: a metre axis in the unit its own pixel reads in (`ScaleBarMath.shown`, which rescales a metre
    /// axis into the unit a length of `reference` metres reads in and leaves any other axis unchanged).
    static func perPixel(_ axis: AxisCalibration?) -> AxisCalibration? {
        axis.map { ScaleBarMath.shown($0, reference: $0.scale) }
    }
}
