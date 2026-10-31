//
//  DemoDocuments.swift
//  Role: the demo documents the UI tests (and a person trying the app without data) open: a lattice image, an EDX spectrum image
//        and an EELS spectrum image, generated in memory, deterministic, with PLANTED truth that `DemoDocuments.Truth` states.
//        Nothing here is real data, nothing is read from a file, and no kit is involved in making them (the kits measure them).
//
//  The generators change only with a test that pins their truth constants (`DemoDocumentsTests`); a changed planted number is a
//  fixture move (its own commit, a CHANGELOG line). Noise comes from a fixed-seed generator, never from the clock.
//

import Foundation
import ImagoCore
import SpectroCore
import SpectroEDX
import SpectroEELS
import TEMCore
import ShellEDXModel

package nonisolated enum DemoDocuments {

    /// The planted truth: what the rooms must read back from the demo documents.
    package enum Truth {
        /// The lattice: two orthogonal sinusoids of this period, at this pixel size.
        package static let latticeSpacingNm = 0.235
        package static let latticePixelNm = 0.0123
        package static let latticeSide = 512
        /// Five bright discs on the lattice image (pixels): diameters, for the Particles view.
        package static let discDiametersPx = [30, 40, 50, 60, 70]
        /// The EDX spectrum image: 16 x 16 pixels, 2048 channels of 10 eV; per-pixel line areas (counts) of the K alpha lines.
        package static let edxSide = 16
        package static let edxChannels = 2048
        package static let edxDispersionEV = 10.0
        package static let edxBeamKeV = 200.0
        package static let edxAreasPerPixel: [String: Double] = ["Al": 120, "Mg": 40, "Si": 47]
        /// `--demo-regions`: two rectangles drawn on the EDX scan, in pixels (x0, y0, x1, y1), and a line across it; the pixels every pixel alike, so counts scale with them.
        package static let edxRegionBoxes = [(0, 0, 4, 4), (4, 4, 12, 12)]
        package static let edxLine = (from: (0.5, 8.0), to: (15.5, 8.0))
        /// The EELS spectrum image: 16 x 16 pixels, 1024 channels of 0.25 eV from -10 eV; t/λ planted at every pixel.
        package static let eelsSide = 16
        package static let eelsChannels = 1024
        package static let eelsDispersionEV = 0.25
        package static let eelsOffsetEV = -10.0
        package static let eelsZeroLossCounts = 100_000.0
        package static let eelsTOverLambda = 0.5
        /// The Au diffraction pattern: 512 x 512, the centre at (256, 256), Δq 0.0125 Å⁻¹/px, 200 kV, Au at 4.0782 Å: ring N = h²+k²+l² sits at
        /// R = sqrt(N) / (a Δq) px ({111} 33.98, {200} 39.24, {220} 55.48 as six spots, {311} 65.06, {222} 67.96).
        package static let patternSide = 512
        package static let patternCentre = 256.0
        package static let patternDeltaQ = 0.0125
        package static let patternLattice = 4.0782
        package static let patternVolts = 200_000.0
        /// The file's own axis is this much larger than the planted Δq (so the fit versus the file reads about −1 %).
        package static let patternFileScaleFactor = 1.01
        package static func patternRadius(n: Double) -> Double { n.squareRoot() / (patternLattice * patternDeltaQ) }
        /// A fixed threshold (eV) above the zero-loss peak and below the plasmon, for an exact recovery.
        package static let eelsThresholdEV = 4.0
    }

    /// The regions of `--demo-regions` on an EDX session whose demo image is bound: what a person would draw, as the room's own calls.
    @MainActor package static func drawRegions(on session: EDXSession) {
        for (x0, y0, x1, y1) in Truth.edxRegionBoxes { session.drawRectangle(PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)) }
        session.drawLine(from: SpectroEDX.PixelPoint(x: Truth.edxLine.from.0, y: Truth.edxLine.from.1), to: SpectroEDX.PixelPoint(x: Truth.edxLine.to.0, y: Truth.edxLine.to.1))
    }

    /// The same regions on an EELS session whose demo image is bound (the 16 x 16 grids are the same).
    @MainActor package static func drawRegions(on session: EELSSession) {
        for (x0, y0, x1, y1) in Truth.edxRegionBoxes { session.drawRegion(.rectangle(PixelRect(x0: x0, y0: y0, x1: x1, y1: y1))) }
        session.drawLine(from: SpectroEDX.PixelPoint(x: Truth.edxLine.from.0, y: Truth.edxLine.from.1), to: SpectroEDX.PixelPoint(x: Truth.edxLine.to.0, y: Truth.edxLine.to.1))
    }

    /// A marker for the lattice: a path that opens through the app's own open path and is answered from memory, not from disk.
    package static let latticeURL = URL(fileURLWithPath: "/macTEM-demo/Demo lattice")
    package static let patternURL = URL(fileURLWithPath: "/macTEM-demo/Demo Au pattern")
    package static func isDemo(_ url: URL) -> Bool { url.path.hasPrefix("/macTEM-demo/") }

    // MARK: A fixed-seed generator

    private struct Generator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        /// SplitMix64: uniform in [0, 1).
        mutating func uniform() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    // MARK: The lattice image

    /// 512 x 512, 0.0123 nm/px, a 0.235 nm square lattice with noise and five bright discs.
    package static func lattice() -> CalibratedImage {
        let n = Truth.latticeSide
        let period = Truth.latticeSpacingNm / Truth.latticePixelNm
        var g = Generator(seed: 2026_10_21)
        var px = [Float](repeating: 0, count: n * n)
        let discs: [(cx: Double, cy: Double, r: Double)] = zip(Truth.discDiametersPx, [(90.0, 90.0), (250.0, 90.0), (420.0, 110.0), (110.0, 330.0), (330.0, 380.0)])
            .map { (cx: $1.0, cy: $1.1, r: Double($0) / 2) }
        for y in 0..<n {
            for x in 0..<n {
                var v = 1000 + 300 * cos(2 * .pi * Double(x) / period) + 300 * cos(2 * .pi * Double(y) / period)
                for d in discs where (Double(x) - d.cx) * (Double(x) - d.cx) + (Double(y) - d.cy) * (Double(y) - d.cy) <= d.r * d.r { v += 2500 }
                v += (g.uniform() - 0.5) * 2 * v.squareRoot()      // noise of about the Poisson width
                px[y * n + x] = Float(v)
            }
        }
        let axis = AxisCalibration(scale: Truth.latticePixelNm, unit: "nm")
        return CalibratedImage(width: n, height: n, pixels: px, x: axis, y: axis, fileName: "Demo lattice", source: "demo", voltage: 200_000,
                               notes: ["generated demo image, not data"])
    }

    // MARK: The Au diffraction pattern

    /// A polycrystalline-gold-like pattern: Gaussian rings ({111}, {200}, {311}, {222}), the {220} reflections as six spots, a central beam and a
    /// gentle background, with fixed-seed noise. The file's axis is written in 1/nm, 1 % off the planted scale.
    package static func diffractionPattern() -> CalibratedImage {
        let n = Truth.patternSide, c = Truth.patternCentre
        var g = Generator(seed: 2026_10_22)
        var px = [Float](repeating: 0, count: n * n)
        let rings: [(r: Double, amp: Double)] = [(Truth.patternRadius(n: 3), 3000), (Truth.patternRadius(n: 4), 2200),
                                                 (Truth.patternRadius(n: 11), 1200), (Truth.patternRadius(n: 12), 700)]
        let r220 = Truth.patternRadius(n: 8)
        let spots: [(x: Double, y: Double)] = (0..<6).map { k in
            let a = (45.0 + 60.0 * Double(k)) * .pi / 180
            return (c + r220 * cos(a), c + r220 * sin(a))
        }
        for y in 0..<n {
            for x in 0..<n {
                let dx = Double(x) - c, dy = Double(y) - c
                let r = (dx * dx + dy * dy).squareRoot()
                var v = 60 + 20000 * exp(-r * r / (2 * 16))
                for ring in rings { v += ring.amp * exp(-(r - ring.r) * (r - ring.r) / (2 * 1.2 * 1.2)) }
                for s in spots { v += 4000 * exp(-((Double(x) - s.x) * (Double(x) - s.x) + (Double(y) - s.y) * (Double(y) - s.y)) / (2 * 2.0 * 2.0)) }
                v *= 1 + 0.01 * (g.uniform() - 0.5) * 2
                px[y * n + x] = Float(v)
            }
        }
        // The file's axis in 1/nm: Δq in Å⁻¹ times 10, a little larger than planted.
        let axis = AxisCalibration(scale: Truth.patternDeltaQ * 10 * Truth.patternFileScaleFactor, unit: "1/nm", origin: c)
        return CalibratedImage(width: n, height: n, pixels: px, x: axis, y: axis, fileName: "Demo Au pattern", source: "demo",
                               voltage: Truth.patternVolts, notes: ["generated demo pattern, not data"])
    }

    // MARK: The image stack

    /// The demo stack: 24 frames of 128 x 128, 16-bit, a bright block that moves one step to the right per frame on a gentle ramp, so the
    /// frame shown is visible in the picture and the pixel under the block names the frame.
    package static let stackFrames = 24
    package static let stackSide = 128
    package static func stackPixel(frame f: Int, x: Int, y: Int) -> UInt16 {
        let block = x >= 8 + 4 * f && x < 24 + 4 * f && y >= 56 && y < 72
        return UInt16(1000 + (x + y) + (block ? 20_000 : 0))
    }

    /// Writes the demo stack as a multi-page TIFF (little-endian, baseline, one strip per page) and returns its URL in the temporary folder.
    package static func stackFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macTEM-demo-stack")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Demo stack.tif")
        try writeStackTIFF(to: url, frames: stackFrames, width: stackSide, height: stackSide, pixel: stackPixel)
        return url
    }

    /// A multi-page baseline TIFF of 16-bit grey pages, `pixel(frame, x, y)` in every pixel (also what a test writes its planted stacks with).
    package static func writeStackTIFF(to url: URL, frames: Int, width: Int, height: Int, pixel: (Int, Int, Int) -> UInt16) throws {
        var out = Data()
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        out.append(contentsOf: [0x49, 0x49, 0x2A, 0x00]); u32(8)
        let entries = 9, ifdBytes = 2 + entries * 12 + 4, pageBytes = width * height * 2
        for f in 0..<frames {
            let dataAt = out.count + ifdBytes
            let nextAt = f == frames - 1 ? 0 : dataAt + pageBytes
            u16(entries)
            func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); if type == 3 { u16(value); u16(0) } else { u32(value) } }
            entry(256, 4, 1, width); entry(257, 4, 1, height); entry(258, 3, 1, 16); entry(259, 3, 1, 1); entry(262, 3, 1, 1)
            entry(273, 4, 1, dataAt); entry(277, 3, 1, 1); entry(278, 4, 1, height); entry(279, 4, 1, pageBytes)
            u32(nextAt)
            for y in 0..<height { for x in 0..<width { var v = pixel(f, x, y).littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) } } }
        }
        try out.write(to: url)
    }

    // MARK: The EDX spectrum image

    /// 16 x 16 x 2048: an Al matrix with Mg and Si K lines on a bremsstrahlung continuum; per-pixel areas in `Truth.edxAreasPerPixel`.
    package static func edx() -> LoadedSpectrumImage {
        let n = Truth.edxSide, channels = Truth.edxChannels
        let axis = EnergyAxis(offset: 0, scale: Truth.edxDispersionEV / 1000, size: channels)
        let energies = (0..<channels).map { axis.energy(ofChannel: $0) }
        // The expected counts per channel for one pixel: continuum plus Gaussians (an SDD's resolution: 130 eV FWHM at Mn K alpha, narrower below). The continuum is
        // the kit's planted one (0.4 over one pixel) divided by the 256 pixels, so the pooled spectrum has the planted peak-to-continuum ratio.
        var mu = energies.map { e -> Double in
            let x = max(e, 0.05)
            return e >= 0.2 ? 0.0016 * max(Truth.edxBeamKeV - e, 0) / x * exp(-pow(0.3 / x, 3)) : 0
        }
        for (element, area) in Truth.edxAreasPerPixel {
            for (suffix, share) in [("Ka", 1.0), ("Kb", 0.02)] {
                guard let line = XRayLines.line("\(element)_\(suffix)") else { continue }
                let sigma = 0.0553 * (0.2 + 0.8 * line.energy / 5.895).squareRoot()     // 130 eV at Mn K alpha, about 83 eV at Al K alpha
                var weights = energies.map { exp(-0.5 * pow(($0 - line.energy) / sigma, 2)) }
                let total = weights.reduce(0, +)
                weights = weights.map { $0 / total }
                for c in 0..<channels { mu[c] += area * share * weights[c] }
            }
        }
        var g = Generator(seed: 1_021)
        var counts = [UInt32](repeating: 0, count: n * n * channels)
        for p in 0..<(n * n) {
            let scale = 0.8 + 0.4 * Double((p % n) + (p / n)) / Double(2 * (n - 1))     // a gentle thickness ramp
            for c in 0..<channels {
                let expected = mu[c] * scale
                let whole = expected.rounded(.down)
                counts[p * channels + c] = UInt32(whole) + (g.uniform() < expected - whole ? 1 : 0)
            }
        }
        var meta = SpectrumImageMetadata(fileName: "Demo EDX", filePath: "", scanWidth: n, scanHeight: n, channelCount: channels,
                                         energyOffsetEV: 0, energyDispersionEV: Truth.edxDispersionEV)
        meta.origin = .veloxEMD
        meta.beamEnergyKeV = Truth.edxBeamKeV
        return LoadedSpectrumImage(image: DenseSpectrumImage(ny: n, nx: n, channels: channels, counts: counts), metadata: meta, energyAxis: axis,
                                   scanImage: (0..<(n * n)).map { Float(100 + $0 % n) })
    }

    /// The demo EDX image's pooled spectrum as an `.msa` file in the temporary folder (what a person would open from the File menu).
    package static func spectrumFile() throws -> URL {
        let demo = edx()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macTEM-demo-spectrum")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Demo EDX spectrum.msa")
        try EDXExports.msa(counts: demo.image.sum(mask: nil), axis: demo.energyAxis, title: "Demo EDX spectrum", beamEnergyKeV: Truth.edxBeamKeV, host: .macTEM).write(to: url)
        return url
    }

    // MARK: The EELS spectrum image

    /// 16 x 16 x 1024: a narrow zero-loss peak holding `eelsZeroLossCounts` and one plasmon at 15 eV whose area makes ln(I_total / I_0)
    /// equal `eelsTOverLambda` at every pixel (both normalised over the channels, so the answer is exact by construction).
    package static func eels() throws -> LoadedEELS {
        let n = Truth.eelsSide, channels = Truth.eelsChannels
        let energies = (0..<channels).map { Truth.eelsOffsetEV + Truth.eelsDispersionEV * Double($0) }
        func normalised(centre: Double, sigma: Double) -> [Double] {
            let w = energies.map { exp(-0.5 * pow(($0 - centre) / sigma, 2)) }
            let total = w.reduce(0, +)
            return w.map { $0 / total }
        }
        let zlp = normalised(centre: 0, sigma: 0.6), plasmon = normalised(centre: 15, sigma: 3)
        let plasmonCounts = Truth.eelsZeroLossCounts * (exp(Truth.eelsTOverLambda) - 1)
        var spectrum = [Double](repeating: 0, count: channels)
        for c in 0..<channels { spectrum[c] = Truth.eelsZeroLossCounts * zlp[c] + plasmonCounts * plasmon[c] }
        var counts = [Double]()
        counts.reserveCapacity(n * n * channels)
        for _ in 0..<(n * n) { counts.append(contentsOf: spectrum) }
        let image = try LowLossSpectrumImage(nx: n, ny: n, channels: channels, counts: counts,
                                             energyOffsetEV: Truth.eelsOffsetEV, energyScaleEV: Truth.eelsDispersionEV)
        return LoadedEELS(fileName: "Demo EELS", image: image, beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10, origin: "generated demo")
    }
}
