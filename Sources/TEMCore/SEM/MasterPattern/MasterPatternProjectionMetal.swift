//
//  MasterPatternProjectionMetal.swift
//  Role: the float32 GPU twin of `MasterPatternProjection.project` for many patterns at once (a dictionary): one thread per pattern
//        pixel turns the pixel's direction cosine by the pattern's quaternion, maps it to the square Lambert projection and
//        interpolates the master pattern bilinearly, exactly the steps of the CPU path in float32 with precise (not fast) math; each
//        pattern is then rescaled to -1 ... 1 on the CPU unless the master pattern is float32 already (the CPU path's rule,
//        `get_patterns`' `rescale = dtype_out != self.data.dtype`; EMsoft writes float32). The kernel is compiled from the source below at first use (no .metal
//        file: the app target's shader library stays the shell's). Same ports and licences as MasterPatternProjection.swift.
//        Checked against the float64 CPU path in macTEMTests/MasterPatternParityTests.swift within `tolerance` (decision in
//        docs/decisions.md: float32 Lambert coordinates on a 401 px master pattern move an interpolation weight by ~1e-5).
//

import Foundation
import FormatoCore
import Metal

package nonisolated enum MasterPatternProjectionMetal {
    /// The bound on |GPU − CPU| of a pattern rescaled to -1 ... 1: 1e-3, thirty times the 3.2e-5 a float32 emulation of the
    /// kernel measured on the Ni 20 kV pattern over 403 orientations (2026-11-06); the GPU's own transcendentals sit inside it.
    package static let tolerance = 1e-3

    /// Whether this Mac has a Metal device.
    package static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    private struct Pipeline: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let state: MTLComputePipelineState
    }

    /// Built once: the device, a queue and the compiled kernel (or why not).
    private static let pipeline: Result<Pipeline, MasterPatternProjection.Error> = {
        guard let device = MTLCreateSystemDefaultDevice() else { return .failure(.noMetalDevice) }
        guard let queue = device.makeCommandQueue() else { return .failure(.metal("no command queue")) }
        do {
            let options = MTLCompileOptions()
            options.mathMode = .safe
            let library = try device.makeLibrary(source: kernelSource, options: options)
            guard let function = library.makeFunction(name: "project_master_pattern") else { return .failure(.metal("no kernel function")) }
            let state = try device.makeComputePipelineState(function: function)
            return .success(Pipeline(device: device, queue: queue, state: state))
        } catch {
            return .failure(.metal(error.localizedDescription))
        }
    }()

    /// The patterns as float32, `rotations.count` × rows × columns, row-major: rescaled to -1 ... 1 per pattern, or as stored when the
    /// master pattern is float32 (as `MasterPatternProjection.project` with float32 output).
    package static func project(master: EBSDMasterPattern, rotations: [SIMD4<Double>], detector: EBSDDetectorGeometry,
                                energy: Double? = nil) throws -> [Float] {
        try MasterPatternProjection.checkSuitable(master)
        let centres = detector.projectionCenters.count
        guard centres == 1 || centres == rotations.count else {
            throw MasterPatternProjection.Error.centreCount(centres: centres, rotations: rotations.count)
        }
        let pixels = detector.rows * detector.columns
        guard pixels > 0 else { throw MasterPatternProjection.Error.emptyDetector }
        if rotations.isEmpty { return [] }
        let p = try pipeline.get()
        let (upper, lower) = try master.hemispheres(energy: energy)

        // Direction cosines in float64 on the CPU (one set per centre, as the reference), handed to the GPU as float4.
        let cosines = MasterPatternProjection.directionCosines(detector: detector).flatMap { set in
            set.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 0) }
        }
        let quaternions = rotations.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) }
        var params = Params(pixels: UInt32(pixels), patterns: UInt32(rotations.count), side: UInt32(master.side),
                            varying: centres == 1 ? 0 : 1, scale: Float(Double(master.side - 1) / 2))

        let outputBytes = rotations.count * pixels * MemoryLayout<Float>.stride
        guard let qBuffer = p.device.makeBuffer(bytes: quaternions, length: quaternions.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let dcBuffer = p.device.makeBuffer(bytes: cosines, length: cosines.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let upBuffer = Array(upper).withUnsafeBytes({ p.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let loBuffer = Array(lower).withUnsafeBytes({ p.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let outBuffer = p.device.makeBuffer(length: outputBytes, options: .storageModeShared),
              let commands = p.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else {
            throw MasterPatternProjection.Error.metal("could not allocate \(outputBytes) bytes on the GPU")
        }
        encoder.setComputePipelineState(p.state)
        encoder.setBuffer(qBuffer, offset: 0, index: 0)
        encoder.setBuffer(dcBuffer, offset: 0, index: 1)
        encoder.setBuffer(upBuffer, offset: 0, index: 2)
        encoder.setBuffer(loBuffer, offset: 0, index: 3)
        encoder.setBuffer(outBuffer, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 5)
        let width = min(p.state.threadExecutionWidth, pixels)
        let height = max(1, min(p.state.maxTotalThreadsPerThreadgroup / width, rotations.count))
        encoder.dispatchThreads(MTLSize(width: pixels, height: rotations.count, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw MasterPatternProjection.Error.metal(error.localizedDescription) }

        var out = [Float](repeating: 0, count: rotations.count * pixels)
        out.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: outBuffer.contents(), count: outputBytes)) }
        // `_rescale_with_min_max` to -1 ... 1, per pattern, only when the master pattern is not float32 already (`get_patterns`:
        // `rescale = dtype_out != self.data.dtype`, as `MasterPatternProjection.project`).
        guard master.dataType != .float32 else { return out }
        for n in 0 ..< rotations.count {
            let range = n * pixels ..< (n + 1) * pixels
            guard let lowest = out[range].min(), let highest = out[range].max(), highest > lowest else {
                throw MasterPatternProjection.Error.flatPattern(n)
            }
            let span = highest - lowest
            for i in range { out[i] = (out[i] - lowest) / span * 2 - 1 }
        }
        return out
    }

    /// The kernel's constants, laid out as the `Params` struct of the source.
    private struct Params {
        var pixels: UInt32
        var patterns: UInt32
        var side: UInt32
        var varying: UInt32
        var scale: Float
    }

    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { uint pixels; uint patterns; uint side; uint varying; float scale; };

    static float sgn(float x) { return x > 0.0f ? 1.0f : (x < 0.0f ? -1.0f : 0.0f); }

    kernel void project_master_pattern(device const float4 *rotations [[buffer(0)]],
                                       device const float4 *cosines [[buffer(1)]],
                                       device const float *upper [[buffer(2)]],
                                       device const float *lower [[buffer(3)]],
                                       device float *out [[buffer(4)]],
                                       constant Params &p [[buffer(5)]],
                                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.pixels || gid.y >= p.patterns) { return; }
        float4 q = rotations[gid.y];
        float4 d = cosines[(p.varying != 0 ? gid.y * p.pixels : 0u) + gid.x];
        float a = q.x, b = q.y, c = q.z, e = q.w;
        float aa = a * a, bb = b * b, cc = c * c, ee = e * e;
        float ac = a * c, ab = a * b, ae = a * e, bc = b * c, be = b * e, ce = c * e;
        float vx = (aa + bb - cc - ee) * d.x + 2.0f * ((ac + be) * d.z + (bc - ae) * d.y);
        float vy = (aa - bb + cc - ee) * d.y + 2.0f * ((ae + bc) * d.x + (ce - ab) * d.z);
        float vz = (aa - bb - cc + ee) * d.z + 2.0f * ((ab + ce) * d.y + (be - ac) * d.x);
        float n = precise::sqrt(vx * vx + vy * vy + vz * vz);
        float x = vx / n, y = vy / n, z = vz / n;
        float az = fabs(z);
        // 1 - |z| as (x² + y²) / (1 + |z|): the same number for a unit vector, without float32's cancellation near the
        // pole (1 - |z| loses up to 3e-4 px of Lambert coordinate there, measured as 2e-3 on the -1 ... 1 scale on an M-series GPU).
        float sz = precise::sqrt(2.0f * (x * x + y * y) / (1.0f + az));
        const float sqrtPiOver2 = 0.886226925452758f;
        const float twoOverSqrtPi = 1.128379167095513f;
        const float sqrtPiHalf = 1.253314137315500f;
        float lx = 0.0f, ly = 0.0f;
        if (az != 1.0f) {
            if (fabs(y) <= fabs(x)) {
                float s = sgn(x);
                lx = s * sz * sqrtPiOver2;
                ly = s * sz * twoOverSqrtPi * precise::atan(y / x);
            } else {
                float s = sgn(y);
                lx = s * sz * twoOverSqrtPi * precise::atan(x / y);
                ly = s * sz * sqrtPiOver2;
            }
        }
        float scale = p.scale;
        float i = scale * ly / sqrtPiHalf;
        float j = scale * lx / sqrtPiHalf;
        int side = int(p.side);
        int nii = int(i + scale), nij = int(j + scale);
        int niip = nii + 1, nijp = nij + 1;
        if (niip >= side) { niip = nii; }
        if (nijp >= side) { nijp = nij; }
        if (nii < 0) { nii = niip; }
        if (nij < 0) { nij = nijp; }
        float di = i - float(nii) + scale, dj = j - float(nij) + scale;
        float dim = 1.0f - di, djm = 1.0f - dj;
        device const float *mp = vz >= 0.0f ? upper : lower;
        out[gid.y * p.pixels + gid.x] = mp[nii * side + nij] * dim * djm + mp[niip * side + nij] * di * djm
            + mp[nii * side + nijp] * dim * dj + mp[niip * side + nijp] * di * dj;
    }
    """
}
