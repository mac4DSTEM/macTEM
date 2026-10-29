//
//  FFTAnalysis.swift
//  Role: the one owner of the FFT room's state for one open file (archive: roadmap-registrations-2026-10-15.md V1-6 + 6a + 6b, "The room"; the design in
//        archive: fft-room-design-2026-10-13.md): the region transformed, the spots measured on its transform, what
//        the source pane shows, the mask's radius and edge, the HRTEM filters' parameters and the spectrum's display
//        window — small values, kept while the file is cold, as the marks are (`OpenItem.fft`, beside `measurements`) —
//        and, while the room shows the file, the products: the spectrum ready to draw with its radial profile, the
//        masked inverse, ABSF and Wiener. The numbers are ImagoKit's (`PowerSpectrum`, `RadialProfile`, `SpotMeasurement`,
//        `MaskedInverseFFT`, `HRTEMFilter`, ADR 027; the room's region, bin and unit rules are ImagoFFT's `FFTRegion`, `SpectrumBin`, `FFTUnits`; `FFTMask` is ImagoFFT's); this owner asks for them and
//        publishes what it is answered, by the live-update rule R2.
//
//        NOT SAVED: the session sidecar (V1-2) is not built, so the room's state lives with its open file and goes when
//        it closes, as the marks do.
//
//  R2, THE LANES: four kinds of work — the spectrum (with its profile and display), a spot, the masked inverse, the
//  filters — each a lane that runs at most one job. A request while its job runs replaces the lane's pending key (the
//  newest wins); a job's answer is published only if its key still equals the lane's wanted key AND the room still shows
//  the file (`release()` bumps the lane's generation), otherwise it is dropped; then the pending key, if it is still
//  wanted and is not what just landed, runs. A running job is never interrupted: "cancel" means its answer is dropped.
//  Spots are the one FIFO lane: each click is its own job, in order, one at a time. Jobs are Tasks started on the main
//  actor that await the injected `FFTCompute` closures; the live ones run TEMCore in `@concurrent` functions below.
//

import Foundation
import Observation
import Synchronization
import ImagoCore
import ImagoFFT
import ImagoFilters
import TEMCore

// MARK: - Keys

/// What a spectrum is of: the file's pixels as last read (its canvas's content version) and the region (nil: the whole
/// image).
package nonisolated struct FFTSpectrumKey: Sendable, Equatable {
    package let contentVersion: Int
    package let crop: PixelCrop?
    /// What is done to the region's pixels before the transform (smoothing, band-pass, window); none by default.
    package let preprocess: FFTPreprocess

    package init(contentVersion: Int, crop: PixelCrop?, preprocess: FFTPreprocess = FFTPreprocess()) {
        self.contentVersion = contentVersion
        self.crop = crop
        self.preprocess = preprocess
    }
}

/// What a masked inverse is of: a spectrum's key and the mask's spots (centres, radius and edge, R4).
package nonisolated struct FFTMaskKey: Sendable, Equatable {
    package let spectrum: FFTSpectrumKey
    package let spots: [MaskedInverseFFT.Spot]

    package init(spectrum: FFTSpectrumKey, spots: [MaskedInverseFFT.Spot]) {
        self.spectrum = spectrum
        self.spots = spots
    }
}

/// What a filter run is of: the file's pixels, the region and the parameters.
package nonisolated struct FFTFilterKey: Sendable, Equatable {
    package let spectrum: FFTSpectrumKey
    package let parameters: HRTEMFilter.Parameters

    package init(spectrum: FFTSpectrumKey, parameters: HRTEMFilter.Parameters) {
        self.spectrum = spectrum
        self.parameters = parameters
    }
}

// MARK: - Spots

/// One spot: the bin clicked, on which spectrum, and what the estimator answered.
package nonisolated struct FFTSpot: Sendable, Identifiable {
    package enum Outcome: Sendable {
        case measuring
        case measured(SpotMeasurement)
        /// The kit's reason: `.noPower` for a window with no power (a constant region) and `.nonFinite` for an image with a NaN or an
        /// infinity (ImagoKit 0.6.0 refuses both where it answered NaN before), as well as its other refusals.
        case refused(SpotMeasurementError)
    }

    package let id: UUID
    /// As listed and drawn, from 1; not reused while the spots stand.
    package let number: Int
    /// The bin clicked, in the centred spectrum.
    package let row: Int
    package let col: Int
    /// The spectrum the click was on.
    package let spectrumKey: FFTSpectrumKey
    package var outcome: Outcome
    /// Whether the masked inverse passes this spot (only a measured one: a refused spot, or one with no peak, has no centroid).
    package var inMask: Bool

    package init(id: UUID = UUID(), number: Int, row: Int, col: Int, spectrumKey: FFTSpectrumKey,
                 outcome: Outcome = .measuring, inMask: Bool = true) {
        self.id = id
        self.number = number
        self.row = row
        self.col = col
        self.spectrumKey = spectrumKey
        self.outcome = outcome
        self.inMask = inMask
    }

    package var measured: SpotMeasurement? {
        if case .measured(let m) = outcome { return m }
        return nil
    }
}

