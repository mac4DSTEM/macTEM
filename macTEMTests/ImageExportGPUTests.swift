//
//  ImageExportGPUTests.swift
//  Pins `ImageExport.rgb` — the export's Double-precision twin of Colormaps.metal's `colormapFragment` and the LUT sampler —
//  to the REAL display pipeline on this Mac's GPU. The shader maps the window and gamma in Float32 and filters the LUT
//  with the GPU's fixed-point weights, then converts to 8-bit unorm; the export does the same arithmetic in Double with an
//  exact LUT interpolation and `.rounded()`. They cannot agree on every code value, so the difference is MEASURED and
//  asserted at a bound: the largest per-channel difference in 8-bit levels (a hard bound, the measured 1) and
//  the share of channels that differ at all, over the grid below (a fraction with a margin, not an exact count: another GPU's
//  fixed-point filter weights move the count a little, and a review measured no second GPU). A bound on the share catches
//  what a bound on the maximum cannot: a rounding that truncates instead of rounding stays within one level and differs on
//  an eighth of the channels.
//  The draw is the one `MetalEngineDisplayTests` makes (`displayPSO`, the identity transform, one texel per pixel, a
//  `bgra8Unorm` target), over: every real LUT (`Colormaps.lutRGBA`), a spread of window and gamma pairs, and a canvas row
//  holding a ramp, every LUT texel centre and midpoint, a golden-ratio spread, pseudo-random values and the masked
//  sentinel. The gamma goes to the shader as the Float the Metal view hands it and to the export as the Double the
//  presentation holds, as in the app. The measured numbers are a property of this GPU: the test prints the device's name,
//  the count and the share on its log line (and as an activity in the result bundle), so a failure on another Mac shows what
//  that GPU measured.
//  Mutations the test was broken by: `ImageExport.rgb` with gamma as v^γ (max difference 252 levels, 345 946 channels) and
//  with `.rounded()` as `.rounded(.down)` (max difference still 1, 150 344 channels = 12.7 %: only the share catches it);
//  and each bound lowered below the measured number.
//

@testable import ShellMetal
import XCTest
import Metal
import TEMCore
@testable import macTEM

