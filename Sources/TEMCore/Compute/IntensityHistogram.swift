//
//  IntensityHistogram.swift
//  Role: the Image room's histogram of the RAW pixels, on ImagoKit's `IntensityHistogram` (ImagoCore): the kit's
//        `compute(_:bins:range:)` is numpy's `np.histogram` of the finite pixels (gated by tools/parity/histogram-parity at
//        96 bins). What stays here is the room's choice of 96 bins.
//
//  Stays: ImagoKit 0.4.0 has no default-bins `compute` (checked 2026-10-21); delete `binCount` and `compute(_:)` if it gains one.
//

import ImagoCore

extension IntensityHistogram {
    /// The bins the room draws.
    package nonisolated static let binCount = 96

    /// The histogram of `pixels` over their finite range in `binCount` bins; nil when no pixel is finite.
    package nonisolated static func compute(_ pixels: [Float]) -> IntensityHistogram? {
        compute(pixels, bins: binCount)
    }
}