// MARK: - The angle between spots

/// A measured spot's angle to the first measured spot of the list (the reference): the kit's `SpotMeasurement.angle`, in degrees 0...180. Adding or removing a later spot
/// never changes another's angle; removing the reference moves the reference to the next measured spot.
package nonisolated enum FFTSpotAngles {
    package struct Angle: Equatable, Sendable {
        package let degrees: Double
        /// The reference spot's number, as the list shows it.
        package let reference: Int
        package init(degrees: Double, reference: Int) { self.degrees = degrees; self.reference = reference }
    }

    package static func angles(_ spots: [FFTSpot]) -> [UUID: Angle] {
        guard let reference = spots.first(where: { $0.measured != nil }), let base = reference.measured else { return [:] }
        var out: [UUID: Angle] = [:]
        for spot in spots where spot.id != reference.id {
            guard let m = spot.measured, let degrees = try? SpotMeasurement.angle(base, m) else { continue }
            out[spot.id] = Angle(degrees: degrees, reference: reference.number)
        }
        return out
    }
}

// MARK: - Products (reference-held: observation compares their identity, never megabytes)
//
// `nonisolated` so a `@concurrent` job can build one: they are immutable values whose members are all `Sendable`.

/// A spectrum ready to draw.
package nonisolated final class FFTSpectrumProduct: Sendable {
    package let key: FFTSpectrumKey
    package let width: Int
    package let height: Int
    /// `PowerSpectrum`'s frequency step per bin and unit on each axis.
    package let spacingX: Double
    package let spacingY: Double
    package let unitsX: String
    package let unitsY: String
    /// `SpectrumDisplay`'s values normalised over their finite range (NaN drawn masked); `rawRange` is that range and
    /// `histogram` the histogram of the finite values (the Spectrum Display section).
    package let canvas: CanvasPixels
    package let defaultWindow: SpectrumDisplay.Window?
    /// `RadialProfile.compute` at its default width; nil when refused (the axes in different units).
    package let profile: RadialProfile?
    /// The transformed pixels alone, linear over their own finite range: the source pane's Region view.
    package let region: CanvasPixels

    package init(key: FFTSpectrumKey, width: Int, height: Int, spacingX: Double, spacingY: Double, unitsX: String,
                 unitsY: String, canvas: CanvasPixels, defaultWindow: SpectrumDisplay.Window?, profile: RadialProfile?,
                 region: CanvasPixels) {
        self.key = key
        self.width = width
        self.height = height
        self.spacingX = spacingX
        self.spacingY = spacingY
        self.unitsX = unitsX
        self.unitsY = unitsY
        self.canvas = canvas
        self.defaultWindow = defaultWindow
        self.profile = profile
        self.region = region
    }
}

/// The masked inverse of the transformed pixels, ready to draw.
package nonisolated final class FFTMaskedInverseProduct: Sendable {
    package let key: FFTMaskKey
    /// Linear over its own finite range.
    package let canvas: CanvasPixels
    /// `MaskedInverseFFT.imaginaryMax`: what the inverse left in the imaginary part.
    package let imaginaryMax: Double

    package init(key: FFTMaskKey, canvas: CanvasPixels, imaginaryMax: Double) {
        self.key = key
        self.canvas = canvas
        self.imaginaryMax = imaginaryMax
    }
}

/// One filter run: ABSF and Wiener of the transformed pixels, ready to draw, and the run's counts.
package nonisolated final class FFTFilterProduct: Sendable {
    package let key: FFTFilterKey
    package let absf: CanvasPixels
    package let wiener: CanvasPixels
    package let n: Int
    package let passes: Int
    /// The share of the n² bins flagged as background when the loop stopped, percent.
    package let finalDelta: Double

    package init(key: FFTFilterKey, absf: CanvasPixels, wiener: CanvasPixels, n: Int, passes: Int, finalDelta: Double) {
        self.key = key
        self.absf = absf
        self.wiener = wiener
        self.n = n
        self.passes = passes
        self.finalDelta = finalDelta
    }
}

// MARK: - The compute the owner asks (injected: tests pass jobs they finish in their own order)

