// Align's options in the Processing section: the search window for the zero-loss peak (Signal range) and whether the channels a shift left undefined
// are dropped (Crop). They are exSpy align_zero_loss_peak's `signal_range` and `crop`, SpectroKit `ZeroLossAlignmentOptions.signalRangeEV` and `.crop`.
// The kit's other options (calibrate, subpixel, interpolation points) stay at its defaults: the room offers no row for them.
import Foundation
import SpectroCore
import SpectroEELS

package nonisolated struct EELSAlignChoice: Equatable, Sendable {
    /// ±5 eV about 0: over the whole axis a noisy pixel's maximum is anywhere, and its shift empties the cropped axis.
    package static let defaultSignalRangeEV: ClosedRange<Double> = -5...5

    package var signalRangeEV: ClosedRange<Double>
    package var crop: Bool

    package init(signalRangeEV: ClosedRange<Double> = Self.defaultSignalRangeEV, crop: Bool = true) {
        self.signalRangeEV = signalRangeEV; self.crop = crop
    }

    /// The kit's options for a low loss whose axis runs from `axisLowEV` to `axisHighEV`: the window cut to the axis; a window that misses the axis
    /// leaves the kit's whole axis.
    package func kitOptions(axisLowEV: Double, axisHighEV: Double) -> ZeroLossAlignmentOptions {
        var options = ZeroLossAlignmentOptions(crop: crop)
        let lo = max(axisLowEV, signalRangeEV.lowerBound), hi = min(axisHighEV, signalRangeEV.upperBound)
        if lo < hi { options.signalRangeEV = lo...hi }
        return options
    }

    package func kitOptions(for low: LowLossSpectrumImage) -> ZeroLossAlignmentOptions {
        kitOptions(axisLowEV: low.energyOffsetEV, axisHighEV: low.energyOffsetEV + low.energyScaleEV * Double(low.channels - 1))
    }
}
