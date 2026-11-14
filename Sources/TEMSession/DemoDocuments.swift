//
//  DemoDocuments.swift
//  Role: the demo documents the UI tests (and a person trying the app without data) open: a lattice image, an EDX spectrum image
//        and an EELS spectrum image, generated in memory, deterministic, with PLANTED truth that `DemoDocuments.Truth` states.
//        Nothing in the generators is real data, nothing is read from a file, and no kit is involved in making them (the kits measure them).
//        `Shipped` is the other kind: real, public, licensed files the app bundle carries (the SEM program's north-star data), pinned by md5.
//
//  The generators change only with a test that pins their truth constants (`DemoDocumentsTests`); a changed planted number is a
//  fixture move (its own commit, a CHANGELOG line). Noise comes from a fixed-seed generator, never from the clock.
//

import CryptoKit
import Foundation
import FormatoCore
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
        /// The EBSD pattern dataset: a 30 x 40 scan of 60 x 60 uint8 patterns at 1.5 µm, six grains (the nearest of `ebsdGrainSeeds`, row and
        /// column), each with its own band directions and its own mean level `ebsdGrainLevel(g)`, so the mean-intensity map shows the grains.
        package static let ebsdScanRows = 30
        package static let ebsdScanColumns = 40
        package static let ebsdPatternSide = 60
        package static let ebsdStepUm = 1.5
        package static let ebsdBeamKeV = 20.0
        package static let ebsdSampleTilt = 70.0
        package static let ebsdBinning = 8
        package static let ebsdProjectionCenter = SIMD3<Double>(0.5, 0.5, 0.5)
        package static let ebsdGrainSeeds: [(row: Int, column: Int)] = [(5, 6), (8, 28), (16, 15), (22, 34), (26, 8), (14, 38)]
        package static func ebsdGrain(row: Int, column: Int) -> Int {
            var best = 0, bestDistance = Int.max
            for (g, seed) in ebsdGrainSeeds.enumerated() {
                let d = (seed.row - row) * (seed.row - row) + (seed.column - column) * (seed.column - column)
                if d < bestDistance { bestDistance = d; best = g }
            }
            return best
        }
        /// The level the bands of grain `g` sit on (counts), before the vignetting and the noise.
        package static func ebsdGrainLevel(_ g: Int) -> Double { 100 + 12 * Double(g) }
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
    package static let ebsdURL = URL(fileURLWithPath: "/macTEM-demo/Demo EBSD")
    package static func isDemo(_ url: URL) -> Bool { url.path.hasPrefix("/macTEM-demo/") }

    /// The folders in the app's temporary folder that Help > Open Demo Data writes its on-disk demos to (the stack, the SEM image, the
    /// spectrum): opened through the File menu's own path, but scratch, never a folder to save into (#507).
    package static let writtenFolders = ["macEM-demo-stack", "macEM-demo-sem", "macEM-demo-spectrum"]

    /// Whether `url` is one of the on-disk demo files (`writtenFolders`, in the temporary folder).
    package static func isWrittenDemo(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard writtenFolders.contains(folder.lastPathComponent) else { return false }
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents == tmp
    }

    // MARK: Shipped demo data

    /// A real, public, licensed dataset the app bundle carries under `Contents/Resources/DemoData/` (the repository's `DemoData/` folder
    /// reference; NOTICE names each with its source and licence). Bytes and md5 are pinned (`ShippedDemoDataTests`): a replaced file is a
    /// fixture move, its own commit with the reason.
    package struct ShippedFile: Equatable, Sendable {
        /// Below `DemoData/`.
        package let relativePath: String
        package let bytes: Int
        package let md5: String
        /// What the file is, for a menu or a row.
        package let title: String

        package var fileName: String { (relativePath as NSString).lastPathComponent }

        /// The file in the running app's bundle, or nil when the bundle carries no `DemoData/` (a bare library build).
        package var url: URL? {
            guard let resources = Bundle.main.resourceURL else { return nil }
            let url = resources.appendingPathComponent("DemoData/" + relativePath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    package enum Shipped {
        /// kikuchipy's `nickel_ebsd_large`: 55 x 75 EBSD patterns of 60 x 60 uint8 from polycrystalline nickel (NORDIF UF-1100, 20 kV, 70°
        /// tilt), the north-star EBSD set. Ånes, Hjelen, van Helvoort and Marthinsen, Zenodo 10.5281/zenodo.7498632, CC BY 4.0; the copy is
        /// the one kikuchipy 0.13 fetches (`pyxem/kikuchipy-data` at bcab8f7a, `nickel_ebsd_large/patterns_v2.h5`).
        package static let nickelEBSD = ShippedFile(relativePath: "nickel_ebsd_large/patterns_v2.h5", bytes: 15_368_325,
                                                     md5: "51d6bc0f5ff23dcb0c1a8e1f4c52d4d4", title: "Ni EBSD Patterns (kikuchipy)")
        /// The patterns dataset and its truth: kikuchipy's h5ebsd layout, scan rows x columns of pattern height x width.
        package static let nickelEBSDPatternsPath = "/Scan 1/EBSD/Data/patterns"
        package static let nickelEBSDRows = 55, nickelEBSDColumns = 75, nickelEBSDPatternHeight = 60, nickelEBSDPatternWidth = 60
        /// The sum of every pattern pixel, and of the first pattern's (h5py, 2026-11-06).
        package static let nickelEBSDPixelSum: UInt64 = 2_159_514_130
        package static let nickelEBSDFirstPatternSum: UInt64 = 531_330

        /// exspy's `EDS_SEM_TM002`: one SEM-EDS spectrum of BAM's EDS-TM002 standard (a 6 µm layer of C, Al, Mn, Cu and Zr on silicon),
        /// Zeiss Nvision40, Oxford X-max 80, 10 kV, 1024 channels of 10 eV from -100 eV; the north-star SEM-EDS spectrum. From the exspy
        /// package (`exspy/data/EDS_SEM_TM002.hspy`), GPL-3.0-or-later.
        package static let semEDSSpectrum = ShippedFile(relativePath: "EDS_SEM_TM002.hspy", bytes: 31_008,
                                                         md5: "1c3b8fddb2698741a0948d5a7c4eec51", title: "SEM-EDS Spectrum (BAM TM002)")
        package static let semEDSChannels = 1024
        package static let semEDSOffsetKeV = -0.1, semEDSScaleKeV = 0.01, semEDSBeamKeV = 10.0
        /// The counts, exact (h5py, 2026-11-06): their total, the highest channel and its counts, the elements the file names.
        package static let semEDSTotalCounts: UInt64 = 1_000_279
        package static let semEDSPeakChannel = 37, semEDSPeakCounts: UInt32 = 13_726
        package static let semEDSElements = ["Al", "C", "Cu", "Mn", "Zr"]

        /// kikuchipy's in-package EMsoft master pattern of nickel at 20 kV (`nickel_ebsd_master_pattern_small`): 401 x 401 px, uint8,
        /// square Lambert and stereographic projections of both hemispheres; what the patterns above are simulated and indexed
        /// against (figure F15). The simulation is Ånes, Zenodo 10.5281/zenodo.7498645, CC BY 4.0; the uint8 copy ships in kikuchipy
        /// 0.13.1 (`data/emsoft_ebsd_master_pattern/`), GPL-3.0-or-later.
        package static let nickelMasterPattern = ShippedFile(relativePath: "ni_mc_mp_20kv_uint8_gzip_opts9.h5", bytes: 908_492,
                                                             md5: "807c8306a0d02b46effbcb12bd44cd02", title: "Ni Master Pattern 20 kV (kikuchipy)")
        package static let nickelMasterPatternSide = 401
        /// The sum of each hemisphere's Lambert pattern (kikuchipy reads both hemispheres alike; 2026-11-06).
        package static let nickelMasterPatternLambertSum: UInt64 = 7_099_353

        /// orix-data's `sdss_ferrite_austenite.ang`: a 100 x 117 EDAX TSL orientation map at 1.5 µm of a super duplex stainless steel,
        /// austenite and ferrite (point group 432), indexed with EMsoft by H. W. Ånes; EBSD data by J. Hjelen (NTNU), CC BY 4.0
        /// (pyxem/orix-data). The Maps room's demo without patterns (design §7, `--demo-ang`) and the input of figure F6.
        package static let duplexSteelMap = ShippedFile(relativePath: "sdss_ferrite_austenite.ang", bytes: 651_687,
                                                        md5: "0c45548b82445657fbd52d882a27f2fd", title: "Duplex Steel Orientation Map (orix)")

        package static let all = [nickelEBSD, semEDSSpectrum, nickelMasterPattern, duplexSteelMap]
    }

    /// The md5 of a file, as `md5sum` prints it: how a shipped file is pinned to the copy its source publishes.
    package static func md5(of url: URL) throws -> String {
        Insecure.MD5.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

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
        return UInt16(clamping: 1000 + (x + y) + (block ? 20_000 : 0))   // clamped: a planted stack wider than 44 000 px saturates
    }

    /// Writes the demo stack as a multi-page TIFF (little-endian, baseline, one strip per page) and returns its URL in the temporary folder.
    /// The write is atomic (a new file renamed over the old): a window still reading the stack written before never sees half a file.
    package static func stackFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(writtenFolders[0])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Demo stack.tif")
        try writeStackTIFF(to: url, frames: stackFrames, width: stackSide, height: stackSide, pixel: stackPixel)
        return url
    }

    /// A multi-page baseline TIFF of 16-bit grey pages, `pixel(frame, x, y)` in every pixel (also what a test writes its planted stacks with).
    package static func writeStackTIFF(to url: URL, frames: Int, width: Int, height: Int, pixel: (Int, Int, Int) -> UInt16) throws {
        // Every offset is a 32-bit TIFF LONG: a stack whose bytes pass 4 GB, or of no page, is refused before anything is written.
        let ifdSize = 2 + 9 * 12 + 4
        let page = width.multipliedReportingOverflow(by: min(height, Int.max / 2) * 2)
        let total = (page.partialValue + ifdSize).multipliedReportingOverflow(by: frames)
        guard frames > 0, width > 0, height > 0, height <= Int.max / 2, !page.overflow, !total.overflow, total.partialValue + 8 <= Int(UInt32.max) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey:
                "A stack of \(frames) frames of \(width) x \(height) pixels does not fit a TIFF's 4 GB."])
        }
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
        try out.write(to: url, options: .atomic)
    }

    // MARK: The SEM image

    /// The demo SEM image: a Thermo-style (xT) TIFF of `semWidth` x (`semScanRows` + `semDatabarRows`) 8-bit pixels: a tilted grating
    /// with a bright disc in the scan, and a dark databar of light blocks under it, as the microscope would draw. Its FEI header
    /// (tag 34682) states the pixel size, HV, WD, detector, dwell, spot, pressure, stage, date, user and the databar height, so the
    /// Image room's SEM section and the databar crop are driven on it (SEMImageJourney).
    package static let semWidth = 512
    package static let semScanRows = 442
    package static let semDatabarRows = 29
    package static let semPixelSizeM = 2.0e-8
    package static let semHVVolts = 15_000.0
    package static let semWorkingDistanceM = 0.0100
    package static let semDetector = "ETD"
    package static let semDwellS = 1.0e-6
    package static let semSpot = 3.0
    package static let semChamberPressurePa = 1.2e-4
    package static let semInstrument = "Demo xT SEM"
    package static func semPixel(x: Int, y: Int) -> UInt8 {
        if y >= semScanRows {
            // The databar: dark, with four light blocks where the text and the micron bar would be.
            let inBlock = (y - semScanRows) >= 8 && (y - semScanRows) < 20 && [40, 160, 280, 400].contains { x >= $0 && x < $0 + 72 }
            return inBlock ? 230 : 20
        }
        let dx = Double(x) - 256, dy = Double(y) - 221
        if dx * dx + dy * dy < 60 * 60 { return 240 }
        let grating = sin((Double(x) * 0.8 + Double(y) * 0.6) / 6.0)
        return UInt8(clamping: Int(120 + 60 * grating))
    }

    /// The header as an xT microscope writes it (CRLF lines, `[Section]` and `Key=Value`), the values above in metres, volts and seconds.
    package static var semHeader: String {
        let lines = [
            "[User]", "Date=11/06/2026", "Time=12:00:00 PM", "User=demo",
            "[System]", "Type=SEM", "SystemType=\(semInstrument)",
            "[Beam]", "HV=\(Int(semHVVolts))", "Spot=\(Int(semSpot))", "Beam=EBeam", "Scan=EScan",
            "[EBeam]", "HV=\(Int(semHVVolts))", "WD=\(semWorkingDistanceM)", "BeamCurrent=1e-10",
            "[Scan]", "InternalScan=true", "Dwelltime=\(semDwellS)", "PixelWidth=\(semPixelSizeM)", "PixelHeight=\(semPixelSizeM)",
            "[Stage]", "StageX=0.001", "StageY=-0.002", "StageZ=0.01", "StageR=0", "StageT=0", "WorkingDistance=\(semWorkingDistanceM)",
            "[Image]", "ResolutionX=\(semWidth)", "ResolutionY=\(semScanRows)",
            "[Vacuum]", "ChPressure=\(semChamberPressurePa)", "UserMode=High vacuum",
            "[Detectors]", "Number=1", "Name=\(semDetector)", "Mode=SE",
            "[PrivateFei]", "DataBarSelected=HV WD mag det MicronBar", "DatabarHeight=\(semDatabarRows)",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Writes the demo SEM image and returns its URL in the temporary folder. The write is atomic: Help > Open Demo Data can ask for
    /// the file again while a window is still reading the one written before, and a reader never sees half a file.
    package static func semImageFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(writtenFolders[1])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Demo SEM image.tif")
        try semTIFF().write(to: url, options: .atomic)
        return url
    }

    /// The demo SEM image as a little-endian baseline TIFF: one strip of 8-bit grey, the FEI header in tag 34682 (ASCII, NUL-terminated).
    package static func semTIFF() -> Data {
        let width = semWidth, height = semScanRows + semDatabarRows
        var out = Data()
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        var header = Array(semHeader.utf8); header.append(0)
        if header.count % 2 == 1 { header.append(0) }
        let entries = 10, ifdBytes = 2 + entries * 12 + 4
        let headerAt = 8 + ifdBytes, dataAt = headerAt + header.count
        out.append(contentsOf: [0x49, 0x49, 0x2A, 0x00]); u32(8)
        u16(entries)
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); if type == 3 { u16(value); u16(0) } else { u32(value) } }
        entry(256, 4, 1, width); entry(257, 4, 1, height); entry(258, 3, 1, 8); entry(259, 3, 1, 1); entry(262, 3, 1, 1)
        entry(273, 4, 1, dataAt); entry(277, 3, 1, 1); entry(278, 4, 1, height); entry(279, 4, 1, width * height)
        entry(34682, 2, header.count, headerAt)
        u32(0)
        out.append(contentsOf: header)
        for y in 0..<height { for x in 0..<width { out.append(semPixel(x: x, y: y)) } }
        return out
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

    /// The demo EDX image's pooled spectrum as an `.msa` file in the temporary folder (what a person would open from the File menu),
    /// written atomically as the other demo files are.
    package static func spectrumFile() throws -> URL {
        let demo = edx()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(writtenFolders[2])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Demo EDX spectrum.msa")
        try EDXExports.msa(counts: demo.image.sum(mask: nil), axis: demo.energyAxis, title: "Demo EDX spectrum", beamEnergyKeV: Truth.edxBeamKeV, host: .macTEM).write(to: url, options: .atomic)
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

    // MARK: The EBSD pattern dataset

    /// 30 x 40 patterns of 60 x 60 uint8 in memory: each grain's pattern is two cosine band systems at the grain's own angles on the grain's
    /// own level, dimmed towards the detector's corners, with fixed-seed noise; the geometry is a kikuchipy-like header (1.5 µm step, 20 kV,
    /// 70° sample tilt, binning 8, the projection centre at the detector's centre) so the Calibration rows read real words.
    package static func ebsd() throws -> EBSDSession.Document {
        let rows = Truth.ebsdScanRows, columns = Truth.ebsdScanColumns, side = Truth.ebsdPatternSide
        var g = Generator(seed: 2026_11_06)
        var bytes = Data(count: rows * columns * side * side)
        let half = Double(side - 1) / 2
        bytes.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for row in 0..<rows {
                for column in 0..<columns {
                    let grain = Truth.ebsdGrain(row: row, column: column)
                    let theta = Double(grain) * .pi / 6 + 0.3, phi = theta + 1.1
                    let level = Truth.ebsdGrainLevel(grain)
                    let base = (row * columns + column) * side * side
                    for y in 0..<side {
                        for x in 0..<side {
                            let dx = Double(x) - half, dy = Double(y) - half
                            let band1 = 30 * cos(2 * .pi * (dx * cos(theta) + dy * sin(theta)) / 12)
                            let band2 = 20 * cos(2 * .pi * (dx * cos(phi) + dy * sin(phi)) / 9)
                            let vignette = 1 - 0.4 * (dx * dx + dy * dy) / (2 * half * half)
                            let value = (level + band1 + band2) * vignette + (g.uniform() - 0.5) * 10
                            out[base + y * side + x] = UInt8(min(max(value.rounded(), 0), 255))
                        }
                    }
                }
            }
        }
        let detector = EBSDDetectorGeometry(rows: side, columns: side, pixelSize: 70, binning: Truth.ebsdBinning, tilt: 0, azimuthal: 0, twist: 0,
                                            sampleTilt: Truth.ebsdSampleTilt, projectionCenters: [Truth.ebsdProjectionCenter])
        let dataset = EBSDDataset(format: .generated, manufacturer: "macEM", version: "", scanGroup: "Demo", scanGroups: ["Demo"],
                                  scanRows: rows, scanColumns: columns, patternRows: side, patternColumns: side, dataType: .uint8,
                                  stepY: Truth.ebsdStepUm, stepX: Truth.ebsdStepUm, detector: detector,
                                  sem: EBSDSEMHeader(beamEnergyKeV: Truth.ebsdBeamKeV, magnification: 200, workingDistanceMM: 24.7, microscope: "generated demo"),
                                  crystalMap: try demoCrystalMap(rows: rows, columns: columns),
                                  patterns: EBSDPatternSource(url: ebsdURL, datasetPath: "", fileShape: [rows, columns, side, side], dataType: .uint8))
        let access = try EBSDMemoryPatterns(dataset: dataset, bytes: bytes)
        return EBSDSession.Document(fileName: "Demo EBSD", url: nil, dataset: dataset, access: access)
    }

    /// The generated scan's crystal map: one Ni phase, each grain turned about z by the angle its bands are drawn at (not data:
    /// the planted truth the room's tests and journeys read back).
    private static func demoCrystalMap(rows: Int, columns: Int) throws -> CrystalMap {
        var euler: [SIMD3<Double>] = []
        for row in 0..<rows {
            for column in 0..<columns {
                euler.append(SIMD3(Double(Truth.ebsdGrain(row: row, column: column)) * .pi / 6 + 0.3, 0, 0))
            }
        }
        let grid = CrystalMap.coordinates(shape: (rows, columns), steps: (Truth.ebsdStepUm, Truth.ebsdStepUm))
        let ni = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m", lattice: [3.524, 3.524, 3.524, 90, 90, 90])
        return try CrystalMap(euler: euler, phaseIDs: Array(repeating: 0, count: euler.count), x: grid.x, y: grid.y,
                              phaseList: PhaseList([(0, ni)]), scanUnit: "um")
    }
}