package nonisolated struct FFTCompute: Sendable {
    package var spectrum: @Sendable (_ image: CalibratedImage, _ key: FFTSpectrumKey) async throws -> FFTSpectrumProduct
    package var spot: @Sendable (_ image: CalibratedImage, _ key: FFTSpectrumKey, _ row: Int, _ col: Int) async
        -> FFTSpot.Outcome
    package var maskedInverse: @Sendable (_ image: CalibratedImage, _ key: FFTMaskKey) async throws
        -> FFTMaskedInverseProduct
    package var filter: @Sendable (_ image: CalibratedImage, _ key: FFTFilterKey) async throws -> FFTFilterProduct

    package init(spectrum: @escaping @Sendable (CalibratedImage, FFTSpectrumKey) async throws -> FFTSpectrumProduct,
                 keyedSpot: @escaping @Sendable (CalibratedImage, FFTSpectrumKey, Int, Int) async -> FFTSpot.Outcome,
                 maskedInverse: @escaping @Sendable (CalibratedImage, FFTMaskKey) async throws -> FFTMaskedInverseProduct,
                 filter: @escaping @Sendable (CalibratedImage, FFTFilterKey) async throws -> FFTFilterProduct) {
        self.spectrum = spectrum
        self.spot = keyedSpot
        self.maskedInverse = maskedInverse
        self.filter = filter
    }

    /// A spot job that needs only the region (a test's): the key's preprocess is not its concern.
    package init(spectrum: @escaping @Sendable (CalibratedImage, FFTSpectrumKey) async throws -> FFTSpectrumProduct,
                 spot: @escaping @Sendable (CalibratedImage, PixelCrop?, Int, Int) async -> FFTSpot.Outcome,
                 maskedInverse: @escaping @Sendable (CalibratedImage, FFTMaskKey) async throws -> FFTMaskedInverseProduct,
                 filter: @escaping @Sendable (CalibratedImage, FFTFilterKey) async throws -> FFTFilterProduct) {
        self.init(spectrum: spectrum, keyedSpot: { image, key, row, col in await spot(image, key.crop, row, col) },
                  maskedInverse: maskedInverse, filter: filter)
    }

    /// TEMCore's cores, each in a `@concurrent` function, off the main actor.
    package static var live: FFTCompute {
        FFTCompute(
            spectrum: { image, key in try await FFTWork.spectrum(image, key) },
            keyedSpot: { image, key, row, col in await FFTWork.spot(image, key, row, col) },
            maskedInverse: { image, key in try await FFTWork.maskedInverse(image, key) },
            filter: { image, key in try await FFTWork.filter(image, key) })
    }
}

// MARK: - The live compute

/// A fresh content version for a product's canvas. `MetalImageView` re-uploads its texture when a canvas's version
/// changes, and a product is a new array each time, so every canvas takes the next number of a process-wide counter: a
/// serial, never a hash of the pixels (hashing megabytes per live drag sample buys nothing, and two products that are
/// equal in value are still two uploads). It starts at 2⁶², far from the small integers a test or a reader might use,
/// and `MetalImageView`'s FNV versions are uniform over all 64 bits, so a serial meets one only with a probability of
/// 2⁻⁶⁴ per product.
private nonisolated enum FFTProductVersion {
    private static let counter = Atomic<Int>(1 << 62)

    static func next() -> Int { counter.wrappingAdd(1, ordering: .relaxed).oldValue }
}

