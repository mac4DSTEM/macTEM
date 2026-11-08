//
//  OrientationSampling.swift
//  orix 0.15.0's cubochoric sampling of rotation space (orix.sampling._cubochoric_sampling, orix.sampling.sample_generators):
//  the resolution-to-semi-edge-steps rule, the cubochoric grid S000(N), `get_sample_fundamental` (the grid reduced to
//  the orientation fundamental zone of a point group) and `get_sample_local` (the grid within an angle of the identity,
//  turned onto a centre). The grid is the one of Roşca, Morawiec and De Graef (2014), "A new method of constructing a
//  grid in the space of 3D rotations and its applications to texture analysis", Modelling Simul. Mater. Sci. Eng. 22
//  075013; N from the mean disorientation follows Singh and De Graef (2016), Modelling Simul. Mater. Sci. Eng. 24
//  085013, eq. 9. Dictionary indexing samples its dictionary here. GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE.
//
//  Numbers follow orix's code paths: the grid runs i, j, k over −N+1 ... N with k fastest, each point goes cubochoric →
//  Rodrigues-Frank → axis-angle → quaternion through `RotationConversions` and is normalised as `Rotation(...)` does; the
//  zone test is `OrientationRegion.contains` (orix's `__gt__`, 1e-9 either side); the local test keeps arccos(a) below
//  half the grid width, strictly; `unique` keeps first appearances in grid order. Parity: `tools/parity/sem` bundle
//  `m3/orientation-sampling` (counts exact, rotations atol 1e-7, orix's order), docs/parity.md.
//
//  Stop: the dictionary's sample (1° walks 274³ grid points) ends at the next slab of the grid once its task is cancelled
//  (`fundamentalSample`), and throws `CancellationError`; a walk not cancelled is the same walk in the same order.
//

import Foundation
import Synchronization

