// Open reads a file by what it holds, not by the room the user happens to be in: `FileInventory` lists the datasets of a file (an image to
// draw, an EDS spectrum image, an EELS spectrum image, a single spectrum, an EBSD pattern dataset) from FormatoKit's sniff and group names, and the app opens the
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
    /// An EELS spectrum image, or one EELS spectrum (a GMS spectrum saved alone, an `.msa` of signal type ELS): the EELS room.
    package var eelsSpectrumImage = false
    /// One spectrum (an `.msa`, a Velox file of spectra and nothing else), opened in the EDS room as a one-pixel spectrum image.
    package var singleSpectrum = false
    /// An EBSD or TKD pattern dataset (an h5ebsd file of kikuchipy, Bruker, EDAX or Oxford; EDAX `.up1`/`.up2` or Oxford `.ebsp` with the map
    /// next to it): the Patterns room.
    package var ebsdPatterns = false
    /// An orientation map on its own (an `.ang` or `.ctf` without the pattern file of its name next to it): the Maps room. A map with its
    /// patterns is `ebsdPatterns`, and the Maps room shows it through the dataset.
    package var orientationMap = false
    /// Set instead of the above when the file is not opened here: the sentence says what it is and where it goes.
    package var refusal: String?
    /// The scan of a DM4 spectrum image, from its header: the size the file's Open Files row shows. The image the Image room draws from the
    /// same file is the survey (2048 x 2048 beside a 432 x 172 scan), so its size is not the scan's. Nil for any other file (a Velox
    /// spectrum image's image is the scan image itself).
    package var scan: Scan?

    /// A spectrum image's scan grid and its x sampling as the file writes it.
    package struct Scan: Equatable, Sendable {
        package var width: Int
        package var height: Int
        /// Units per scan pixel along x and the unit as written; nil when the file writes no calibration.
        package var xScale: Double?
        package var xUnit: String?

        package init(width: Int, height: Int, xScale: Double? = nil, xUnit: String? = nil) {
            self.width = width; self.height = height; self.xScale = xScale; self.xUnit = xUnit
        }
    }

    package init(image: Bool = false, edsSpectrumImage: Bool = false, eelsSpectrumImage: Bool = false, singleSpectrum: Bool = false,
                 ebsdPatterns: Bool = false, orientationMap: Bool = false, refusal: String? = nil, scan: Scan? = nil) {
        self.image = image; self.edsSpectrumImage = edsSpectrumImage; self.eelsSpectrumImage = eelsSpectrumImage
        self.singleSpectrum = singleSpectrum; self.ebsdPatterns = ebsdPatterns; self.orientationMap = orientationMap
        self.refusal = refusal; self.scan = scan
    }

    /// The room an Open lands in: the richest dataset the file holds (a spectrum cube before an image).
    package enum Landing: Equatable, Sendable {
        case patterns, maps, eds, eels, image
        /// The richer dataset wins when several files are opened together: patterns (which carry their map), then a map alone.
        package var richness: Int { switch self { case .patterns: 5; case .maps: 4; case .eds: 3; case .eels: 2; case .image: 1 } }
    }

    package var landing: Landing? {
        if ebsdPatterns { return .patterns }
        if orientationMap { return .maps }
        if edsSpectrumImage || singleSpectrum { return .eds }
        if eelsSpectrumImage { return .eels }
        return image ? .image : nil
    }

    /// Opens in the EDS room: a spectrum cube, or one spectrum as a one-pixel cube.
    package var opensInEDS: Bool { edsSpectrumImage || singleSpectrum }
}