/// TEMCore's cores for the room's four lanes. Each is `@concurrent`, so the main actor is never the one transforming;
/// each returns `Sendable` products and keeps none of a core's intermediates (a `PowerSpectrum`'s magnitude and power,
/// `HRTEMFilter.Result`'s ≈ 73 B/px).
private nonisolated enum FFTWork {
    /// The pixels `crop` transforms: its crop of `image`, or the image (nil), as the kit's image.
    static func transformed(_ image: CalibratedImage, _ crop: PixelCrop?) throws -> Micrograph {
        guard let crop else { return image.micrograph }
        guard let cropped = image.micrograph.cropped(crop) else { throw PowerSpectrumError.crop(crop) }
        return cropped
    }

    /// `pixels` ready to draw: normalised over their finite range (non-finite pixels masked), with that range and, if
    /// asked, the histogram of the finite values.
    static func canvas(_ pixels: [Float], width: Int, height: Int, histogram: Bool) -> CanvasPixels {
        let image = FloatImage(width: width, height: height, pixels: pixels)
        let range: ClosedRange<Float>? = pixels.contains(where: \.isFinite) ? image.minMax.0...image.minMax.1 : nil
        return CanvasPixels(width: width, height: height, normalized: image.normalized(),
                            contentVersion: FFTProductVersion.next(), rawRange: range,
                            histogram: histogram ? IntensityHistogram.compute(pixels) : nil)
    }

    @concurrent static func spectrum(_ image: CalibratedImage, _ key: FFTSpectrumKey) async throws -> FFTSpectrumProduct {
        let interval = Signposts.begin("fft.spectrum"); defer { Signposts.end(interval) }
        let display: SpectrumDisplay
        let profile: RadialProfile?
        let spacingX: Double, spacingY: Double
        let unitsX: String, unitsY: String
        let source = try prepared(image, key)
        do {                                    // the core's arrays go out of scope here, before the canvases exist
            let spectrum = key.preprocess.isNone ? try PowerSpectrum.compute(image.micrograph, crop: key.crop)
                                                 : try PowerSpectrum.compute(source, crop: nil)
            display = SpectrumDisplay.make(spectrum)
            profile = try? RadialProfile.compute(spectrum)       // the kit throws where the copy answered nil: the same refusals
            spacingX = spectrum.spacingX
            spacingY = spectrum.spacingY
            unitsX = spectrum.unitsX
            unitsY = spectrum.unitsY
        }
        return FFTSpectrumProduct(
            key: key, width: display.width, height: display.height, spacingX: spacingX, spacingY: spacingY,
            unitsX: unitsX, unitsY: unitsY,
            canvas: canvas(display.values, width: display.width, height: display.height, histogram: true),
            defaultWindow: display.defaultWindow, profile: profile,
            region: canvas(source.pixels, width: source.width, height: source.height, histogram: false))
    }

    /// The pixels the transform sees for `key`: the region, then the key's smoothing, band-pass and window.
    static func prepared(_ image: CalibratedImage, _ key: FFTSpectrumKey) throws -> Micrograph {
        try key.preprocess.apply(transformed(image, key.crop))
    }

    @concurrent static func spot(_ image: CalibratedImage, _ key: FFTSpectrumKey, _ row: Int, _ col: Int) async
        -> FFTSpot.Outcome {
        let interval = Signposts.begin("fft.spot"); defer { Signposts.end(interval) }
        let crop = key.crop
        do {
            return .measured(key.preprocess.isNone
                ? try SpotMeasurement.measure(image.micrograph, crop: crop, clickRow: row, clickColumn: col)
                : try SpotMeasurement.measure(prepared(image, key), crop: nil, clickRow: row, clickColumn: col))
        } catch let failure as SpotMeasurementError {
            return .refused(failure)
        } catch {
            // `SpotMeasurement.measure` throws nothing but its own `SpotMeasurementError` (an outcome has no case for another error), so
            // this is unreachable; the nearest honest word for "could not be computed" is the transform's setup.
            return .refused(.fftSetup(width: crop?.width ?? image.width, height: crop?.height ?? image.height))
        }
    }

    @concurrent static func maskedInverse(_ image: CalibratedImage, _ key: FFTMaskKey) async throws
        -> FFTMaskedInverseProduct {
        let source = try transformed(image, key.spectrum.crop)
        let inverse = try MaskedInverseFFT.compute(source, spots: key.spots)
        return FFTMaskedInverseProduct(
            key: key, canvas: canvas(inverse.image.float32Values, width: inverse.width, height: inverse.height, histogram: false),
            imaginaryMax: inverse.imaginaryMax)
    }

    @concurrent static func filter(_ image: CalibratedImage, _ key: FFTFilterKey) async throws -> FFTFilterProduct {
        let source = try transformed(image, key.spectrum.crop)
        let result = try HRTEMFilter.filter(source, parameters: key.parameters)
        let outputs = try HRTEMFilter.outputs(result, like: source)
        return FFTFilterProduct(
            key: key,
            absf: canvas(outputs.absf.pixels, width: outputs.absf.width, height: outputs.absf.height, histogram: false),
            wiener: canvas(outputs.wiener.pixels, width: outputs.wiener.width, height: outputs.wiener.height,
                           histogram: false),
            n: result.n, passes: result.passes, finalDelta: result.finalDelta)
    }
}

// MARK: - One lane

/// One lane of R2 for a kind of work keyed by `Key`: at most one job at a time, the newest wanted key pending behind it.
private final class Lane<Key: Equatable & Sendable, Output: Sendable> {
    typealias Job = @Sendable () async -> Result<Output, any Error>

    /// The key the owner wants of this lane now; nil when it wants nothing.
    var wanted: () -> Key? = { nil }
    /// The job for `key`, made when it starts so it holds the image as it is then; nil when it cannot run.
    var makeJob: (Key) -> Job? = { _ in nil }
    /// Takes an answer whose key is still wanted.
    var land: (Key, Result<Output, any Error>) -> Void = { _, _ in }

    private var isRunning = false
    private var pending: Key?
    private var generation = 0

    /// Asks for `key`: it runs now if the lane is idle, else it replaces the pending key.
    func request(_ key: Key) {
        if isRunning { pending = key } else { start(key) }
    }

    /// Every answer still to come is dropped, and nothing waits.
    func invalidate() {
        generation += 1
        pending = nil
    }

    private func start(_ key: Key) {
        guard let job = makeJob(key) else { return }
        isRunning = true
        let ticket = generation
        Task { [weak self] in
            let result = await job()
            self?.finish(key, result, ticket)
        }
    }

    private func finish(_ key: Key, _ result: Result<Output, any Error>, _ ticket: Int) {
        isRunning = false
        let landed = ticket == generation && wanted() == key
        if landed { land(key, result) }
        guard !isRunning, let next = pending else { return }
        pending = nil
        // A pending key equal to what just landed was asked for while it ran: the answer is its answer.
        if wanted() == next, !(landed && next == key) { start(next) }
    }
}

// MARK: - The owner

