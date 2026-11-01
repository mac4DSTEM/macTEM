// Open reads a file by what it holds, not by the room the user happens to be in: `FileInventory` lists the datasets of a file (an image to
// draw, an EDS spectrum image, an EELS spectrum image, a single spectrum) from FormatoKit's sniff and group names, and the app opens the
// file into every room that has data in it and lands in the room of the richest one (a spectrum cube before an image). The sniff of an HDF5
// file takes the HDF5 lock, so it runs off the main actor. A multi-page TIFF keeps the stack path (`ImageStackSource`).
import Foundation
import Formato
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoMSA
import SpectroCore

/// What a file holds, and so which rooms an Open fills.
package nonisolated struct FileInventory: Equatable, Sendable {
    /// An image to draw: the Image, FFT, Diffraction and Results rooms.
    package var image = false
    /// An EDS spectrum image: the EDS room.
    package var edsSpectrumImage = false
    /// An EELS spectrum image: the EELS room.
    package var eelsSpectrumImage = false
    /// One spectrum (an `.msa`, a Velox file of spectra and nothing else), opened in the EDS room as a one-pixel spectrum image.
    package var singleSpectrum = false
    /// Set instead of the above when the file is not opened here: the sentence says what it is and where it goes.
    package var refusal: String?

    package init(image: Bool = false, edsSpectrumImage: Bool = false, eelsSpectrumImage: Bool = false, singleSpectrum: Bool = false, refusal: String? = nil) {
        self.image = image; self.edsSpectrumImage = edsSpectrumImage; self.eelsSpectrumImage = eelsSpectrumImage
        self.singleSpectrum = singleSpectrum; self.refusal = refusal
    }

    /// The room an Open lands in: the richest dataset the file holds (a spectrum cube before an image).
    package enum Landing: Equatable, Sendable {
        case eds, eels, image
        /// The richer dataset wins when several files are opened together.
        package var richness: Int { switch self { case .eds: 3; case .eels: 2; case .image: 1 } }
    }

    package var landing: Landing? {
        if edsSpectrumImage || singleSpectrum { return .eds }
        if eelsSpectrumImage { return .eels }
        return image ? .image : nil
    }

    /// Opens in the EDS room: a spectrum cube, or one spectrum as a one-pixel cube.
    package var opensInEDS: Bool { edsSpectrumImage || singleSpectrum }
}

package nonisolated enum FileRouting {
    /// Every extension an Open routes somewhere (an image, an EDS or EELS spectrum image, a single spectrum), each once:
    /// what the Open panel offers, a drop takes, and the app declares as document types for Finder's Open With.
    package static let openableExtensions: [String] = {
        var seen = Set<String>()
        return (ImageOpening.readableExtensions + EDXOpening.readableExtensions + EELSOpening.readableExtensions)
            .filter { seen.insert($0).inserted }
    }()

    package struct SpectrumReadError: Error, LocalizedError, Equatable {
        package var text: String
        package var errorDescription: String? { text }
    }

    /// What `path` holds. Reads the first bytes and, for a Velox file, its group names (one HDF5 open), for a DM4 its object list (header
    /// only): run it off the main actor.
    package static func inventory(path: String) -> FileInventory {
        let name = (path as NSString).lastPathComponent
        switch FormatoLoader.sniff(path: path) {
        case .digitalMicrograph:
            var found = FileInventory(image: true)
            if path.lowercased().hasSuffix(".dm4"), let objects = try? DM4Experiment.list(path: path) {
                found.edsSpectrumImage = SpectrumImageOpener.kind(ofFileAt: path) != .other
                found.eelsSpectrumImage = objects.contains { $0.role == .eels }
                // A file of spectrum cubes alone has no image to draw (a GMS thumbnail or survey is one).
                found.image = objects.isEmpty || objects.contains { $0.role != .eels && $0.role != .eds }
            }
            return found
        case .tiff, .mrc: return FileInventory(image: true)
        case .msa: return FileInventory(singleSpectrum: true)
        case .veloxEMD:
            guard let held = VeloxEMDReader.contents(path: path) else { return FileInventory(image: true) }   // the reader says in words what the file lacks
            var found = FileInventory(image: held.images > 0, edsSpectrumImage: held.edsSpectrumImages > 0, eelsSpectrumImage: held.eelsSpectrumImages > 0)
            // Spectra only when there is nothing else to open (the spectra of a spectrum-image file are inside its cube).
            if held.spectra > 0, !found.image, !found.edsSpectrumImage, !found.eelsSpectrumImage { found.singleSpectrum = true }
            if !found.image, !found.edsSpectrumImage, !found.eelsSpectrumImage, !found.singleSpectrum { found.image = true }
            return found
        case .empad, .merlinMIB, .hdf5:
            return FileInventory(refusal: "\(name) is a 4D dataset or an HDF5 file that is not a Velox file: macTEM opens images and spectra; open it in mac4DSTEM.")
        case .unknown:
            return FileInventory(refusal: "\(name) is not a format macTEM opens (or its extension and its first bytes disagree).")
        }
    }

    /// Whether `path` is a single spectrum the EDX room opens (`.msa`, or a Velox file of spectra).
    package static func isSingleSpectrum(path: String) -> Bool {
        let kind = FormatoLoader.sniff(path: path)
        return kind == .msa || (kind == .veloxEMD && inventory(path: path).singleSpectrum)
    }

    /// The single spectrum in `path` as a 1 x 1 spectrum image on a keV axis. Counts are rounded to whole counts (a spectrum with negative or
    /// non-finite values is refused); the beam energy is the file's when it states one.
    package static func spectrumFile(path: String) throws -> LoadedSpectrumImage {
        let name = (path as NSString).lastPathComponent
        let signal: FormatoSignal
        switch FormatoLoader.sniff(path: path) {
        case .msa: signal = try MSAReader.read(path: path).signal
        case .veloxEMD:
            guard let first = try VeloxSpectrumSignals(path: path).signals.first(where: { $0.axes.count == 1 }) else {
                throw SpectrumReadError(text: "\(name) holds no single spectrum.")
            }
            signal = first
        default: throw SpectrumReadError(text: "\(name) is not a single spectrum.")
        }
        guard let axis = signal.axes.first else { throw SpectrumReadError(text: "The spectrum has no energy axis.") }
        let values = signal.data.doubles()
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SpectrumReadError(text: "The spectrum holds negative or non-finite values: it is not a count spectrum.")
        }
        // Axes are eV unless the file says keV.
        let toKeV = axis.units.lowercased() == "kev" ? 1.0 : 0.001
        let energyAxis = EnergyAxis(offset: axis.offset * toKeV, scale: axis.scale * toKeV, size: values.count)
        guard energyAxis.scale > 0 else { throw SpectrumReadError(text: "The spectrum's channel width is not positive.") }
        var meta = SpectrumImageMetadata(fileName: name, filePath: path, scanWidth: 1, scanHeight: 1, channelCount: values.count,
                                         energyOffsetEV: axis.offset * toKeV * 1000, energyDispersionEV: axis.scale * toKeV * 1000)
        if let beam = signal.metadata["Acquisition_instrument.TEM.beam_energy"]?.value.number, beam > 0 { meta.beamEnergyKeV = beam }
        let counts = values.map { UInt32(min($0.rounded(), Double(UInt32.max))) }
        return LoadedSpectrumImage(image: DenseSpectrumImage(ny: 1, nx: 1, channels: values.count, counts: counts), metadata: meta, energyAxis: energyAxis)
    }
}