/// Uniform grids of rotations for indexing: the cubochoric grid of orix's `cubochoric_sampling`, reduced to a
/// fundamental zone or to a neighbourhood of a rotation.
package nonisolated enum OrientationSampling {

    package enum Error: Swift.Error, Equatable, Sendable {
        /// The resolution gives no grid: Singh and De Graef's rule needs a resolution above 0.03732° and gives N ≥ 1.
        case resolutionOutOfRange(Double)
        /// The grid width is not a positive angle.
        case gridWidthOutOfRange(Double)
    }

    /// The semi-edge of the cubochoric cube, π^(2/3) / 2.
    package static let semiEdgeLength = 0.5 * pow(Double.pi, 2.0 / 3.0)

    /// `resolution_to_semi_edge_steps`: N = round(131.97049 / (resolution − 0.03732)), resolution in degrees the mean
    /// disorientation between neighbours (Singh and De Graef 2016, eq. 9); rounded half to even as numpy rounds.
    package static func semiEdgeSteps(resolution: Double) throws -> Int {
        guard resolution.isFinite, resolution > 0.03732 else { throw Error.resolutionOutOfRange(resolution) }
        let steps = (131.97049 / (resolution - 0.03732)).rounded(.toNearestOrEven)
        guard steps >= 1, steps <= 4096 else { throw Error.resolutionOutOfRange(resolution) }
        return Int(steps)
    }

    /// `cubochoric_sampling(semi_edge_steps=N)`: the (2N)³ rotations of the grid S000(N) in orix's order (it holds the
    /// identity; a point outside the cube, which the grid never reaches, is skipped as orix skips it).
    package static func cubochoricGrid(semiEdgeSteps n: Int) -> [Rotation] {
        grid(semiEdgeSteps: n) { _ in true }.map { Rotation(unit: $0) }
    }

    /// `get_sample_fundamental(resolution, point_group, method="cubochoric")`: the grid's rotations inside the
    /// orientation fundamental zone of the point group (an improper group takes its proper region, as orix's
    /// `OrientationRegion.from_symmetry`), without repeats, in grid order. Resolution in degrees. `isCancelled` is asked
    /// before each slab of the grid, from the threads the slabs run on; it throws `CancellationError` once it says so.
    package static func fundamental(resolution: Double, pointGroup: PointGroup,
                                    isCancelled: @Sendable () -> Bool = { false }) throws -> [Rotation] {
        let n = try semiEdgeSteps(resolution: resolution)
        let region = try OrientationRegion.fromSymmetry(pointGroup)
        let inside = grid(semiEdgeSteps: n, keep: { region.contains($0) }, isCancelled: isCancelled)
        // A walk stopped part way holds only the slabs walked before: thrown away, never taken for the sample.
        if isCancelled() { throw CancellationError() }
        return Rotation.unique(inside.map { Rotation(unit: $0) }).rotations
    }

    /// `get_sample_local(resolution, center, grid_width, method="cubochoric")`: the grid's rotations closer to the
    /// identity than the grid width (arccos(a) < width / 2), without repeats, then `center * rotation` when a centre is
    /// given. Resolution and grid width in degrees.
    package static func local(resolution: Double, center: Rotation? = nil, gridWidth: Double = 10) throws -> [Rotation] {
        guard gridWidth.isFinite, gridWidth > 0 else { throw Error.gridWidthOutOfRange(gridWidth) }
        let n = try semiEdgeSteps(resolution: resolution)
        let halfAngle = gridWidth / 2 * Double.pi / 180
        let near = grid(semiEdgeSteps: n) { acos($0[0]) < halfAngle }
        let unique = Rotation.unique(near.map { Rotation(unit: $0) }).rotations
        guard let center else { return unique }
        return unique.map { center * $0 }
    }

    /// `fundamental(resolution:pointGroup:)` off the caller's actor (a 1° m-3m sample walks 274³ grid points). A cancelled
    /// task ends the walk at its next slab and throws `CancellationError`: the slabs run on dispatch threads, where
    /// `Task.isCancelled` reads false, so the task's cancellation handler raises a flag they read.
    @concurrent package static func fundamentalSample(resolution: Double, pointGroup: PointGroup) async throws -> [Rotation] {
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try fundamental(resolution: resolution, pointGroup: pointGroup, isCancelled: { cancelled.isRaised })
        } onCancel: {
            cancelled.raise()
        }
    }

    /// `local(resolution:center:gridWidth:)` off the caller's actor.
    @concurrent package static func localSample(resolution: Double, center: Rotation? = nil, gridWidth: Double = 10) async throws -> [Rotation] {
        try local(resolution: resolution, center: center, gridWidth: gridWidth)
    }

    // MARK: - The grid

    /// `_cubochoric_sampling_loop` with a filter applied as each point is made: the unit quaternions the filter keeps, in
    /// orix's order. The outer index runs in parallel bands; the bands are joined in index order, so the order is the
    /// serial loop's. A band asks `isCancelled` before each slab (one outer index) and stops once it says so; what the
    /// walk returns then is incomplete, and the caller throws instead of using it.
    private static func grid(semiEdgeSteps n: Int, keep: @Sendable (SIMD4<Double>) -> Bool,
                             isCancelled: @Sendable () -> Bool = { false }) -> [SIMD4<Double>] {
        precondition(n >= 1, "semi-edge steps must be at least 1")
        let length = semiEdgeLength
        let step = length / Double(n)
        let indices = Array((-n + 1)...n)
        let bands = Swift.min(indices.count, Swift.max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
        let per = (indices.count + bands - 1) / bands
        let results = BandResults(count: bands)
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            var out: [SIMD4<Double>] = []
            let lo = band * per, hi = Swift.min(indices.count, lo + per)
            guard lo < hi else { return }
            for i in indices[lo..<hi] {
                if isCancelled() { break }
                let x = Double(i) * step
                for j in indices {
                    let y = Double(j) * step
                    for k in indices {
                        let z = Double(k) * step
                        if Swift.max(abs(x), abs(y), abs(z)) > length { continue }
                        let q = quaternion(cubochoric: SIMD3(x, y, z))
                        if keep(q) { out.append(q) }
                    }
                }
            }
            results.set(band, out)
        }
        return results.joined()
    }

    /// One grid point: `cu2ro_single`, `ro2ax_single`, `ax2qu_single`, then `Rotation(...)`'s division by the norm.
    package static func quaternion(cubochoric cu: SIMD3<Double>) -> SIMD4<Double> {
        let q = RotationConversions.ax2qu(RotationConversions.ro2ax(RotationConversions.cu2ro(cu)))
        return q / RotationConversions.norm(q)
    }

    /// The bands' outputs, each written once by its own band.
    private nonisolated final class BandResults: @unchecked Sendable {
        private var bands: [[SIMD4<Double>]]
        private let lock = NSLock()

        init(count: Int) { bands = Array(repeating: [], count: count) }

        func set(_ band: Int, _ values: [SIMD4<Double>]) {
            lock.lock()
            bands[band] = values
            lock.unlock()
        }

        func joined() -> [SIMD4<Double>] {
            lock.lock()
            defer { lock.unlock() }
            return bands.flatMap { $0 }
        }
    }

    /// A task's cancellation as the bands read it from their own threads: raised once by the task's cancellation handler.
    private nonisolated final class CancellationFlag: Sendable {
        private let raised = Atomic<Bool>(false)

        func raise() { raised.store(true, ordering: .relaxed) }

        var isRaised: Bool { raised.load(ordering: .relaxed) }
    }
}
