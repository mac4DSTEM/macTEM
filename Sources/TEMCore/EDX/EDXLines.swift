// Lines drawn on the EDX maps (design 2026-10-22 §2.1): a segment in pixels of the scan grid, and the profile of a map along it. The sampling is
// ImagoKit's `LineProfile` (bilinear, the mean across the width, float64 arithmetic; the same call the Image room's line tool makes); this file chooses
// the inputs: a map's values as a micrograph, and the scan grid's pixel-centre convention (pixel i covers [i, i+1), its centre is i + 0.5).
import Foundation
import ImagoCore
import SpectroEDX

package struct EDXLine: Equatable, Identifiable, Sendable {
    package var id: UUID
    package var name: String
    package var number: Int
    package var color: EDXPinColor?
    package var isVisible: Bool
    package var from: SpectroEDX.PixelPoint
    package var to: SpectroEDX.PixelPoint
    package init(id: UUID = UUID(), name: String, number: Int, from: SpectroEDX.PixelPoint, to: SpectroEDX.PixelPoint, color: EDXPinColor? = nil, isVisible: Bool = true) {
        self.id = id; self.name = name; self.number = number; self.from = from; self.to = to; self.color = color; self.isVisible = isVisible
    }

    /// Length in scan pixels.
    package var length: Double { ((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y)).squareRoot() }
}

package enum EDXLineProfiles {
    /// The profile of `values` (a `width` x `height` map, row-major) along `line`, `linewidth` pixels wide: positions in scan pixels from the start and the
    /// mean across the width at each. Empty when the line is shorter than a pixel or the kit refuses it (a non-finite end).
    package static func profile(values: [Double], width: Int, height: Int, along line: EDXLine, linewidth: Int = 1) -> (positions: [Double], samples: [Double]) {
        guard width > 0, height > 0, values.count == width * height, line.length >= 1,
              let image = try? Micrograph(width: width, height: height, pixels: values.map { Float($0) }),
              let p = try? LineProfile.sample(image, from: ImagoCore.PixelPoint(x: line.from.x - 0.5, y: line.from.y - 0.5),
                                              to: ImagoCore.PixelPoint(x: line.to.x - 0.5, y: line.to.y - 0.5), linewidth: max(1, linewidth),
                                              order: .linear, mode: .reflect, reduce: .mean, arithmetic: .float64) else { return ([], []) }
        return (p.positions, p.samples)
    }
}
