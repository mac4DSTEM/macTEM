// PROVENANCE: mac4DSTEM df1e6c994ea5b49c7ec08737628631b204736974 mac4DSTEM/Core/Data/DiffractionPattern.swift verbatim
// END PROVENANCE
import Foundation

/// Min/max over the FINITE values only — a single NaN/Inf pixel (dead-pixel
/// correction, division artifacts) must not blank the display scaling.
package nonisolated func finiteMinMax(_ pixels: [Float]) -> (Float, Float) {
    var lo = Float.greatestFiniteMagnitude
    var hi = -Float.greatestFiniteMagnitude
    for v in pixels where v.isFinite {
        if v < lo { lo = v }
        if v > hi { hi = v }
    }
    guard lo <= hi else { return (0, 1) }
    return (lo, hi)
}

package nonisolated struct FloatImage {
    package let width: Int
    package let height: Int
    package let pixels: [Float]

    package nonisolated var minMax: (Float, Float) { finiteMinMax(pixels) }

    /// Sentinel for invalid (masked / non-finite) pixels in display-normalized
    /// space. Valid pixels normalize into [0,1]; renderers (the Metal fragment
    /// shader and the PNG export colormap) show negative values as an explicit
    /// masked color instead of a colormap entry.
    package nonisolated static let invalidDisplayValue: Float = -1

    /// Linearly normalize to [0, 1]. If symmetric, the scale is centered on
    /// zero. Non-finite pixels map to `invalidDisplayValue`, never to a valid
    /// color — "no data" must stay distinguishable from any real value.
    package nonisolated func normalized(symmetric: Bool = false) -> [Float] {
        let invalid = Self.invalidDisplayValue
        let (lo, hi) = minMax
        if symmetric {
            let magnitude = max(abs(lo), abs(hi))
            guard magnitude > 0 else {
                return pixels.map { $0.isFinite ? 0.5 : invalid }
            }
            return pixels.map { $0.isFinite ? 0.5 + 0.5 * ($0 / magnitude) : invalid }
        }

        let span = hi - lo
        guard span > 0 else { return pixels.map { $0.isFinite ? 0.0 : invalid } }
        return pixels.map { $0.isFinite ? ($0 - lo) / span : invalid }
    }

    // Explicit so the memberwise initializer is `package` (synthesized ones are internal). // v2.5 step 2b
    package nonisolated init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// A packed RGBA8 image for results that are inherently colored.
package nonisolated struct RGBAImage {
    package let width: Int
    package let height: Int
    package let rgba: [UInt8]

    // Explicit so the memberwise initializer is `package` (synthesized ones are internal). // v2.5 step 2b
    package nonisolated init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

package nonisolated struct DiffractionPattern {
    package let qy: Int
    package let qx: Int
    package let pixels: [Float]

    package nonisolated var minMax: (Float, Float) { finiteMinMax(pixels) }

    /// Normalize for display. CBED patterns span many orders of magnitude, so log display is useful.
    package nonisolated func normalized(useLog: Bool) -> [Float] {
        FloatImage(width: qx, height: qy,
                   pixels: contrastPixels(useLog: useLog)).normalized()
    }

    /// Values along the CBED contrast/histogram axis before [0,1]
    /// normalization. Log mode uses log10(1 + max(I, 0)).
    package nonisolated func contrastPixels(useLog: Bool) -> [Float] {
        guard useLog else { return pixels }
        return pixels.map {
            $0.isFinite ? Float(log10(1.0 + Double(max($0, 0)))) : 0
        }
    }

    package nonisolated var asFloatImage: FloatImage { FloatImage(width: qx, height: qy, pixels: pixels) }

    // Explicit so the memberwise initializer is `package` (synthesized ones are internal). // v2.5 step 2b
    package nonisolated init(qy: Int, qx: Int, pixels: [Float]) {
        self.qy = qy
        self.qx = qx
        self.pixels = pixels
    }
}
