// The EELS room's Info rows, as the EDS room's Info shows its file: the file, its grid and energy axes, the microscope, and the stage tilts and the
// instrument where the file states them. The beam energy names where it came from (the file, or typed, which wins), in SpectroKit's words
// (`BeamEnergySource.phrase`). Words only: every value is the file's or the person's, as read.
import Foundation
import SpectroCore
import SpectroEELS

/// One Info row: its label and its value.
package nonisolated struct EELSInfoRow: Equatable, Sendable, Identifiable {
    package let label: String
    package let value: String
    package var id: String { label }
    package init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

package nonisolated enum EELSInfoFormat {
    /// The rows in order; a row the file has no value for is left out.
    package static func rows(_ source: LoadedEELS, beamEnergyKeV: Double?, beamEnergySource: BeamEnergySource?,
                             locale: Locale = .autoupdatingCurrent) -> [EELSInfoRow] {
        func sig(_ v: Double, _ digits: Int) -> String { EELSRoomFormat.sig(v, digits, locale: locale) }
        // The file's axes as read, also after Align has replaced the cubes (`LoadedEELS.fileAxis`).
        let image = source.image, axis = source.fileAxis
        var out = [EELSInfoRow("File", source.fileName), EELSInfoRow("Read as", source.origin), EELSInfoRow("Scan", "\(image.nx) × \(image.ny) px"),
                   EELSInfoRow("Channels", "\(axis.channels)"),
                   EELSInfoRow("Energy axis", "\(sig(axis.offsetEV, 4)) eV + i × \(sig(axis.scaleEV, 4)) eV")]
        if let channels = axis.coreChannels, let offset = axis.coreOffsetEV {
            out.append(EELSInfoRow("Core loss", "\(channels) ch from \(sig(offset, 5)) eV"))
            if let origin = source.coreLossOrigin { out.append(EELSInfoRow("Core loss from", origin)) }
        }
        if let kv = beamEnergyKeV {
            out.append(EELSInfoRow("Beam", "\(sig(kv, 6)) keV" + (beamEnergySource.map { " · " + $0.phrase } ?? "")))
        }
        if let a = source.convergenceMrad { out.append(EELSInfoRow("Convergence", "\(sig(a, 6)) mrad")) }
        if let b = source.collectionMrad { out.append(EELSInfoRow("Collection", "\(sig(b, 6)) mrad")) }
        if let size = source.scanPixelSize, let unit = source.scanPixelUnit { out.append(EELSInfoRow("Scan pixel", "\(sig(size, 6)) \(unit)")) }
        if let a = source.alphaTiltDegrees { out.append(EELSInfoRow("Alpha tilt", "\(sig(a, 6))°")) }
        if let b = source.betaTiltDegrees { out.append(EELSInfoRow("Beta tilt", "\(sig(b, 6))°")) }
        if let i = source.instrument { out.append(EELSInfoRow("Instrument", i)) }
        return out
    }
}
