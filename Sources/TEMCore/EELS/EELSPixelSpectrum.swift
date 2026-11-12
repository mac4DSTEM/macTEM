// The hovered pixel's spectra (control placement §7: ⌥ while hovering a map adds the pixel's spectrum to the plot as a thin layer until the key is
// released). A read, not a number of macTEM's own: the pixel's stored counts, sliced out of the kit's cube in its own layout
// (`counts[(y * nx + x) * channels + c]`, SpectroKit `LowLossSpectrumImage` and `CoreLossSpectrumImage`), on the cube's own energy axis.
import Foundation
import SpectroCore
import SpectroEELS

/// A map pixel the pointer is over, in scan pixels.
package nonisolated struct EELSHoverPixel: Equatable, Sendable {
    package let x: Int
    package let y: Int
    package init(x: Int, y: Int) { self.x = x; self.y = y }
}

package nonisolated enum EELSPixelSpectrum {
    /// The low loss of pixel (`x`, `y`) as stored; nil off the scan.
    package static func low(_ image: LowLossSpectrumImage, x: Int, y: Int) -> EELSPlotCurve? {
        slice(image.storedCounts, nx: image.nx, ny: image.ny, channels: image.channels, x: x, y: y)
            .map { EELSPlotCurve(origin: image.energyOffsetEV, step: image.energyScaleEV, counts: $0) }
    }

    /// The core loss of pixel (`x`, `y`) as stored; nil off the scan, or when `answered` (a deconvolution's pixels with an answer) leaves the pixel out:
    /// the kit's zeros there are no spectrum.
    package static func core(_ image: CoreLossSpectrumImage, x: Int, y: Int, answered: PixelMask? = nil) -> EELSPlotCurve? {
        if let answered, answered.count == image.nx * image.ny, x >= 0, y >= 0, x < image.nx, y < image.ny, !answered[y * image.nx + x] { return nil }
        return slice(image.storedCounts, nx: image.nx, ny: image.ny, channels: image.channels, x: x, y: y)
            .map { EELSPlotCurve(origin: image.energyOffsetEV, step: image.energyScaleEV, counts: $0) }
    }

    /// One pixel's spectrum, read alone (a float32 cube is widened for this pixel only, never whole: macTEM#571).
    private static func slice(_ counts: EELSCounts, nx: Int, ny: Int, channels: Int, x: Int, y: Int) -> [Double]? {
        guard x >= 0, y >= 0, x < nx, y < ny, channels > 0 else { return nil }
        let start = (y * nx + x) * channels
        guard start + channels <= counts.count else { return nil }
        return counts.withRow(start: start, count: channels) { Array($0) }
    }
}
