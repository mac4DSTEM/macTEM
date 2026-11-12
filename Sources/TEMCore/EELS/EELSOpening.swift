// Opening a low-loss EELS spectrum image: a GMS .dm4 with an EELS spectrum-image object (FormatoKit's `DM4Experiment.readEELSSpectrumImage`)
// or a Velox.emd with an EELS stream (`VeloxSpectrumImageSignals`; NOT yet verified on a real Velox EELS file). A single spectrum (a GMS EELS
// object of dimensions [energy], an EMSA/MSA file of signal type ELS) opens as a 1 x 1 spectrum image.
// The counts stay as stored. What the file states (E0, the two angles) rides along for the mean free path; nothing is assumed.
// The room holds every count as a Double, so a file whose cubes would take more than half of the Mac's memory once read is refused in a
// sentence (`memoryRefusal`): a GMS file before a cube is read, from its header; a Velox file once FormatoKit has read it and before a cube is
// converted (its reader hands the shapes with the data).
import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoMSA
import SpectroEELS

/// One EELS cube of a file before its role is known: its energy window decides (a window that holds 0 eV is a low loss, one that starts above
/// it a core loss).
private nonisolated struct EELSCube {
    let nx: Int, ny: Int, channels: Int
    /// At the file's own precision: a GMS float32 cube stays four bytes a count (macTEM#571; SpectroKit `EELSCounts`).
    let counts: EELSCounts
    let offsetEV: Double, scaleEV: Double
    let origin: String
    var holdsZeroLoss: Bool { offsetEV <= 0 && offsetEV + scaleEV * Double(channels - 1) >= 0 }
}

/// A low-loss spectrum image with what its file says about the instrument.
package struct LoadedEELS: Sendable {
    package let fileName: String
    /// The low-loss cube the room holds: the file's, until Align replaces it with the aligned one (`replaceCubes`), so the room keeps one cube,
    /// not the file's and the aligned (macTEM#571: 8.9 GB after Align on the 1.46 GB 145_STEM). The file's own axis stays in `fileAxis`.
    package private(set) var image: LowLossSpectrumImage
    package let beamEnergyKeV: Double?
    package let convergenceMrad: Double?
    package let collectionMrad: Double?
    /// "GMS DM4 object 3 (EELS)" and the like: where the cube came from.
    package let origin: String
    /// The file's core-loss cube, when it holds one next to the low loss (a Dual-EELS file): same scan, its own energy window. The room
    /// aligns it with the low loss, and the edge model fits it.
    package private(set) var coreLoss: CoreLossSpectrumImage?
    /// The file's own axes, as read (the Info rows and Align's "before"): they stay when Align replaces the cubes.
    package let fileAxis: EELSFileAxis
    /// The cubes are Align's output, not the file's (`replaceCubes`): another Align reads the file again.
    package private(set) var cubesAreAligned = false
    /// Where the core loss came from, in words, or nil.
    package let coreLossOrigin: String?
    /// The scan's pixel size along x and its unit as the file states them ("µm" in a GMS file: `ImageData.Calibrations.Dimension.1`, FormatoKit's `xAxis`,
    /// RosettaSciIO's x axis `scale` and `units`); nil where the file states none. The maps' scale bar and the "Maps…" export draw from it.
    package let scanPixelSize: Double?
    package let scanPixelUnit: String?
    /// The file's path as it was opened ("" for a document made in memory): the Results room lists the room's numbers only under this file, so two
    /// files of one name in two folders are told apart (`AppState.eelsResultsBelong`).
    package let filePath: String
    /// The stage tilts in degrees and the instrument as the file states them (FormatoKit's DM reading, `EELSOpening.stated`); nil where it states none.
    /// Shown in Info and written to the spectrum's MSA file; nothing computes with them.
    package let alphaTiltDegrees: Double?
    package let betaTiltDegrees: Double?
    package let instrument: String?

    package init(fileName: String, image: LowLossSpectrumImage, beamEnergyKeV: Double?, convergenceMrad: Double?, collectionMrad: Double?, origin: String,
                 coreLoss: CoreLossSpectrumImage? = nil, coreLossOrigin: String? = nil, alphaTiltDegrees: Double? = nil, betaTiltDegrees: Double? = nil,
                 instrument: String? = nil, scanPixelSize: Double? = nil, scanPixelUnit: String? = nil, filePath: String = "") {
        self.fileName = fileName; self.image = image; self.beamEnergyKeV = beamEnergyKeV
        self.convergenceMrad = convergenceMrad; self.collectionMrad = collectionMrad; self.origin = origin
        self.coreLoss = coreLoss; self.coreLossOrigin = coreLossOrigin
        self.alphaTiltDegrees = alphaTiltDegrees; self.betaTiltDegrees = betaTiltDegrees; self.instrument = instrument
        self.scanPixelSize = scanPixelSize; self.scanPixelUnit = scanPixelUnit
        self.filePath = filePath
        fileAxis = EELSFileAxis(channels: image.channels, offsetEV: image.energyOffsetEV, scaleEV: image.energyScaleEV,
                                coreChannels: coreLoss?.channels, coreOffsetEV: coreLoss?.energyOffsetEV)
    }

    /// Holds Align's cubes in place of the file's: the file's let go, so the room holds one cube. The aligned core loss replaces the file's
    /// when Align aligned one.
    package mutating func replaceCubes(with alignment: ZeroLossAlignment) {
        image = alignment.aligned
        if let core = alignment.alsoAligned.first { coreLoss = core }
        cubesAreAligned = true
    }
}

