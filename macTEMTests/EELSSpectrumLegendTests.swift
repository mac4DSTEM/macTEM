//
//  EELSSpectrumLegendTests.swift
//  The EELS spectrum's legend and its "low loss" / "core loss" names never meet. A drive on a Dual-EELS spectrum image (2026-11-02) showed the legend
//  ("Whole map", "Region 1") drawn over the two names at the foot of the plot. The legend now sits top left, above the plot, as in the EDS room.
//
//  WHAT IS PINNED: the legend's and the names' frames, measured in the fonts they are drawn in, over a sweep of spectrum sizes, counts-label margins and
//  junction positions. Red under: the legend at the bottom left, 40 pt above the foot of the view. Layout only; no number moves.
//

import XCTest
import AppKit
import SwiftUI
import ShellSpectroscopy
import SpectroEDX
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM
import ShellEDXModel

nonisolated final class EELSSpectrumLegendTests: XCTestCase {
    @MainActor private func fitting(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor private func legend(_ names: [String]) -> CGSize {
        let grey = RegionColor(red: 0.55, green: 0.55, blue: 0.55)
        let layers = names.enumerated().map { SpectrumLayer(id: "\($0.offset)", name: $0.element, color: grey, origin: 0, step: 1, counts: [1]) }
        return fitting(SpectrumLayerLegend(layers: layers))
    }

    /// For every spectrum size, counts-label margin and junction the plot can have, the legend's frame meets neither name's.
    @MainActor func testTheLegendNeverCoversTheLowLossAndCoreLossNames() {
        let low = fitting(Text(EELSSpectrumLayout.lowLossName).font(.caption2))
        let core = fitting(Text(EELSSpectrumLayout.coreLossName).font(.caption2))
        XCTAssertGreaterThan(low.width, 20); XCTAssertGreaterThan(core.width, 20)
        let legends = [legend(["Region 1"]), legend(["Whole map", "Region 1"]), legend(["Whole map", "Region 1", "Region 2", "Region 3"])]
        var checked = 0
        for width in stride(from: CGFloat(320), through: 1000, by: 40) {
            for height in stride(from: CGFloat(140), through: 420, by: 20) {
                for left in [CGFloat(30), 44, 52, 70] {
                    let size = CGSize(width: width, height: height)
                    let area = EELSSpectrumLayout.plotArea(in: size, left: left)
                    for junction in stride(from: area.minX, through: area.maxX, by: 3) {
                        let names = EELSSpectrumLayout.sectionLabelFrames(area: area, junction: junction, low: low, core: core)
                        for l in legends {
                            let frame = EELSSpectrumLayout.legendFrame(in: size, legend: l)
                            checked += 1
                            guard !frame.intersects(names.low), !frame.intersects(names.core) else {
                                return XCTFail("\(size), left \(left), junction \(junction): the legend \(frame) covers \(names.low) or \(names.core)")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
    }

    /// The legend sits top left above the plot, as in the EDS room: inside the band the titles share, clear of the counts axis title on its left.
    @MainActor func testTheLegendSitsInTheBandAboveThePlot() {
        let l = legend(["Whole map", "Region 1"])
        let size = CGSize(width: 480, height: 260)
        let frame = EELSSpectrumLayout.legendFrame(in: size, legend: l)
        XCTAssertLessThanOrEqual(frame.maxY, EELSSpectrumLayout.top, "above the plot")
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        let title = fitting(Text("log counts").font(.caption2))
        XCTAssertGreaterThanOrEqual(frame.minX, 4 + title.width + 4, "clear of the counts axis title, with a gap")
    }

    /// The room draws them where the layout says: the legend in the top-left overlay, the names at the layout's centres.
    func testTheRoomUsesTheLayout() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let room = try String(contentsOf: root.appendingPathComponent("macTEM/UI/EELSRoom.swift"), encoding: .utf8)
        let legend = try XCTUnwrap(room.range(of: "SpectrumLayerLegend(layers: Self.legendLayers(layers))"))
        let before = room[room.index(legend.lowerBound, offsetBy: -500)..<legend.lowerBound]
        XCTAssertTrue(before.contains(".overlay(alignment: .topLeading) {"), "the legend's overlay is top left")
        let after = room[legend.upperBound..<room.index(legend.upperBound, offsetBy: 160)]
        XCTAssertTrue(after.contains(".padding(.leading, EELSSpectrumLayout.legendLeading).padding(.top, EELSSpectrumLayout.legendInset)"))
        XCTAssertTrue(room.contains("EELSSpectrumLayout.sectionLabelCentres(area: area, junction: jx)"))
        XCTAssertTrue(room.contains("let area = EELSSpectrumLayout.plotArea(in: size, left: left)"))
    }

    // MARK: The picture

    /// A 2 x 2 spectrum image whose low loss (-5 to 250 eV) and core loss (150 to 649 eV) share a stretch, so the plot names the two at their junction.
    static func loaded() throws -> LoadedEELS {
        let nx = 2, ny = 2, lowChannels = 256, coreChannels = 500
        var lowCounts = [Double](), coreCounts = [Double]()
        for k in 0..<(nx * ny) {
            let level = Double(k + 1)
            for c in 0..<lowChannels {
                let e = -5 + Double(c)
                lowCounts.append(level * (1e6 * exp(-e * e / 2) + 4e4 * exp(-(e - 22) * (e - 22) / 60) + 2e5 / pow(max(e, 3), 1.5)))
            }
            for c in 0..<coreChannels {
                let e = 150 + Double(c)
                coreCounts.append(level * (3e9 * pow(e, -3) + (e >= 284 ? 4e2 * exp(-(e - 284) / 80) : 0)))
            }
        }
        let low = try LowLossSpectrumImage(nx: nx, ny: ny, channels: lowChannels, counts: lowCounts, energyOffsetEV: -5, energyScaleEV: 1)
        let core = try CoreLossSpectrumImage(nx: nx, ny: ny, channels: coreChannels, counts: coreCounts, energyOffsetEV: 150, energyScaleEV: 1)
        return LoadedEELS(fileName: "dual.dm4", image: low, beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10, origin: "planted",
                          coreLoss: core, coreLossOrigin: "planted core")
    }

    /// The lower pane with a region selected (legend "Whole map", "Region 1") and the low loss / core loss names, rendered offscreen in light mode. Writes
    /// `macTEM-legend.png` when MACEM_SHOT_DIR is set (TEST_RUNNER_MACEM_SHOT_DIR); otherwise only checks that it renders.
    @MainActor func testTheSpectrumWithARegionRendersOffscreen() async throws {
        let session = EELSSession()
        await session.bind(try Self.loaded()).value
        await session.settled()
        XCTAssertNotNil(session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))))
        await session.settled()
        XCTAssertEqual(EELSLowerPane.legendLayers(EELSLowerPane.layers(session)).map(\.name), ["Whole map", "Region 1"])
        let state = EELSRoomState()
        let canvas = NSSize(width: 760, height: 300)
        let host = NSHostingView(rootView: EELSLowerPane(session: session, state: state).frame(width: canvas.width, height: canvas.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-legend.png"))
    }
}
