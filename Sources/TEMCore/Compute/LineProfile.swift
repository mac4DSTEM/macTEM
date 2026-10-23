//
//  LineProfile.swift
//  Role: the intensity along a line segment on a CalibratedImage, averaged across a width. The type and the numbers are
//        ImagoKit's `LineProfile` (order 1 (bilinear), mode "reflect", the mean across the width, float64 arithmetic;
//        tools/parity/profile-parity checks it against scikit-image 0.26.0).
//
//  What stays here is the seam, two answers that differ from the kit's, as the app's always did: a width below 1 is read as 1
//  (the kit throws), and a segment the kit refuses (a non-finite end, an end beyond 1e15 px, more than 2²⁴ samples) is an EMPTY
//  profile, not an error.
//

import ImagoCore

extension LineProfile {
    package nonisolated static func sample(_ image: CalibratedImage, from: ImagePoint, to: ImagePoint, width: Int) -> LineProfile {
        let w = max(1, width)
        if let p = try? sample(image.micrograph, from: from.pixelPoint, to: to.pixelPoint, linewidth: w,
                               order: .linear, mode: .reflect, reduce: .mean, arithmetic: .float64) {
            return p
        }
        let length = ImageMeasurement.distance(from, to, x: image.x, y: image.y)
        return LineProfile(samples: [], positions: [], unit: length.unit ?? "px", isPhysical: length.unit != nil, width: w)
    }
}

extension LineProfile: @retroactive Equatable {
    public static func == (a: LineProfile, b: LineProfile) -> Bool {
        a.samples == b.samples && a.positions == b.positions && a.unit == b.unit && a.isPhysical == b.isPhysical && a.width == b.width
    }
}