@Observable
package final class FFTAnalysis {
    /// What the source pane (left) shows: the file as the Image room draws it, the transformed pixels alone, or a
    /// product of them.
    package enum SourceView: String, CaseIterable, Sendable {
        case original, region, maskedInverse, absf, wiener
    }

    // Settings, kept while the file is cold.

    /// The square transformed (R1: even side, at least 32 px, inside the image); nil is the whole image.
    package private(set) var region: PixelCrop?
    package private(set) var sourceView = SourceView.original
    /// The masked inverse's spot radius and raised-cosine edge, in bins (R4).
    package private(set) var maskRadius: Double = FFTMask.defaultRadius
    package private(set) var maskEdge: Double = FFTMask.defaultEdge
    /// Mitchell's defaults until changed; out of range is refused by the filter, never clamped.
    package private(set) var filterParameters = HRTEMFilter.Parameters.defaults
    /// Smoothing, band-pass and window applied to the transformed pixels before the transform (badged unvalidated).
    package private(set) var preprocess = FFTPreprocess()
    /// "Find spots": the settings of the finder and the number of spots it put on the spectrum last time.
    package private(set) var spotFinder = FFTSpotFinder.Settings()
    package private(set) var findSpotsFailure: String?
    /// The spectrum's display window in its displayed values; nil is the default window's edge.
    package var spectrumWindowLow: Float?
    package var spectrumWindowHigh: Float?

    // The spots, on the spectrum of the committed region.

    package private(set) var spots: [FFTSpot] = []
    package var selection: FFTSpot.ID?

    // Products, held while the room shows the file.

    package private(set) var spectrum: FFTSpectrumProduct?
    package private(set) var maskedInverse: FFTMaskedInverseProduct?
    package private(set) var filtered: FFTFilterProduct?
    /// The spectrum asked for: the region now, on the file's pixels as last shown.
    package private(set) var wantedSpectrumKey: FFTSpectrumKey?
    package private(set) var isFiltering = false
    /// Why the last spectrum, masked inverse or filter run failed, in the core's words; nil after a success.
    package private(set) var spectrumFailure: String?
    package private(set) var maskFailure: String?
    package private(set) var filterFailure: String?

    /// The spectrum shown is the one asked for.
    package var isSpectrumCurrent: Bool { spectrum != nil && spectrum?.key == wantedSpectrumKey }

    /// The masked inverse asked for: nil unless the source pane shows it, the spectrum shown is the one asked for, and
    /// at least one spot measured on it is in the mask. Its spots are the measured, in-mask ones (R4: a refused spot has
    /// no centroid), as `SpotMeasurement.maskSpot` places them on that spectrum with the mask's radius and edge.
    package var wantedMaskKey: FFTMaskKey? {
        guard sourceView == .maskedInverse, isSpectrumCurrent, let spectrum else { return nil }
        let inMask = spots.filter { $0.inMask && $0.spectrumKey == spectrum.key }.compactMap(\.measured).map {
            $0.maskSpot(radius: maskRadius, edge: maskEdge)
        }
        // A centre that is not a number can never equal itself (the key would never match its own answer): no such spot.
        .filter { $0.kx.isFinite && $0.ky.isFinite }
        guard !inMask.isEmpty else { return nil }
        return FFTMaskKey(spectrum: spectrum.key, spots: inMask)
    }

    /// A spot has been measured (a refused one, one with no peak and one still measuring have no centroid).
    package var hasMeasuredSpot: Bool { spots.contains { $0.measured != nil } }

    /// A measured spot is in the mask: the masked inverse has something to pass.
    package var hasMaskSpot: Bool { spots.contains { $0.inMask && $0.measured != nil } }

    /// The masked inverse shown is the one asked for.
    package var isMaskedInverseCurrent: Bool { maskedInverse != nil && maskedInverse?.key == wantedMaskKey }

    @ObservationIgnored private let compute: FFTCompute
    /// The file's pixels while the room shows it (`show` … `release`).
    @ObservationIgnored private var image: CalibratedImage?
    /// The content version last shown; kept through `release`, so the room's return to an unchanged file keeps its spots.
    @ObservationIgnored private var contentVersion: Int?
    /// The region last committed (a drag's end, a typed field, a button); a committed region that differs clears the spots.
    @ObservationIgnored private var committedRegion: PixelCrop?
    @ObservationIgnored private var lastSpotNumber = 0
    @ObservationIgnored private var wantedFilterKey: FFTFilterKey?

    @ObservationIgnored private let spectrumLane = Lane<FFTSpectrumKey, FFTSpectrumProduct>()
    @ObservationIgnored private let maskLane = Lane<FFTMaskKey, FFTMaskedInverseProduct>()
    @ObservationIgnored private let filterLane = Lane<FFTFilterKey, FFTFilterProduct>()
    /// The spot lane: the spots waiting for their turn, the one running, whether a job is out (it can outlive a
    /// `release`), and the generation `release` bumps so that job's answer is dropped.
    @ObservationIgnored private var spotQueue: [FFTSpot.ID] = []
    @ObservationIgnored private var spotRunning: FFTSpot.ID?
    @ObservationIgnored private var spotJobOut = false
    @ObservationIgnored private var spotGeneration = 0

    package init(compute: FFTCompute = .live) {
        self.compute = compute

        spectrumLane.wanted = { [weak self] in self?.wantedSpectrumKey }
        spectrumLane.makeJob = { [weak self] key in
            guard let self, let image = self.image else { return nil }
            let compute = self.compute
            return { await Self.attempt { try await compute.spectrum(image, key) } }
        }
        spectrumLane.land = { [weak self] _, result in
            guard let self else { return }
            switch result {
            case .success(let product):
                spectrum = product
                spectrumFailure = nil
            case .failure(let error):
                spectrum = nil
                spectrumFailure = Self.words(error)
            }
            reconcileMask()
        }

        maskLane.wanted = { [weak self] in self?.wantedMaskKey }
        maskLane.makeJob = { [weak self] key in
            guard let self, let image = self.image else { return nil }
            let compute = self.compute
            return { await Self.attempt { try await compute.maskedInverse(image, key) } }
        }
        maskLane.land = { [weak self] _, result in
            guard let self else { return }
            switch result {
            case .success(let product):
                maskedInverse = product
                maskFailure = nil
            case .failure(let error):
                maskedInverse = nil
                maskFailure = Self.words(error)
            }
        }

        // The run asked for, only while it is of the spectrum asked for now: a region that moved on makes it unwanted at once,
        // whether or not the move was committed (R2: a result is published only if its key still equals the wanted one).
        filterLane.wanted = { [weak self] in
            guard let self, let key = self.wantedFilterKey, key.spectrum == self.wantedSpectrumKey else { return nil }
            return key
        }
        filterLane.makeJob = { [weak self] key in
            guard let self, let image = self.image else { return nil }
            let compute = self.compute
            return { await Self.attempt { try await compute.filter(image, key) } }
        }
        filterLane.land = { [weak self] _, result in
            guard let self else { return }
            isFiltering = false
            switch result {
            case .success(let product):
                filtered = product
                filterFailure = nil
                sourceView = .absf
            case .failure(let error):
                filtered = nil
                filterFailure = Self.words(error)
            }
        }
    }

    // MARK: Intents

    /// The room shows this file — it appeared, or the file was read again: a region that no longer fits is cleared, the
    /// spots and products go when `contentVersion` differs from the last one shown, and the spectrum is asked for.
    package func show(_ image: CalibratedImage, contentVersion: Int) {
        self.image = image
        let changed = contentVersion != self.contentVersion
        self.contentVersion = contentVersion
        if changed {
            dropSpots()
            spectrum = nil
            spectrumFailure = nil
            dropDerivedProducts()
        }
        if let region, !FFTRegion.isValid(region, width: image.width, height: image.height) {
            self.region = nil
            committedRegion = nil
            if !changed {                               // a region gone is a committed region change
                dropSpots()
                dropDerivedProducts()
            }
        }
        wantedSpectrumKey = FFTSpectrumKey(contentVersion: contentVersion, crop: region, preprocess: preprocess)
        requestSpectrum()
        measureSpotsWaiting()
        reconcileMask()
    }

    /// A region drag's sample (`committed` false: the spectrum follows, live), or a committed region (a drag's end, a
    /// typed field, Clear Region, Use Centred Square): the spots, the masked inverse and the filters' result go when it
    /// differs from the last committed region.
    package func setRegion(_ crop: PixelCrop?, committed: Bool) {
        region = crop
        // The filters' result, and a run asked for, belong to the crop they were made for: any change of region — a drag's
        // sample as much as a committed one — takes them away, so none is published for a region no longer transformed.
        var filterCrops: [PixelCrop?] = []
        if let filtered { filterCrops.append(filtered.key.spectrum.crop) }
        if let wantedFilterKey { filterCrops.append(wantedFilterKey.spectrum.crop) }
        if filterCrops.contains(where: { $0 != crop }) { dropFilterResult() }
        if committed, crop != committedRegion {
            committedRegion = crop
            dropSpots()
            dropDerivedProducts()
        }
        if image != nil, let contentVersion {
            wantedSpectrumKey = FFTSpectrumKey(contentVersion: contentVersion, crop: crop, preprocess: preprocess)
        }
        requestSpectrum()
        reconcileMask()
    }

    /// A new preprocess: the spectrum is asked for again, and the spots, the masked inverse and the filters' result, which belong to
    /// the old transform, go with it.
    package func setPreprocess(_ new: FFTPreprocess) {
        guard new != preprocess else { return }
        preprocess = new
        dropSpots()
        dropDerivedProducts()
        if let contentVersion, image != nil {
            wantedSpectrumKey = FFTSpectrumKey(contentVersion: contentVersion, crop: region, preprocess: preprocess)
        }
        requestSpectrum()
        reconcileMask()
    }

    /// The finder's settings, kept inside what the finder accepts: a threshold between 5 % and 99 % of the display's range, a minimum
    /// distance of 2 to 64 bins, 1 to 40 spots. Changing them finds nothing by itself; Find Spots uses them.
    package func setSpotFinder(thresholdFraction: Double? = nil, minDistance: Int? = nil, count: Int? = nil) {
        if let thresholdFraction, thresholdFraction.isFinite { spotFinder.thresholdFraction = min(max(thresholdFraction, 0.05), 0.99) }
        if let minDistance { spotFinder.minDistance = min(max(minDistance, 2), 64) }
        if let count { spotFinder.count = min(max(count, 1), 40) }
    }

    /// Find spots: the finder's strongest reflections on the spectrum shown, each measured as a click would be (the existing spot
    /// lane). Replaces the spots already there; a spectrum not yet current finds none.
    package func findSpots() {
        findSpotsFailure = nil
        guard isSpectrumCurrent, let product = spectrum else { return }
        let settings = spotFinder
        let values = product.canvas.normalized, width = product.width, height = product.height
        let interval = Signposts.begin("fft.find"); defer { Signposts.end(interval) }
        do {
            let peaks = try FFTSpotFinder.find(values: values, width: width, height: height, settings: settings)
            dropSpots()
            reconcileMask()
            if peaks.isEmpty { findSpotsFailure = "No spot stands out of the transform: lower the threshold or the minimum distance." }
            for p in peaks { measureSpot(row: p.row, col: p.column) }
        } catch {
            findSpotsFailure = (error as? LocalizedError)?.errorDescription ?? "The finder could not run: \(error)"
        }
    }

    /// A click on the spectrum shown (or Measure at…): a new spot at that bin, measured off the main actor. A click on
    /// the bin of a spot already there selects that spot.
    package func measureSpot(row: Int, col: Int) {
        guard isSpectrumCurrent, let key = spectrum?.key else { return }
        if let existing = spots.first(where: { $0.row == row && $0.col == col && $0.spectrumKey == key }) {
            selection = existing.id
            return
        }
        lastSpotNumber += 1
        let spot = FFTSpot(number: lastSpotNumber, row: row, col: col, spectrumKey: key)
        spots.append(spot)
        selection = spot.id
        spotQueue.append(spot.id)
        runNextSpot()
    }

    package func removeSpot(_ id: FFTSpot.ID) {
        guard spots.contains(where: { $0.id == id }) else { return }
        remove(spotWithID: id)
        reconcileMask()
    }

    package func removeAllSpots() {
        dropSpots()
        reconcileMask()
    }

    package func setInMask(_ id: FFTSpot.ID, _ inMask: Bool) {
        guard let index = spots.firstIndex(where: { $0.id == id }), spots[index].inMask != inMask else { return }
        spots[index].inMask = inMask
        reconcileMask()
    }

    /// The mask's radius and edge in bins, clamped to `FFTMask`'s ranges (a value that is not a number leaves the
    /// current one).
    package func setMask(radius: Double, edge: Double) {
        func clamped(_ value: Double, _ range: ClosedRange<Double>, keeping current: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : current
        }
        let newRadius = clamped(radius, FFTMask.radiusRange, keeping: maskRadius)
        let newEdge = clamped(edge, FFTMask.edgeRange, keeping: maskEdge)
        guard newRadius != maskRadius || newEdge != maskEdge else { return }
        maskRadius = newRadius
        maskEdge = newEdge
        reconcileMask()
    }

    /// Choosing what the source pane shows; the masked inverse is computed while it is shown. ABSF and Wiener exist only
    /// after a filter run: asking for one before it is ignored.
    package func setSourceView(_ view: SourceView) {
        if (view == .absf || view == .wiener) && filtered == nil { return }
        sourceView = view
        reconcileMask()
    }

    /// Filter: one run gives ABSF and Wiener; the source pane shows ABSF when it lands.
    package func runFilter() {
        guard let image, let spectrumKey = wantedSpectrumKey else { return }
        let width = region?.width ?? image.width, height = region?.height ?? image.height
        guard FFTRegion.filterable(width: width, height: height) else {
            filterFailure = Self.filterRefusal(width: width, height: height)
            return
        }
        if let name = filterParameters.outOfRange {
            filterFailure = HRTEMFilterError.parameterOutOfRange(name).errorDescription
            return
        }
        filterFailure = nil
        let key = FFTFilterKey(spectrum: spectrumKey, parameters: filterParameters)
        if filtered?.key == key {                           // this very run is on screen: show it
            sourceView = .absf
            return
        }
        wantedFilterKey = key
        isFiltering = true
        filterLane.request(key)
    }

    /// New parameters remove the last run's result.
    package func setFilterParameters(_ parameters: HRTEMFilter.Parameters) {
        guard parameters != filterParameters else { return }
        filterParameters = parameters
        dropFilterResult()
    }

    /// The room stopped showing this file: every product and the image held for the lanes go; answers still running
    /// are dropped when they land. The settings and the spots' bins stay.
    package func release() {
        spectrumLane.invalidate()
        maskLane.invalidate()
        filterLane.invalidate()
        spotGeneration += 1
        spotQueue = []
        spotRunning = nil
        image = nil
        spectrum = nil
        spectrumFailure = nil
        wantedSpectrumKey = nil
        maskedInverse = nil
        maskFailure = nil
        dropFilterResult()
    }

    // MARK: The lanes

    private func requestSpectrum() {
        guard let key = wantedSpectrumKey, image != nil, spectrum?.key != key else { return }
        spectrumFailure = nil                               // a new ask: the last one's failure is not this one's news
        spectrumLane.request(key)
    }

    /// Brings the masked inverse in line with what is wanted: none when nothing is wanted (it is held only while shown),
    /// else the key asked for unless it is the one held.
    private func reconcileMask() {
        guard let key = wantedMaskKey else {
            maskedInverse = nil
            maskFailure = nil
            return
        }
        if maskedInverse?.key != key { maskLane.request(key) }
    }

    /// The spot lane: the next waiting spot whose spectrum is still the one asked for, when no job is out. A waiting spot
    /// whose spectrum is no longer asked for can never be answered and goes.
    private func runNextSpot() {
        guard !spotJobOut, let image else { return }
        while !spotQueue.isEmpty {
            let id = spotQueue.removeFirst()
            guard let spot = spots.first(where: { $0.id == id }), case .measuring = spot.outcome else { continue }
            guard spot.spectrumKey == wantedSpectrumKey else {
                remove(spotWithID: id)
                reconcileMask()
                continue
            }
            spotJobOut = true
            spotRunning = id
            let ticket = spotGeneration
            let compute = self.compute
            Task { [weak self] in
                let outcome = await compute.spot(image, spot.spectrumKey, spot.row, spot.col)
                self?.spotEnded(id, outcome, ticket)
            }
            return
        }
    }

    private func spotEnded(_ id: FFTSpot.ID, _ outcome: FFTSpot.Outcome, _ ticket: Int) {
        spotJobOut = false
        if ticket == spotGeneration {
            spotRunning = nil
            if let index = spots.firstIndex(where: { $0.id == id }) {
                if spots[index].spectrumKey == wantedSpectrumKey {
                    spots[index].outcome = outcome
                } else {                                    // answered for a spectrum no longer asked for: dropped
                    remove(spotWithID: id)
                }
                reconcileMask()
            }
        }
        runNextSpot()
    }

    /// The room is shown again: spots whose answer was lost with a `release` are asked again.
    private func measureSpotsWaiting() {
        for spot in spots where spot.id != spotRunning && !spotQueue.contains(spot.id) {
            if case .measuring = spot.outcome { spotQueue.append(spot.id) }
        }
        runNextSpot()
    }

    // MARK: What a change removes

    private func remove(spotWithID id: FFTSpot.ID) {
        spots.removeAll { $0.id == id }
        spotQueue.removeAll { $0 == id }
        if selection == id { selection = nil }
        if spots.isEmpty { lastSpotNumber = 0 }
    }

    private func dropSpots() {
        findSpotsFailure = nil
        spots = []
        selection = nil
        spotQueue = []
        lastSpotNumber = 0
    }

    /// A committed region, or a new read of the file, removes the masked inverse and the filters' result (the spots go
    /// with `dropSpots`); a source view of a product that no longer exists falls back to the file.
    private func dropDerivedProducts() {
        maskedInverse = nil
        maskFailure = nil
        dropFilterResult()
        if sourceView == .maskedInverse { sourceView = .original }
    }

    private func dropFilterResult() {
        filtered = nil
        filterFailure = nil
        wantedFilterKey = nil
        isFiltering = false
        if sourceView == .absf || sourceView == .wiener { sourceView = .original }
    }

    // MARK: Words

    private nonisolated static func attempt<T: Sendable>(_ work: () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    /// A failure in plain words: the core's own text where it has one, else a sentence written here.
    private static func words(_ error: any Error) -> String {
        if let failure = error as? PowerSpectrumError {
            switch failure {
            case .crop(let crop):
                return "The region (\(crop.width) × \(crop.height) px at column \(crop.col), row \(crop.row)) does not lie inside the image, so it was not transformed."
            case .fftSetup(let width, let height):
                return "The Fourier transform of \(width) × \(height) px could not be set up."
            }
        }
        if let failure = error as? MaskedInverseFFTError {
            switch failure {
            case .fftSetup(let width, let height):
                return "The inverse transform of \(width) × \(height) px could not be set up."
            }
        }
        if let described = (error as? any LocalizedError)?.errorDescription { return described }
        return error.localizedDescription
    }

    /// Why Filter was refused for pixels of this size, pointing at what to do (R5: never a hidden crop).
    private static func filterRefusal(width: Int, height: Int) -> String {
        if width != height {
            return "The HRTEM filters need a square: the pixels transformed are \(width) × \(height) px. Choose Use Centred Square, then Filter."
        }
        if width % 2 != 0 {
            return "The HRTEM filters need an even side: the pixels transformed are \(width) × \(height) px. Choose Use Centred Square, then Filter."
        }
        return "The HRTEM filters need at least \(FFTRegion.minimumSide) × \(FFTRegion.minimumSide) px: the pixels transformed are \(width) × \(height) px."
    }
}
