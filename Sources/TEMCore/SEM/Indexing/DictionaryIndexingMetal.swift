//
//  DictionaryIndexingMetal.swift
//  Role: the float32 GPU twin of `DictionaryIndexing.matchCPU`: the score matrix experimental · dictionaryᵀ of prepared (centred,
//        unit-norm) patterns, the product kikuchipy computes with `da.einsum("ik,mk->im", ..., dtype=float32)`. A tiled matrix
//        product, 16 x 16 scores per threadgroup with the two operands staged through threadgroup memory 16 pixels at a time,
//        accumulated in float32 as kikuchipy's float32 run is. The experimental patterns go to the GPU once per indexing run, each
//        dictionary chunk once. The kernel is compiled from the source below at first use (no .metal file: the app target's shader
//        library stays the shell's). Same port and licence as DictionaryIndexing.swift.
//        Checked against the float64 CPU path in macTEMTests/SEMDictionaryIndexingParityTests.swift within `tolerance`.
//

import Foundation
import Metal

package nonisolated enum DictionaryIndexingMetal {
    /// The bound on |GPU − CPU| of a score (both in -1 ... 1): the float32 rounding of two unit vectors of a few thousand values and
    /// of their product's running sum stays near 1e-6; 1e-5 leaves room for another GPU's summation.
    package static let tolerance = 1e-5

    /// Work (experimental × dictionary × pixels) from which the GPU pays on the automatic backend: a 3 x 3 scan against ten
    /// thousand 60 x 60 patterns (3e8) stays on the CPU, a whole scan (1e11) goes to the GPU.
    package static let workThreshold = 1_000_000_000

    /// Whether this Mac has a Metal device.
    package static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    package enum Error: Swift.Error, LocalizedError, Equatable {
        case noMetalDevice
        case tooLarge(Int)
        case metal(String)

        package var errorDescription: String? {
            switch self {
            case .noMetalDevice: return "This Mac has no Metal device for GPU dictionary indexing."
            case .tooLarge(let n): return "\(n) values are more than one GPU buffer can index."
            case .metal(let text): return "GPU dictionary indexing failed: \(text)"
            }
        }
    }

    private struct Pipeline: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let state: MTLComputePipelineState
    }

    private static let pipeline: Result<Pipeline, Error> = {
        guard let device = MTLCreateSystemDefaultDevice() else { return .failure(.noMetalDevice) }
        guard let queue = device.makeCommandQueue() else { return .failure(.metal("no command queue")) }
        do {
            let options = MTLCompileOptions()
            options.mathMode = .safe
            let library = try device.makeLibrary(source: kernelSource, options: options)
            guard let function = library.makeFunction(name: "match_patterns") else { return .failure(.metal("no kernel function")) }
            let state = try device.makeComputePipelineState(function: function)
            return .success(Pipeline(device: device, queue: queue, state: state))
        } catch {
            return .failure(.metal(error.localizedDescription))
        }
    }()

    /// The experimental side of one indexing run on the GPU; `match` scores one dictionary chunk against it.
    nonisolated final class Matcher {
        private let p: Pipeline
        private let experimental: MTLBuffer
        private let count: Int
        private let length: Int

        /// `experimental`: `count` prepared patterns of `length` values each, row-major.
        init(experimental values: [Double], count: Int, length: Int) throws {
            let pipeline = try DictionaryIndexingMetal.pipeline.get()
            p = pipeline
            guard values.count <= Int(UInt32.max) else { throw Error.tooLarge(values.count) }
            let floats = values.map { Float($0) }
            guard let buffer = floats.withUnsafeBytes({ bytes in
                bytes.baseAddress.flatMap { pipeline.device.makeBuffer(bytes: $0, length: max(bytes.count, 4), options: .storageModeShared) }
                    ?? pipeline.device.makeBuffer(length: 4, options: .storageModeShared)
            }) else {
                throw Error.metal("could not allocate \(floats.count * 4) bytes on the GPU")
            }
            experimental = buffer
            self.count = count
            self.length = length
        }

        /// The scores (experimental × `dictionaryCount`, row-major) of the prepared dictionary chunk, as float32 values.
        func match(dictionary values: [Double], count dictionaryCount: Int) throws -> [Double] {
            guard values.count <= Int(UInt32.max), count * dictionaryCount <= Int(UInt32.max) else {
                throw Error.tooLarge(max(values.count, count * dictionaryCount))
            }
            let floats = values.map { Float($0) }
            let outputBytes = count * dictionaryCount * MemoryLayout<Float>.stride
            var params = Params(experimental: UInt32(count), dictionary: UInt32(dictionaryCount), length: UInt32(length))
            guard let dBuffer = floats.withUnsafeBytes({ bytes in
                      bytes.baseAddress.flatMap { p.device.makeBuffer(bytes: $0, length: max(bytes.count, 4), options: .storageModeShared) }
                          ?? p.device.makeBuffer(length: 4, options: .storageModeShared)
                  }),
                  let sBuffer = p.device.makeBuffer(length: max(outputBytes, 4), options: .storageModeShared),
                  let commands = p.queue.makeCommandBuffer(),
                  let encoder = commands.makeComputeCommandEncoder() else {
                throw Error.metal("could not allocate \(outputBytes) bytes on the GPU")
            }
            encoder.setComputePipelineState(p.state)
            encoder.setBuffer(experimental, offset: 0, index: 0)
            encoder.setBuffer(dBuffer, offset: 0, index: 1)
            encoder.setBuffer(sBuffer, offset: 0, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 3)
            let groups = MTLSize(width: (dictionaryCount + DictionaryIndexingMetal.tile - 1) / DictionaryIndexingMetal.tile, height: (count + DictionaryIndexingMetal.tile - 1) / DictionaryIndexingMetal.tile, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: DictionaryIndexingMetal.tile, height: DictionaryIndexingMetal.tile, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw Error.metal(error.localizedDescription) }
            let out = UnsafeBufferPointer(start: sBuffer.contents().assumingMemoryBound(to: Float.self), count: count * dictionaryCount)
            return out.map { Double($0) }
        }
    }

    /// The tile edge: the kernel's TILE.
    private static let tile = 16

    /// The kernel's constants, laid out as the `Params` struct of the source.
    private struct Params {
        var experimental: UInt32
        var dictionary: UInt32
        var length: UInt32
    }

    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    #define TILE 16

    struct Params { uint experimental; uint dictionary; uint length; };

    // scores[i][m] = sum_k experimental[i][k] * dictionary[m][k]; one thread per score, threadgroups of TILE x TILE scores
    // (x: dictionary pattern, y: experimental pattern). Every thread reaches every barrier: out-of-range threads load zeros.
    kernel void match_patterns(device const float *experimental [[buffer(0)]],
                               device const float *dictionary [[buffer(1)]],
                               device float *scores [[buffer(2)]],
                               constant Params &p [[buffer(3)]],
                               uint2 tid [[thread_position_in_threadgroup]],
                               uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float e[TILE][TILE];
        threadgroup float d[TILE][TILE];
        uint i = group.y * TILE + tid.y;
        uint m = group.x * TILE + tid.x;
        // The dictionary pattern this thread loads for its column of the tile (row tid.y of the transposed tile).
        uint mLoad = group.x * TILE + tid.y;
        float acc = 0.0f;
        for (uint k0 = 0; k0 < p.length; k0 += TILE) {
            uint k = k0 + tid.x;
            e[tid.y][tid.x] = (i < p.experimental && k < p.length) ? experimental[i * p.length + k] : 0.0f;
            d[tid.y][tid.x] = (mLoad < p.dictionary && k < p.length) ? dictionary[mLoad * p.length + k] : 0.0f;
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint t = 0; t < TILE; ++t) {
                acc = fma(e[tid.y][t], d[tid.x][t], acc);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (i < p.experimental && m < p.dictionary) {
            scores[i * p.dictionary + m] = acc;
        }
    }
    """
}
