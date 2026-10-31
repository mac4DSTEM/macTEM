// Opening a low-loss EELS spectrum image: a GMS .dm4 with an EELS spectrum-image object (FormatoKit's `DM4Experiment.readEELSSpectrumImage`)
// or a Velox.emd with an EELS stream (`VeloxSpectrumImageSignals`; NOT yet verified on a real Velox EELS file).
// The counts stay as stored. What the file states (E0, the two angles) rides along for the mean free path; nothing is assumed.
import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import SpectroEELS

/// One EELS cube of a file before its role is known: its energy window decides (a window that holds 0 eV is a low loss, one that starts above
/// it a core loss).
private nonisolated struct EELSCube {
    let nx: Int, ny: Int, channels: Int
    let counts: [Double]
    let offsetEV: Double, scaleEV: Double
    let origin: String
    var holdsZeroLoss: Bool { offsetEV <= 0 && offsetEV + scaleEV * Double(channels - 1) >= 0 }
}

/// A low-loss spectrum image with what its file says about the instrument.
package struct LoadedEELS: Sendable {
    package let fileName: String
    package let image: LowLossSpectrumImage
    package let beamEnergyKeV: Double?
    package let convergenceMrad: Double?
    package let collectionMrad: Double?
    /// "GMS DM4 object 3 (EELS)" and the like: where the cube came from.
    package let origin: String
    /// The file's core-loss cube, when it holds one next to the low loss (a Dual-EELS file): same scan, its own energy window. The room
    /// aligns it with the low loss, and the edge model fits it.
    package let coreLoss: CoreLossSpectrumImage?
    /// Where the core loss came from, in words, or nil.
    package let coreLossOrigin: String?
    /// The scan's pixel size along x and its unit as the file states them ("µm" in a GMS file: `ImageData.Calibrations.Dimension.1`, FormatoKit's `xAxis`,
    /// RosettaSciIO's x axis `scale` and `units`); nil where the file states none. The maps' scale bar and the "Maps…" export draw from it.
    package let scanPixelSize: Double?
    package let scanPixelUnit: String?

    package init(fileName: String, image: LowLossSpectrumImage, beamEnergyKeV: Double?, convergenceMrad: Double?, collectionMrad: Double?, origin: String,
                 coreLoss: CoreLossSpectrumImage? = nil, coreLossOrigin: String? = nil, scanPixelSize: Double? = nil, scanPixelUnit: String? = nil) {
        self.fileName = fileName; self.image = image; self.beamEnergyKeV = beamEnergyKeV
        self.convergenceMrad = convergenceMrad; self.collectionMrad = collectionMrad; self.origin = origin
        self.coreLoss = coreLoss; self.coreLossOrigin = coreLossOrigin
        self.scanPixelSize = scanPixelSize; self.scanPixelUnit = scanPixelUnit
    }
}

package enum EELSOpeningError: Error, Equatable, LocalizedError {
    case notEELS(String)
    case unsupportedShape(String)

    package var errorDescription: String? {
        switch self {
        case .notEELS(let name): "\(name) holds no EELS spectrum image."
        case .unsupportedShape(let why): why
        }
    }
}

package enum EELSOpening {
    package static let readableExtensions = ["dm4", "emd"]

    /// Reads the EELS spectrum images of the file and gives each its role by its energy window: the first that holds 0 eV is the low loss (what the
    /// thickness map and the zero-loss alignment work on), the first that starts above it is the core loss (what the edge model fits). A file with
    /// one cube and no zero loss opens as the low loss, as before (its t/λ says why it has none). Off the main actor; the kit's reasons come through in its words.
    package static func open(url: URL) throws -> LoadedEELS {
        let name = url.lastPathComponent
        var beam: Double?, convergence: Double?, collection: Double?
        var pixel: (size: Double, unit: String)?
        var cubes: [EELSCube] = []
        switch url.pathExtension.lowercased() {
        case "dm4":
            let objects = try DM4Experiment.list(path: url.path).filter { $0.role == .eels }
            guard !objects.isEmpty else { throw EELSOpeningError.notEELS(name) }
            var firstFailure: (any Error)?
            for object in objects {
                // An EELS object that is not a spectrum image in eV (a GMS "energy in nm" stack) is skipped while another reads; if none does, its reason is raised.
                let si: DM4EELSSpectrumImage
                do { si = try DM4Experiment.readEELSSpectrumImage(path: url.path, index: object.index) } catch { firstFailure = firstFailure ?? error; continue }
                if beam == nil { beam = si.beamEnergyKeV; convergence = si.convergenceSemiAngleMrad; collection = si.collectionSemiAngleMrad }
                if pixel == nil, let x = si.xAxis, x.scale > 0, !x.units.isEmpty { pixel = (x.scale, x.units) }
                cubes.append(EELSCube(nx: si.nx, ny: si.ny, channels: si.channels, counts: si.counts.map { Double($0) },
                                      offsetEV: -si.energyAxis.origin * si.energyAxis.scale, scaleEV: si.energyAxis.scale,
                                      origin: "GMS DM4 object \(object.index) (EELS)"))
            }
            if cubes.isEmpty, let firstFailure { throw firstFailure }
        case "emd":
            let signals = try VeloxSpectrumImageSignals(path: url.path).signals.filter { $0.signalType == "EELS" }
            guard !signals.isEmpty else { throw EELSOpeningError.notEELS(name) }
            for (i, signal) in signals.enumerated() {
                guard signal.data.shape.count == 3, signal.axes.count == 3 else {
                    throw EELSOpeningError.unsupportedShape("\(name): the EELS signal has \(signal.data.shape.count) dimensions, a spectrum image needs three.")
                }
                let axis = signal.axes[2]
                guard axis.units == "eV" else { throw EELSOpeningError.unsupportedShape("\(name): the energy axis is in \"\(axis.units)\", not eV.") }
                if beam == nil, let kv = signal.metadata["Acquisition_instrument.TEM.beam_energy"]?.value.number, kv > 0 { beam = kv }
                if pixel == nil, signal.axes[1].scale > 0, !signal.axes[1].units.isEmpty { pixel = (signal.axes[1].scale, signal.axes[1].units) }
                cubes.append(EELSCube(nx: signal.data.shape[1], ny: signal.data.shape[0], channels: signal.data.shape[2], counts: signal.data.doubles(),
                                      offsetEV: axis.offset, scaleEV: axis.scale, origin: "Velox EMD (EELS stream \(i + 1) of \(signals.count))"))
            }
        default:
            throw EELSOpeningError.notEELS(name)
        }
        let low = cubes.first(where: \.holdsZeroLoss) ?? cubes[0]
        let core = cubes.first(where: { !$0.holdsZeroLoss && $0.offsetEV > 0 && $0.nx == low.nx && $0.ny == low.ny && $0.origin != low.origin })
        let image = try LowLossSpectrumImage(nx: low.nx, ny: low.ny, channels: low.channels, counts: low.counts, energyOffsetEV: low.offsetEV, energyScaleEV: low.scaleEV)
        let coreImage = try core.map { try CoreLossSpectrumImage(nx: $0.nx, ny: $0.ny, channels: $0.channels, counts: $0.counts, energyOffsetEV: $0.offsetEV, energyScaleEV: $0.scaleEV) }
        return LoadedEELS(fileName: name, image: image, beamEnergyKeV: beam, convergenceMrad: convergence, collectionMrad: collection, origin: low.origin,
                          coreLoss: coreImage, coreLossOrigin: core?.origin, scanPixelSize: pixel?.size, scanPixelUnit: pixel?.unit)
    }
}
