//
//  DemoDocumentsTests.swift
//  The generated demo documents the UI journeys open (`DemoDocuments`, TEMSession) and the launch arguments that open them
//  (`LaunchOptions`, App): their planted truth is pinned here, so a changed constant is a deliberate fixture move.
//

import XCTest
import ImagoCore
import SpectroCore
import SpectroEELS
import SpectroEDX
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
@testable import macTEM

nonisolated final class DemoDocumentsTests: XCTestCase {

    /// The lattice: 512 x 512 at 0.0123 nm/px, deterministic (two calls equal), named, flagged as generated, and its brightest column
    /// pattern repeats at the planted period. Red under: a different size, calibration or seed; the period moved.
    func testTheLatticeIsDeterministicAndHasThePlantedPeriod() throws {
        let a = DemoDocuments.lattice(), b = DemoDocuments.lattice()
        XCTAssertEqual(a, b, "a fixed seed: the same pixels every time")
        XCTAssertEqual(a.width, 512); XCTAssertEqual(a.height, 512)
        XCTAssertEqual(a.fileName, "Demo lattice")
        XCTAssertEqual(a.x, AxisCalibration(scale: 0.0123, unit: "nm")); XCTAssertEqual(a.y, a.x)
        XCTAssertTrue(a.notes.contains { $0.contains("not data") })
        // The mean of each column over the rows free of the discs: its autocorrelation peaks at the planted period (19.1 px).
        var column = [Double](repeating: 0, count: 512)
        for x in 0..<512 { for y in 200..<300 { column[x] += Double(a.pixels[y * 512 + x]) } }
        let mean = column.reduce(0, +) / 512
        let centred = column.map { $0 - mean }
        func r(_ lag: Int) -> Double { (0..<(512 - lag)).reduce(0) { $0 + centred[$1] * centred[$1 + lag] } }
        let best = (15...24).max { r($0) < r($1) }
        XCTAssertEqual(best, 19, "0.235 nm / 0.0123 nm per pixel = 19.1 px")
    }

    /// The EDX demo is 16 x 16 x 2048 at 10 eV with the beam stated, deterministic, and Auto ID through the room finds the planted
    /// Mg and Si besides the Al; quantifying lists them. Red under: the line areas or the continuum changed so that a planted element is lost.
    @MainActor func testTheEDXDemoIsFoundByAutoID() async throws {
        let demo = DemoDocuments.edx()
        XCTAssertEqual(demo.metadata.scanWidth, 16); XCTAssertEqual(demo.metadata.channelCount, 2048)
        XCTAssertEqual(demo.metadata.beamEnergyKeV, 200)
        XCTAssertEqual(demo.energyAxis.scale, 0.01, accuracy: 1e-12)
        XCTAssertEqual(DemoDocuments.edx().image.sum(mask: nil), demo.image.sum(mask: nil), "deterministic")
        let session = EDXSession()
        await session.bind(demo).value
        await session.settled()
        let picked = Set(session.picks.map(\.symbol))
        XCTAssertTrue(picked.isSuperset(of: ["Al", "Mg", "Si"]), "Auto ID picked \(picked)")
        await session.quantify()?.value
        await session.settled()
        let fit = try XCTUnwrap(session.fit, session.fitFailure ?? "no fit")
        for e in ["Al", "Mg", "Si"] { XCTAssertNotNil(fit.rows.first { $0.element == e }?.weightPercent, e) }
        // Al is the matrix: far above Mg and Si, as planted (120 : 40 : 47 counts per pixel).
        let wt = Dictionary(uniqueKeysWithValues: fit.rows.compactMap { r in r.weightPercent.map { (r.element, $0) } })
        XCTAssertGreaterThan(try XCTUnwrap(wt["Al"]), try XCTUnwrap(wt["Si"]))
        XCTAssertGreaterThan(try XCTUnwrap(wt["Si"]), try XCTUnwrap(wt["Mg"]))
    }

    /// The EELS demo recovers the planted t/λ = 0.5 at every pixel through the room with a fixed threshold, and through the default
    /// (estimated) rule within the kit's stated bias. Red under: the plasmon or the zero-loss area moved.
    @MainActor func testTheEELSDemoRecoversThePlantedThickness() async throws {
        let session = EELSSession()
        await session.bind(try DemoDocuments.eels()).value
        session.setThreshold(.fixed(DemoDocuments.Truth.eelsThresholdEV))
        await session.settled()
        let map = try XCTUnwrap(session.map, session.failure ?? "no map")
        XCTAssertEqual(map.pixels.count, 256)
        for p in map.pixels { XCTAssertEqual(try XCTUnwrap(p.tOverLambda), DemoDocuments.Truth.eelsTOverLambda, accuracy: 2e-3, "the fixed 4 eV threshold leaves a plasmon tail of about 1e-4 in I_0") }
        session.setThreshold(.estimated)
        await session.settled()
        let estimated = try XCTUnwrap(session.map?.pixels.first?.tOverLambda, session.failure ?? "no estimated map")
        XCTAssertEqual(estimated, 0.5, accuracy: 0.01, "the estimated rule on the noise-free demo")
    }

    /// The five planted discs are found and counted by the Particles defaults (a threshold at half the range, no smoothing, minimum 4 px): five
    /// objects, none on the edge, whose areas match the planted diameters within the rasterisation. Red under: a disc moved to the edge; a
    /// lattice peak counted as an object.
    func testTheDemoLatticeHasFivePlantedDiscs() throws {
        let image = DemoDocuments.lattice()
        let report = try ParticleCompute.analyse(pixels: image.pixels, width: image.width, height: image.height, settings: ParticleSettings())
        XCTAssertEqual(report.summary.counted, 5, "objects: \(report.objects.map(\.moments.area))")
        XCTAssertEqual(report.summary.total, 5)
        let areas = report.objects.map(\.moments.area).sorted()
        for (area, d) in zip(areas, DemoDocuments.Truth.discDiametersPx) {
            let planted = Double.pi * Double(d * d) / 4
            XCTAssertEqual(Double(area), planted, accuracy: 0.05 * planted, "a disc of \(d) px")
        }
    }

    // MARK: Launch arguments

    @MainActor func testTheLaunchArgumentsAreRead() {
        XCTAssertEqual(LaunchOptions(arguments: ["macTEM"]), LaunchOptions(arguments: []))
        let all = LaunchOptions(arguments: ["macTEM", "--ui-testing", "--demo-fixture", "--demo-spectrum-fixture", "--demo-eels-fixture", "--export-dir", "/tmp/out"])
        XCTAssertTrue(all.isUITesting && all.demoImage && all.demoSpectrum && all.demoEELS)
        XCTAssertEqual(all.exportDirectory, URL(fileURLWithPath: "/tmp/out", isDirectory: true))
        XCTAssertNil(LaunchOptions(arguments: ["--export-dir"]).exportDirectory, "no path after the flag")
        let relative = AppState(launch: LaunchOptions(arguments: ["--export-dir", "ui-export"]))
        XCTAssertEqual(relative.exportDirectory, FileManager.default.temporaryDirectory.appendingPathComponent("ui-export", isDirectory: true), "a relative folder is inside the temporary folder")
        let absolute = AppState(launch: LaunchOptions(arguments: ["--export-dir", "/tmp/out"]))
        XCTAssertEqual(absolute.exportDirectory, URL(fileURLWithPath: "/tmp/out", isDirectory: true))
        XCTAssertNil(AppState(launch: LaunchOptions(arguments: [])).exportDirectory, "a person gets the panel")
        XCTAssertFalse(LaunchOptions(arguments: ["--demo-fixture"]).isUITesting)
    }

    @MainActor func testOpenArgumentsParseInOrderAndRefuseARelativePath() {
        let two = LaunchOptions(arguments: ["macTEM", "--open", "/data/b.emd", "--ui-testing", "--open", "/data/a.emd"])
        XCTAssertEqual(two.openFiles, [URL(fileURLWithPath: "/data/b.emd"), URL(fileURLWithPath: "/data/a.emd")], "the order given")
        XCTAssertTrue(LaunchOptions(arguments: ["--open", "data/relative.emd"]).openFiles.isEmpty, "a relative path is refused")
        XCTAssertTrue(LaunchOptions(arguments: ["--open"]).openFiles.isEmpty, "no path after the flag")
        XCTAssertTrue(LaunchOptions(arguments: []).openFiles.isEmpty)
    }

    /// The demo opens through the app's own open path: an item named for it, resident, with the image in its session.
    /// Red under: the reader not answering the demo URL; the item stuck reading.
    @MainActor func testTheDemoImageOpensThroughTheAppsOpenPath() async throws {
        let state = AppState(launch: LaunchOptions(arguments: ["--demo-fixture"]))
        await state.lastOpen?.value
        XCTAssertEqual(state.openItems.items.count, 1)
        let item = try XCTUnwrap(state.openItems.selected)
        XCTAssertEqual(item.session.image?.fileName, "Demo lattice")
        XCTAssertEqual(item.residency, .resident)
        XCTAssertTrue(DemoDocuments.isDemo(DemoDocuments.latticeURL))
        XCTAssertFalse(DemoDocuments.isDemo(URL(fileURLWithPath: "/Users/x/a.dm4")))
    }

    @MainActor func testTheSpectrumFixturesOpenTheirRooms() async throws {
        let state = AppState(launch: LaunchOptions(arguments: ["--demo-spectrum-fixture", "--demo-eels-fixture"]))
        await state.edx.settled()
        await state.eels.settled()
        XCTAssertEqual(state.edx.fileName, "Demo EDX")
        XCTAssertEqual(state.eels.fileName, "Demo EELS")
        XCTAssertFalse(state.hasImage, "no image fixture: no image open")
        XCTAssertEqual(state.navigation.workspaceArea, .edx, "a launch with only spectrum documents starts in a room that can show one, not in Prepare")
    }
}