nonisolated final class ImageExportGPUTests: XCTestCase {

    /// MEASURED 2026-10-13 on an Apple M5 Pro (macOS 27.0.1), run twice with the same result (the log line of
    /// `testTheExportsMappingMatchesTheRealDisplayPipelineWithinTheMeasuredBound`, kept in the result bundle as an
    /// activity): 96 draws, 1 179 648 channels; the export differs from the GPU by at most 1 level, in 11 407 channels
    /// (0.967 %); 4 476 of them with gamma 1, where the shader's `pow` is exact, so the difference is the GPU's fixed-point
    /// filter weights on the LUT and not the Float32 arithmetic; the masked sentinel agrees in all 14 112 of its channels.
    /// The largest difference is asserted at exactly the measured 1 level. The count is asserted as a share of the
    /// channels, at 2 % (twice the measured 0.967 %): the truncating mutant is at 12.7 %, so the margin costs no blindness.
    private static let measuredMaxDifference = 1
    private static let maximumDifferingShare = 0.02

    private static let columns = 2048
    private static let rows = 2

    /// The canvas values: exactly `columns × rows`.
    private static func canvas() -> [Float] {
        var values: [Float] = [0, 1, 0.5, 0.25, 0.75, 1e-7, 1 - 1e-7, 1.5, 100, .leastNonzeroMagnitude, 0.3333333]
        values += [FloatImage.invalidDisplayValue, FloatImage.invalidDisplayValue, -0.5, -1e-9, -1e30]
        for k in 0..<1024 { values.append(Float(k) / 1023) }
        for k in 0...256 { values += [(Float(k) + 0.5) / 256, Float(k) / 256] }
        for k in 1...1500 { values.append(Float((Double(k) * 0.6180339887498949).truncatingRemainder(dividingBy: 1))) }
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        while values.count < columns * rows {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53)
            values.append(u < 0.04 ? FloatImage.invalidDisplayValue : Float(u))
        }
        return Array(values.prefix(columns * rows))
    }

    @MainActor func testTheExportsMappingMatchesTheRealDisplayPipelineWithinTheMeasuredBound() throws {
        let engine = MetalEngine.shared
        let values = Self.canvas()
        XCTAssertEqual(values.count, Self.columns * Self.rows)
        let data = try XCTUnwrap(engine.device.makeFloatTexture(pixels: values, width: Self.columns, height: Self.rows))
        let windows: [(Float, Float)] = [(0, 1), (0.1, 0.9), (0.4, 0.45), (0.5, 1), (0, 1e-7), (0.9, 0.1)]
        let gammas: [Double] = [0.5, 1, 2.2, 0.04]

        var maxDifference = 0, differing = 0, channels = 0, draws = 0
        var histogram = [Int: Int]()
        var differingByGamma = [Double: Int](), differingByKind = [String: Int]()
        var maskedChannels = 0, maskedDiffering = 0
        var worst = ""
        for kind in ColormapKind.allCases {
            let lutBytes = Colormaps.lutRGBA(kind, count: 256)
            let lut = try XCTUnwrap(engine.device.makeLUTTexture(rgba: lutBytes))
            for (low, high) in windows {
                for gamma in gammas {
                    let bgra = try Self.render(engine.displayPSO, width: Self.columns, height: Self.rows) { encoder in
                        var display = SIMD4<Float>(low, high, Float(gamma), 0)
                        encoder.setFragmentBytes(&display, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                        encoder.setFragmentTexture(data, index: 0)
                        encoder.setFragmentTexture(lut, index: 1)
                    }
                    draws += 1
                    for i in 0..<values.count {
                        let gpu = [Int(bgra[4 * i + 2]), Int(bgra[4 * i + 1]), Int(bgra[4 * i])]
                        let mine = ImageExport.rgb(values[i], low: low, high: high, gamma: gamma, lut: lutBytes)
                        let export = [Int(mine.0), Int(mine.1), Int(mine.2)]
                        XCTAssertEqual(bgra[4 * i + 3], 255, "alpha")
                        for c in 0..<3 {
                            let d = abs(gpu[c] - export[c])
                            histogram[d, default: 0] += 1
                            channels += 1
                            if values[i] < 0 { maskedChannels += 1; if d != 0 { maskedDiffering += 1 } }
                            if d != 0 {
                                differing += 1
                                differingByGamma[gamma, default: 0] += 1
                                differingByKind[kind.rawValue, default: 0] += 1
                            }
                            if d > maxDifference {
                                maxDifference = d
                                worst = "\(kind) n=\(values[i]) window \(low)–\(high) gamma \(gamma): GPU \(gpu), export \(export)"
                            }
                        }
                    }
                }
            }
        }
        func list<K: Comparable & Hashable>(_ counts: [K: Int]) -> String {
            counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        }
        let share = Double(differing) / Double(channels)
        let percent = String(format: "%.4f", 100 * share)
        var line = "GPU parity [\(engine.device.name)]: \(draws) draws, \(channels) channels; "
        line += "max difference \(maxDifference) level(s) (bound \(Self.measuredMaxDifference)); "
        line += "\(differing) channels differ (\(percent) %, bound \(100 * Self.maximumDifferingShare) %); "
        line += "by size {\(list(histogram))}; by gamma {\(list(differingByGamma))}; by colormap {\(list(differingByKind))}; "
        line += "masked sentinel: \(maskedDiffering) of \(maskedChannels) channels differ; worst: \(worst)"
        print(line)
        XCTContext.runActivity(named: line) { _ in }
        XCTAssertGreaterThan(draws, 90)
        XCTAssertGreaterThan(maskedChannels, 0, "the grid must include the masked sentinel")
        XCTAssertLessThanOrEqual(maxDifference, Self.measuredMaxDifference, line)
        XCTAssertLessThanOrEqual(share, Self.maximumDifferingShare, line)
    }

    /// One frame of `pso` into a `width` × `height` BGRA8 target, the identity transform MetalImageView passes, read back
    /// (MetalEngineDisplayTests' helper, restated: it is private there). The clear colour is magenta, so a pixel the draw
    /// missed cannot pass for a value.
    private static func render(_ pso: MTLRenderPipelineState, width: Int, height: Int,
                               bind: (MTLRenderCommandEncoder) -> Void) throws -> [UInt8] {
        let engine = MetalEngine.shared
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(engine.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let buffer = try XCTUnwrap(engine.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pso)
        let identity = MetalDisplayTransform.identity(CGSize(width: width, height: height)).shaderRows()
        var rows = [identity.0, identity.1]
        encoder.setVertexBytes(&rows, length: 2 * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        bind(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertEqual(buffer.status, .completed, "\(String(describing: buffer.error))")
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return out
    }
}