/// The energy axes of an EELS file's cubes, as read.
package nonisolated struct EELSFileAxis: Sendable, Equatable {
    package let channels: Int
    package let offsetEV: Double
    package let scaleEV: Double
    package let coreChannels: Int?
    package let coreOffsetEV: Double?
}

package enum EELSOpeningError: Error, Equatable, LocalizedError {
    case notEELS(String)
    case unsupportedShape(String)
    /// The file's EELS cubes would take more than half of the Mac's memory once read: the sentence says how much (`EELSOpening.memoryRefusal`).
    case tooLarge(String)

    package var errorDescription: String? {
        switch self {
        case .notEELS(let name): "\(name) holds no EELS spectrum or spectrum image."
        case .unsupportedShape(let why): why
        case .tooLarge(let why): why
        }
    }
}

package enum EELSOpening {
    package static let readableExtensions = ["dm4", "emd", "msa"]

    /// The bytes `cubes` EELS cubes of `nx` x `ny` pixels and `channels` channels take as the room holds them: every count a Double, 8 bytes. In
    /// Double, so no file's size overflows it.
    package static func estimatedBytes(nx: Int, ny: Int, channels: Int, cubes: Int = 1, bytesPerCount: Int = 8) -> Double {
        Double(max(nx, 0)) * Double(max(ny, 0)) * Double(max(channels, 0)) * Double(max(cubes, 0)) * Double(bytesPerCount)
    }

    /// The share of the Mac's memory a file's cubes may take once read: half. The other half is the reader's own copy of the cube it is converting,
    /// what the room computes from the cubes, the app and the system (the Patterns room's rule for a processed scan, `PatternPipeline.processAdmission`).
    package static let memoryShare = 0.5

    /// The refusal of `name` when its `cubes` EELS cubes, `bytes` once read (`estimatedBytes`, summed over the cubes), take more than `memoryShare`
    /// of a Mac of `physicalMemory` bytes; nil when the file is read. One sentence: what the file holds, what it would take and what the Mac has.
    package static func memoryRefusal(name: String, cubes: Int, bytes: Double, physicalMemory: UInt64,
                                      locale: Locale = .autoupdatingCurrent) -> EELSOpeningError? {
        let memory = Double(physicalMemory)
        guard bytes > memory * memoryShare else { return nil }
        let gb = 1_073_741_824.0
        let holds = cubes == 1 ? "an EELS spectrum image" : "\(cubes) EELS spectrum images"
        let size = UnitDisplay.fixed(bytes / gb, places: 1, locale: locale), mac = UnitDisplay.fixed(memory / gb, places: 0, locale: locale)
        return .tooLarge("\(name) holds \(holds) that would take about \(size) GB in memory, more than half of this Mac's \(mac) GB, so it is not opened: "
                         + "crop or bin the spectrum image where it was acquired, or open it on a Mac with more memory.")
    }

    /// Reads the EELS spectrum images of the file and gives each its role by its energy window: the first that holds 0 eV is the low loss (what the
    /// thickness map and the zero-loss alignment work on), the first that starts above it is the core loss (what the edge model fits). A file with
    /// one cube and no zero loss opens as the low loss, as before (its t/λ says why it has none). Off the main actor; the kit's reasons come through in its words.
    /// A file whose cubes would take more than half of `physicalMemory` once read is refused (`memoryRefusal`); a test hands a memory of its own.
    package static func open(url: URL, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws -> LoadedEELS {
        let name = url.lastPathComponent
        var beam: Double?, convergence: Double?, collection: Double?
        var pixel: (size: Double, unit: String)?
        var stated: Stated?
        var cubes: [EELSCube] = []
        switch url.pathExtension.lowercased() {
        case "dm4":
            let objects = try DM4Experiment.list(path: url.path).filter { $0.role == .eels }
            guard !objects.isEmpty else { throw EELSOpeningError.notEELS(name) }
            // Before a cube is read: what the cubes take once read, from the object list (the header only; GMS writes [x, y, energy]).
            let sized = objects.map(\.dimensions).filter { $0.count == 3 }
            // A GMS cube is held as read, float32: four bytes a count (macTEM#571).
            let bytes = sized.reduce(0.0) { $0 + Self.estimatedBytes(nx: $1[0], ny: $1[1], channels: $1[2], bytesPerCount: 4) }
            if let refusal = memoryRefusal(name: name, cubes: sized.count, bytes: bytes, physicalMemory: physicalMemory) { throw refusal }
            var firstFailure: (any Error)?
            for object in objects {
                // A spectrum saved alone ([energy]) is a 1 x 1 spectrum image; a line scan ([x, energy]) is refused in words.
                if object.dimensions.count <= 2 {
                    do {
                        let spectrum = try Self.singleSpectrum(object, path: url.path, name: name)
                        if beam == nil { beam = spectrum.beam; convergence = spectrum.convergence; collection = spectrum.collection }
                        if stated == nil { stated = Self.stated(numbers: object.imageTagNumbers, strings: object.imageTagStrings) }
                        cubes.append(spectrum.cube)
                    } catch { firstFailure = firstFailure ?? error }
                    continue
                }
                // An EELS object that is not a spectrum image in eV (a GMS "energy in nm" stack) is skipped while another reads; if none does, its reason is raised.
                let si: DM4EELSSpectrumImage
                do { si = try DM4Experiment.readEELSSpectrumImage(path: url.path, index: object.index) } catch { firstFailure = firstFailure ?? error; continue }
                if beam == nil { beam = si.beamEnergyKeV; convergence = si.convergenceSemiAngleMrad; collection = si.collectionSemiAngleMrad }
                if stated == nil { stated = Self.stated(numbers: si.object.imageTagNumbers, strings: si.object.imageTagStrings) }
                if pixel == nil, let x = si.xAxis, x.scale > 0, !x.units.isEmpty { pixel = (x.scale, x.units) }
                cubes.append(EELSCube(nx: si.nx, ny: si.ny, channels: si.channels, counts: EELSCounts(si.counts),
                                      offsetEV: -si.energyAxis.origin * si.energyAxis.scale, scaleEV: si.energyAxis.scale,
                                      origin: "GMS DM4 object \(object.index) (EELS)"))
            }
            if cubes.isEmpty, let firstFailure { throw firstFailure }
        case "emd":
            var signals = try VeloxSpectrumImageSignals(path: url.path).signals.filter { $0.signalType == "EELS" }
            guard !signals.isEmpty else { throw EELSOpeningError.notEELS(name) }
            // FormatoKit's reader hands a Velox file's cubes with their data, so they are sized here, before any is converted to the room's Doubles.
            let sized = signals.map(\.data.shape).filter { $0.count == 3 }
            let bytes = sized.reduce(0.0) { $0 + Self.estimatedBytes(nx: $1[1], ny: $1[0], channels: $1[2]) }
            if let refusal = memoryRefusal(name: name, cubes: sized.count, bytes: bytes, physicalMemory: physicalMemory) { throw refusal }
            // Each of the kit's cubes is let go once it is converted, before the next one is: the kit's copy and the Doubles are in memory together
            // for one cube at a time, not for all of them.
            let count = signals.count
            for i in 0..<count {
                let signal = signals.removeFirst()
                guard signal.data.shape.count == 3, signal.axes.count == 3 else {
                    throw EELSOpeningError.unsupportedShape("\(name): the EELS signal has \(signal.data.shape.count) dimensions, a spectrum image needs three.")
                }
                let axis = signal.axes[2]
                guard axis.units == "eV" else { throw EELSOpeningError.unsupportedShape("\(name): the energy axis is in \"\(axis.units)\", not eV.") }
                if beam == nil, let kv = signal.metadata["Acquisition_instrument.TEM.beam_energy"]?.value.number, kv > 0 { beam = kv }
                if pixel == nil, signal.axes[1].scale > 0, !signal.axes[1].units.isEmpty { pixel = (signal.axes[1].scale, signal.axes[1].units) }
                cubes.append(EELSCube(nx: signal.data.shape[1], ny: signal.data.shape[0], channels: signal.data.shape[2], counts: EELSCounts(signal.data.doubles()),
                                      offsetEV: axis.offset, scaleEV: axis.scale, origin: "Velox EMD (EELS stream \(i + 1) of \(count))"))
            }
        case "msa":
            // An EMSA/MSA file holds one spectrum; FormatoKit's reader names its signal (`#SIGNALTYPE ELS` is EELS) and its axis.
            let signal = try MSAReader.read(path: url.path).signal
            guard signal.signalType == "EELS", let axis = signal.axes.first, signal.axes.count == 1 else { throw EELSOpeningError.notEELS(name) }
            guard axis.units == "eV" else {
                throw EELSOpeningError.unsupportedShape("\(name): the energy axis of the EELS spectrum is in \"\(axis.units)\", not eV.")
            }
            func number(_ key: String) -> Double? { signal.metadata[key]?.value.number }
            beam = number("Acquisition_instrument.TEM.beam_energy").flatMap { $0 > 0 ? $0 : nil }
            convergence = number("Acquisition_instrument.TEM.convergence_angle")
            collection = number("Acquisition_instrument.TEM.Detector.EELS.collection_angle")
            let counts = signal.data.doubles()
            cubes.append(EELSCube(nx: 1, ny: 1, channels: counts.count, counts: EELSCounts(counts), offsetEV: axis.offset, scaleEV: axis.scale,
                                  origin: "EMSA/MSA spectrum (EELS)"))
        default:
            throw EELSOpeningError.notEELS(name)
        }
        let low = cubes.first(where: \.holdsZeroLoss) ?? cubes[0]
        let core = cubes.first(where: { !$0.holdsZeroLoss && $0.offsetEV > 0 && $0.nx == low.nx && $0.ny == low.ny && $0.origin != low.origin })
        let image = try LowLossSpectrumImage(nx: low.nx, ny: low.ny, channels: low.channels, storedCounts: low.counts, energyOffsetEV: low.offsetEV, energyScaleEV: low.scaleEV)
        let coreImage = try core.map { try CoreLossSpectrumImage(nx: $0.nx, ny: $0.ny, channels: $0.channels, storedCounts: $0.counts, energyOffsetEV: $0.offsetEV, energyScaleEV: $0.scaleEV) }
        return LoadedEELS(fileName: name, image: image, beamEnergyKeV: beam, convergenceMrad: convergence, collectionMrad: collection, origin: low.origin,
                          coreLoss: coreImage, coreLossOrigin: core?.origin, alphaTiltDegrees: stated?.alphaTiltDegrees, betaTiltDegrees: stated?.betaTiltDegrees,
                          instrument: stated?.instrument, scanPixelSize: pixel?.size, scanPixelUnit: pixel?.unit, filePath: url.path)
    }

    /// One GMS EELS spectrum saved alone (an object of dimensions [energy], what a spectrum picker saves; [energy, 1] reads the same) as a 1 x 1 cube.
    /// FormatoKit's `readEELSSpectrumImage` reads [x, y, energy] only, so the counts come from its general DM reader (`DMFile.signal`, the data as
    /// stored), rounded to Float as that reader rounds a cube's; the axis is the object's calibration in eV, as for a cube (offset = -origin x scale);
    /// E0 and the two semi-angles are the tags `readEELSSpectrumImage` reads, by its rule (`ImageTags.source.Tags at creation.` on a stack-builder object).
    /// Interim, delete when FormatoKit reads a single EELS spectrum (FormatoKit#77). A line scan ([x, energy]) is refused in a sentence: the room maps a scan of
    /// two dimensions or shows one spectrum.
    private static func singleSpectrum(_ object: DM4ImageObject, path: String, name: String) throws
        -> (cube: EELSCube, beam: Double?, convergence: Double?, collection: Double?) {
        let dims = object.dimensions
        guard !dims.isEmpty, dims.allSatisfy({ $0 > 0 }) else {
            throw EELSOpeningError.unsupportedShape("\(name): the EELS object \(object.index) holds no channels.")
        }
        if dims.count == 2, dims.allSatisfy({ $0 > 1 }) {
            let energy = object.axes.firstIndex { $0?.units == "eV" } ?? 1
            throw EELSOpeningError.unsupportedShape(
                "\(name) holds an EELS line scan (\(dims[1 - energy]) positions of \(dims[energy]) channels): the EELS room opens a spectrum image [x, y, energy] or a single spectrum.")
        }
        let energy = dims.firstIndex { $0 > 1 } ?? 0
        guard energy < object.axes.count, let axis = object.axes[energy] else {
            throw EELSOpeningError.unsupportedShape("\(name): the EELS spectrum carries no energy calibration.")
        }
        guard axis.units == "eV" else {
            throw EELSOpeningError.unsupportedShape("\(name): the energy axis of the EELS spectrum is in \"\(axis.units)\", not eV.")
        }
        let counts = try DMFile(path: path).signal(index: object.index).load().data.doubles().map { Double(Float($0)) }
        let stack = "source.Tags at creation."
        let fromStack = object.imageTagNumbers.keys.contains { $0.hasPrefix(stack) } || object.imageTagStrings.keys.contains { $0.hasPrefix(stack) }
        let base = fromStack ? stack : "", conditions = base + "EELS.Experimental Conditions."
        let cube = EELSCube(nx: 1, ny: 1, channels: counts.count, counts: EELSCounts(counts), offsetEV: -axis.origin * axis.scale, scaleEV: axis.scale,
                            origin: "GMS DM4 object \(object.index) (EELS spectrum)")
        return (cube, object.imageTagNumbers[base + "Microscope Info.Voltage"].map { $0 / 1e3 },
                object.imageTagNumbers[conditions + "Convergence semi-angle (mrad)"], object.imageTagNumbers[conditions + "Collection semi-angle (mrad)"])
    }

    /// What a GMS EELS object states about the stage and the instrument.
    package struct Stated: Equatable, Sendable {
        package let alphaTiltDegrees: Double?
        package let betaTiltDegrees: Double?
        package let instrument: String?
    }

    /// The stage tilts and the instrument of one GMS image object, as FormatoKit's DM reader maps them (`AcquisitionMetadata.dm`, RosettaSciIO's
    /// `get_mapping`: `Microscope Info.Stage Position.Stage Alpha` / `Beta` in degrees as stored, the instrument the first of `Session Info.Microscope`,
    /// `Microscope Info.Name`, `Microscope Info.Microscope`; a stack-builder object from its `source.Tags at creation.` copy). A Velox EELS stream carries
    /// neither through FormatoKit's spectrum-image reader, so a Velox file shows none.
    package static func stated(numbers: [String: Double], strings: [String: String]) -> Stated {
        let m = AcquisitionMetadata.dm(numbers: numbers, strings: strings)
        return Stated(alphaTiltDegrees: m.stageTiltAlphaDeg?.value, betaTiltDegrees: m.stageTiltBetaDeg?.value, instrument: m.instrument?.value)
    }
}