package nonisolated enum FileRouting {
    /// Every extension an Open routes somewhere (an image, an EDS or EELS spectrum image, a single spectrum, EBSD patterns, an orientation map), each once:
    /// what the Open panel offers, a drop takes, and the app declares as document types for Finder's Open With.
    package static let openableExtensions: [String] = {
        var seen = Set<String>()
        return (ImageOpening.readableExtensions + EDXOpening.readableExtensions + EELSOpening.readableExtensions + EBSDOpening.readableExtensions)
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
        // SEM-EDS map files (Bruker, EDAX, JEOL; FormatoKit's sniff knows none of them), by extension: a spectrum image or one spectrum for
        // the EDS room, a JEOL image or element map for the Image room. The readers say in words what a file lacks when it is opened.
        if SEMEDSOpening.isImageFile(path: path) { return FileInventory(image: true) }
        if SEMEDSOpening.isSingleSpectrumFile(path: path) { return FileInventory(singleSpectrum: true) }
        if SEMEDSOpening.opensInEDS(path: path) { return FileInventory(edsSpectrumImage: true) }
        // HyperSpy's own HDF5 layout (`.hspy`, which FormatoKit's sniff does not know): one spectrum opens in the EDS room, anything else is
        // refused in the reader's words.
        if HyperSpySpectrumFile.isHyperSpyFile(path: path) {
            do { _ = try HyperSpySpectrumFile.header(path: path); return FileInventory(singleSpectrum: true) } catch {
                return FileInventory(refusal: (error as? LocalizedError)?.errorDescription ?? "\(name) is not a spectrum macTEM opens.")
            }
        }
        // A vendor's EBSD file (EDAX `.up1`/`.up2`/`.ang`, Oxford `.ebsp`/`.ctf`): FormatoKit's sniff knows none of them; the pattern file's header
        // decides (a map file counts when its patterns are next to it), and a refusal is the door's sentence.
        let url = URL(fileURLWithPath: path)
        if EBSDOpening.isVendorFile(url) {
            if EBSDOpening.isLoneMap(url) { return FileInventory(orientationMap: true) }
            if let why = EBSDOpening.vendorRefusal(url: url) { return FileInventory(refusal: why) }
            return FileInventory(ebsdPatterns: true)
        }
        let kind = FormatoLoader.sniff(path: path)
        // An h5ebsd file (kikuchipy, Bruker, EDAX, Oxford H5OINA): FormatoKit's sniff knows `.h5` as HDF5 and `.h5oina` not at all, so the
        // EBSD reader's own sniff decides for both (one HDF5 open). A `.h5` that is neither an EBSD scan nor a Velox file keeps its refusal.
        if kind == .hdf5 || (kind == .unknown && EBSDOpening.h5Extensions.contains(url.pathExtension.lowercased())),
           EBSDH5Reader.sniff(url: url) != nil {
            return FileInventory(ebsdPatterns: true)
        }
        switch kind {
        case .digitalMicrograph:
            var found = FileInventory(image: true)
            if path.lowercased().hasSuffix(".dm4"), let objects = try? DM4Experiment.list(path: path) {
                found.edsSpectrumImage = SpectrumImageOpener.kind(ofFileAt: path) != .other
                found.eelsSpectrumImage = objects.contains { $0.role == .eels }
                // A file of spectrum cubes alone has no image to draw (a GMS thumbnail or survey is one).
                found.image = objects.isEmpty || objects.contains { $0.role != .eels && $0.role != .eds }
                found.scan = scan(of: objects)
            }
            return found
        case .tiff, .mrc: return FileInventory(image: true)
        case .msa:
            // One spectrum: an EELS one (`#SIGNALTYPE ELS`) goes to the EELS room; any other (EDS, or a file the reader refuses, which the EDS room
            // then reports in its words) to the EDS room.
            if (try? MSAReader.read(path: path).signal.signalType) == "EELS" { return FileInventory(eelsSpectrumImage: true) }
            return FileInventory(singleSpectrum: true)
        case .veloxEMD:
            guard let held = VeloxEMDReader.contents(path: path) else { return FileInventory(image: true) }   // the reader says in words what the file lacks
            var found = FileInventory(image: held.images > 0, edsSpectrumImage: held.edsSpectrumImages > 0, eelsSpectrumImage: held.eelsSpectrumImages > 0)
            // Spectra only when there is nothing else to open (the spectra of a spectrum-image file are inside its cube).
            if held.spectra > 0, !found.image, !found.edsSpectrumImage, !found.eelsSpectrumImage { found.singleSpectrum = true }
            if !found.image, !found.edsSpectrumImage, !found.eelsSpectrumImage, !found.singleSpectrum { found.image = true }
            return found
        case .empad, .merlinMIB, .hdf5:
            return FileInventory(refusal: "\(name) is a 4D dataset or an HDF5 file that is neither a Velox file nor an EBSD scan: macTEM opens images, spectra and EBSD patterns; open it in mac4DSTEM.")
        case .unknown:
            // A `.dat` whose `Setting.txt` is there but may not be read (the sandbox granted the file, not its folder) says so.
            if let why = NORDIFOpening.unreadableSettingsRefusal(url) { return FileInventory(refusal: why) }
            return FileInventory(refusal: "\(name) is not a format macTEM opens (or its extension and its first bytes disagree).")
        }
    }

    /// The scan of a DM4 file's spectrum image (the EDS cube when there is one, as the landing room, else the first EELS cube): GMS writes a spectrum image's dimensions fastest first, [x, y, energy], as FormatoKit's spectrum-image readers take them.
    package static func scan(of objects: [DM4ImageObject]) -> FileInventory.Scan? {
        let cube = objects.first { $0.role == .eds && $0.dimensions.count == 3 } ?? objects.first { $0.role == .eels && $0.dimensions.count == 3 }
        guard let cube, cube.dimensions[0] > 0, cube.dimensions[1] > 0 else { return nil }
        let x = cube.axes.first.flatMap { $0 }
        let calibrated = x.map { $0.scale > 0 && !$0.units.isEmpty } ?? false
        return FileInventory.Scan(width: cube.dimensions[0], height: cube.dimensions[1],
                                  xScale: calibrated ? x?.scale : nil, xUnit: calibrated ? x?.units : nil)
    }

    /// Whether `path` is a single spectrum the EDX room opens (an `.msa` that is not EELS, or a Velox file of spectra).
    package static func isSingleSpectrum(path: String) -> Bool {
        if SEMEDSOpening.isSingleSpectrumFile(path: path) { return true }
        if HyperSpySpectrumFile.isHyperSpyFile(path: path) { return inventory(path: path).singleSpectrum }
        let kind = FormatoLoader.sniff(path: path)
        return (kind == .msa || kind == .veloxEMD) && inventory(path: path).singleSpectrum
    }

    /// The single spectrum in `path` as a 1 x 1 spectrum image on a keV axis. Counts are rounded to whole counts (a spectrum with negative or
    /// non-finite values is refused); the beam energy is the file's when it states one.
    package static func spectrumFile(path: String) throws -> LoadedSpectrumImage {
        let name = (path as NSString).lastPathComponent
        if SEMEDSOpening.isSingleSpectrumFile(path: path) { return try SEMEDSOpening.open(url: URL(fileURLWithPath: path)) }
        if HyperSpySpectrumFile.isHyperSpyFile(path: path) {
            let spectrum = try HyperSpySpectrumFile.read(path: path)
            return try onePixel(name: name, path: path, values: spectrum.counts, offset: spectrum.offset, scale: spectrum.scale, units: spectrum.units,
                                beamEnergyKeV: spectrum.beamEnergyKeV, instrument: spectrum.microscope)
        }
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
        let beam = signal.metadata["Acquisition_instrument.TEM.beam_energy"]?.value.number
        return try onePixel(name: name, path: path, values: signal.data.doubles(), offset: axis.offset, scale: axis.scale, units: axis.units,
                            beamEnergyKeV: beam.flatMap { $0 > 0 ? $0 : nil }, instrument: nil)
    }

    /// The one spectrum as a 1 x 1 spectrum image: counts rounded to whole counts (negative or non-finite values are refused), the axis in
    /// keV (eV unless the file says keV), the beam energy and instrument when the file states them.
    private static func onePixel(name: String, path: String, values: [Double], offset: Double, scale: Double, units: String,
                                 beamEnergyKeV: Double?, instrument: String?) throws -> LoadedSpectrumImage {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SpectrumReadError(text: "The spectrum holds negative or non-finite values: it is not a count spectrum.")
        }
        let toKeV = units.lowercased() == "kev" ? 1.0 : 0.001
        let energyAxis = EnergyAxis(offset: offset * toKeV, scale: scale * toKeV, size: values.count)
        guard energyAxis.scale > 0 else { throw SpectrumReadError(text: "The spectrum's channel width is not positive.") }
        var meta = SpectrumImageMetadata(fileName: name, filePath: path, scanWidth: 1, scanHeight: 1, channelCount: values.count,
                                         energyOffsetEV: offset * toKeV * 1000, energyDispersionEV: scale * toKeV * 1000)
        meta.beamEnergyKeV = beamEnergyKeV
        meta.instrument = instrument
        let counts = values.map { UInt32(min($0.rounded(), Double(UInt32.max))) }
        return LoadedSpectrumImage(image: DenseSpectrumImage(ny: 1, nx: 1, channels: values.count, counts: counts), metadata: meta, energyAxis: energyAxis)
    }
}
