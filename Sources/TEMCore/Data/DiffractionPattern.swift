import Foundation
import ImagoCore

/// A float image and its display normalisation; the arithmetic is ImagoKit's `DisplayNormalization`.
package nonisolated struct FloatImage {
    package let width: Int
    package let height: Int
    package let pixels: [Float]

    /// Min/max over the finite values only (`DisplayNormalization.finiteMinMax`).
    package nonisolated var minMax: (Float, Float) { DisplayNormalization.finiteMinMax(pixels) }

    /// Sentinel for invalid (masked / non-finite) pixels in display-normalized
    /// space. Valid pixels normalize into [0,1]; renderers (the Metal fragment
    /// shader and the PNG export colormap) show negative values as an explicit
    /// masked color instead of a colormap entry.
    package nonisolated static let invalidDisplayValue: Float = DisplayNormalization.invalidValue

    /// Linearly normalize to [0, 1]; centred on zero if symmetric. Non-finite pixels map to `invalidDisplayValue`.
    package nonisolated func normalized(symmetric: Bool = false) -> [Float] {
        DisplayNormalization.normalized(pixels, symmetric: symmetric)
    }

    // Explicit so the memberwise initializer is `package` (synthesized ones are internal).
    package nonisolated init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

package nonisolated struct DiffractionPattern {
    package let qy: Int
    package let qx: Int
    package let pixels: [Float]

    /// Normalize for display. CBED patterns span many orders of magnitude, so log display is useful.
    package nonisolated func normalized(useLog: Bool) -> [Float] {
        useLog ? DisplayNormalization.normalizedLog(pixels) : DisplayNormalization.normalized(pixels)
    }

    // Explicit so the memberwise initializer is `package` (synthesized ones are internal).
    package nonisolated init(qy: Int, qx: Int, pixels: [Float]) {
        self.qy = qy
        self.qx = qx
        self.pixels = pixels
    }
}
