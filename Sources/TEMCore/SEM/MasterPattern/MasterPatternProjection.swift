//
//  MasterPatternProjection.swift
//  Role: EBSD patterns projected from a master pattern in the square Lambert projection onto a detector, for crystal rotations
//        relative to the EDAX TSL sample frame: a port of kikuchipy 0.13.1's `EBSDMasterPattern.get_patterns` and of
//        `kikuchipy/signals/util/_master_pattern.py` (`_get_direction_cosines_for_fixed_pc` / `_varying_pc`,
//        `_project_single_pattern_from_master_pattern`, `_vector2lambert`, `_get_lambert_interpolation_parameters`,
//        `_get_pixel_from_master_pattern`), `_utils/numba.py::rotate_vector`, `pattern/_pattern.py::_rescale_with_min_max` and the
//        detector's `gnomonic_bounds` and `_sample_to_detector_matrix` (`detectors/_ebsd_detector.py`, after Britton et al. 2016),
//        GPL-3.0-or-later; the direction cosines and the Lambert interpolation are kikuchipy's adaptation of EMsoft (Callahan and
//        De Graef 2013; the square Lambert projection of Roşca 2010), BSD-3-Clause, both notices in NOTICE.
//        The float64 path below is the reference (decision D16); `MasterPatternProjectionMetal` is the float32 GPU path behind
//        `patternsFloat32`, checked against this one.
//        Parity: macTEMTests/MasterPatternParityTests.swift against tools/parity/sem/references/m6/project-master-pattern-*
//        (figure F15), within `np.allclose`'s defaults on the float values and one grey level on the integer ones.
//

import Foundation
import FormatoCore

package nonisolated enum MasterPatternProjection {
    /// `dtype_out`: the data type the patterns are returned in. A type other than the master pattern's own rescales each pattern
    /// to the type's range (`skimage`'s `dtype_range`: -1 to 1 for floats, 0 to the maximum for unsigned integers) before the cast.
    package enum OutputType: String, Sendable, CaseIterable {
        case float32, float64, uint8, uint16

        var range: (min: Double, max: Double) {
            switch self {
            case .float32, .float64: return (-1, 1)
            case .uint8: return (0, 255)
            case .uint16: return (0, 65_535)
            }
        }

        var formatoType: FormatoDataType {
            switch self {
            case .float32: return .float32
            case .float64: return .float64
            case .uint8: return .uint8
            case .uint16: return .uint16
            }
        }

        /// numpy's `astype` from float64: a float32 rounds to nearest, an unsigned integer truncates (the values are in range).
        func cast(_ x: Double) -> Double {
            switch self {
            case .float64: return x
            case .float32: return Double(Float(x))
            case .uint8, .uint16: return x.rounded(.towardZero)
            }
        }
    }

    /// Where `patternsFloat32` computes: the float64 CPU reference, the float32 GPU path, or the GPU when the work pays and a
    /// device is there.
    package enum Backend: Sendable, Equatable { case automatic, cpu, metal }

    /// Simulated patterns: `count` patterns of `rows x columns`, row-major, each value already in the output type.
    package struct Patterns: Sendable, Equatable {
        package var count: Int
        package var rows: Int
        package var columns: Int
        package var outputType: OutputType
        package var values: [Double]

        package func pattern(_ i: Int) -> ArraySlice<Double> {
            let n = rows * columns
            return values[i * n ..< (i + 1) * n]
        }
    }

    package enum Error: Swift.Error, LocalizedError, Equatable {
        case notLambert
        case needsBothHemispheres(pointGroup: String)
        case centreCount(centres: Int, rotations: Int)
        case emptyDetector
        case flatPattern(Int)
        case noMetalDevice
        case metal(String)

        package var errorDescription: String? {
            switch self {
            case .notLambert: return "The master pattern must be in the square Lambert projection."
            case .needsBothHemispheres(let pg):
                return "For point groups without inversion symmetry, like the current \(pg), both hemispheres must be present in the master pattern."
            case .centreCount(let c, let r):
                return "The detector has \(c) projection centres for \(r) rotations; it needs one, or one per rotation."
            case .emptyDetector: return "The detector has no pixels."
            case .flatPattern(let i): return "Pattern \(i) is flat, so it cannot be rescaled."
            case .noMetalDevice: return "This Mac has no Metal device for the GPU projection."
            case .metal(let text): return "The GPU projection failed: \(text)"
            }
        }
    }

    // MARK: - Detector geometry

    /// `_sample_to_detector_matrix(σ, θ, ω, γ)`: rows are the detector axes (X_d, Y_d, Z_d) in sample coordinates, so
    /// `M · v_sample = v_detector`. Starts from X_d = Y_s, Y_d = Z_s, Z_d = X_s and turns the basis by -σ (sample tilt) and θ
    /// (detector tilt) about its first vector, -ω (azimuthal) about its second, -γ (twist) about its third (Rodrigues). Degrees in;
    /// row-major 3 x 3 out.
    package static func sampleToDetector(sampleTilt: Double, tilt: Double, azimuthal: Double, twist: Double) -> [Double] {
        var basis: [[Double]] = [[0, 1, 0], [0, 0, 1], [1, 0, 0]]
        let rad = Double.pi / 180
        let steps: [(axis: Int, angle: Double)] = [(0, -sampleTilt * rad), (0, tilt * rad), (1, -azimuthal * rad), (2, -twist * rad)]
        for (i, angle) in steps {
            var u = basis[i]
            let norm = (u[0] * u[0] + u[1] * u[1] + u[2] * u[2]).squareRoot()
            u = u.map { $0 / norm }
            let c = cos(angle), s = sin(angle), oneMinusC = 1 - c
            for j in 0 ..< 3 {
                let v = basis[j]
                let dot = u[0] * v[0] + u[1] * v[1] + u[2] * v[2]
                let cx = u[1] * v[2] - u[2] * v[1]
                let cy = u[2] * v[0] - u[0] * v[2]
                let cz = u[0] * v[1] - u[1] * v[0]
                basis[j] = [v[0] * c + cx * s + u[0] * dot * oneMinusC,
                            v[1] * c + cy * s + u[1] * dot * oneMinusC,
                            v[2] * c + cz * s + u[2] * dot * oneMinusC]
            }
        }
        return basis.flatMap { $0 }
    }

    /// The detector bounds (x0, x1, y0, y1) in gnomonic coordinates for one Bruker-convention centre (`gnomonic_bounds`):
    /// x from -aspect·PCx/PCz to aspect·(1 − PCx)/PCz, y from −(1 − PCy)/PCz to PCy/PCz.
    package static func gnomonicBounds(rows: Int, columns: Int, pc: SIMD3<Double>) -> [Double] {
        let aspect = Double(columns) / Double(rows)
        return [-aspect * (pc.x / pc.z), aspect * (1 - pc.x) / pc.z, -(1 - pc.y) / pc.z, pc.y / pc.z]
    }

    /// The unit vectors from the source point to each detector pixel centre, in the sample frame, row-major
    /// (`_get_direction_cosines_for_fixed_pc`): the pixel's gnomonic centre times PCz, turned by the transpose of the sample-to-
    /// detector matrix, normalised.
    package static func directionCosines(rows: Int, columns: Int, pc: SIMD3<Double>, sampleToDetector m: [Double]) -> [SIMD3<Double>] {
        let b = gnomonicBounds(rows: rows, columns: columns, pc: pc)
        let xScale = (b[1] - b[0]) / Double(columns)
        let yScale = (b[3] - b[2]) / Double(rows)
        let xHalf = xScale / 2, yHalf = yScale / 2
        var out = [SIMD3<Double>](repeating: .zero, count: rows * columns)
        for r in 0 ..< rows {
            let gy = ((b[3] - Double(r) * yScale) - yHalf) * pc.z
            for c in 0 ..< columns {
                let gx = ((b[0] + Double(c) * xScale) + xHalf) * pc.z
                let gz = pc.z
                // Row vector times Mᵀ's transpose, i.e. Mᵀ · v: the detector-to-sample turn.
                let x = gx * m[0] + gy * m[3] + gz * m[6]
                let y = gx * m[1] + gy * m[4] + gz * m[7]
                let z = gx * m[2] + gy * m[5] + gz * m[8]
                let norm = (x * x + y * y + z * z).squareRoot()
                out[r * columns + c] = SIMD3(x / norm, y / norm, z / norm)
            }
        }
        return out
    }

    /// The detector's direction cosines for each of its centres (one set for one centre).
    package static func directionCosines(detector: EBSDDetectorGeometry) -> [[SIMD3<Double>]] {
        let m = sampleToDetector(sampleTilt: detector.sampleTilt, tilt: detector.tilt, azimuthal: detector.azimuthal, twist: detector.twist)
        return detector.projectionCenters.map { directionCosines(rows: detector.rows, columns: detector.columns, pc: $0, sampleToDetector: m) }
    }

    // MARK: - Projection

    /// `rotate_vector`: the vector turned by the unit quaternion (a, b, c, d) as kikuchipy writes it out.
    @inline(__always)
    package static func rotate(_ q: SIMD4<Double>, _ v: SIMD3<Double>) -> SIMD3<Double> {
        let a = q.x, b = q.y, c = q.z, d = q.w
        let aa = a * a, bb = b * b, cc = c * c, dd = d * d
        let ac = a * c, ab = a * b, ad = a * d, bc = b * c, bd = b * d, cd = c * d
        let x = v.x, y = v.y, z = v.z
        return SIMD3((aa + bb - cc - dd) * x + 2 * ((ac + bd) * z + (bc - ad) * y),
                     (aa - bb + cc - dd) * y + 2 * ((ad + bc) * x + (cd - ab) * z),
                     (aa - bb - cc + dd) * z + 2 * ((ab + cd) * y + (bd - ac) * x))
    }

    @inline(__always)
    static func sign(_ x: Double) -> Double { x > 0 ? 1 : (x < 0 ? -1 : 0) }

    /// `_vector2lambert`: the square Lambert coordinates (X, Y) of a vector (normalised first), (0, 0) at a pole.
    @inline(__always)
    package static func lambert(_ v: SIMD3<Double>) -> SIMD2<Double> {
        let norm = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        let x = v.x / norm, y = v.y / norm, z = v.z / norm
        let absZ = abs(z)
        let sqrtZ = (2 * (1 - absZ)).squareRoot()
        if absZ == 1 { return .zero }
        let sqrtPiOver2 = Double.pi.squareRoot() / 2
        let twoOverSqrtPi = 2 / Double.pi.squareRoot()
        if abs(y) <= abs(x) {
            let s = sign(x)
            return SIMD2(s * sqrtZ * sqrtPiOver2, s * sqrtZ * twoOverSqrtPi * atan(y / x))
        } else {
            let s = sign(y)
            return SIMD2(s * sqrtZ * twoOverSqrtPi * atan(x / y), s * sqrtZ * sqrtPiOver2)
        }
    }

    /// One pixel of a projected pattern before rescaling: the direction turned by the rotation, its Lambert coordinates scaled to
    /// the master pattern's pixels, and the bilinear interpolation of the upper (z ≥ 0) or lower hemisphere
    /// (`_get_lambert_interpolation_parameters` with EMsoft's edge clamps, `_get_pixel_from_master_pattern`).
    @inline(__always)
    static func sample(_ q: SIMD4<Double>, _ dc: SIMD3<Double>, upper: UnsafeBufferPointer<Float>, lower: UnsafeBufferPointer<Float>,
                       side: Int, scale: Double) -> Double {
        let v = rotate(q, dc)
        let l = lambert(v)
        let sqrtPiHalf = (Double.pi / 2).squareRoot()
        // `scale * _vector2lambert(v) / SQRT_PI_HALF`, then the int32 casts (truncation towards zero).
        let i = scale * l.y / sqrtPiHalf, j = scale * l.x / sqrtPiHalf
        var nii = Int(i + scale)
        var nij = Int(j + scale)
        var niip = nii + 1, nijp = nij + 1
        if niip >= side { niip = nii }
        if nijp >= side { nijp = nij }
        if nii < 0 { nii = niip }
        if nij < 0 { nij = nijp }
        let di = i - Double(nii) + scale, dj = j - Double(nij) + scale
        let dim = 1 - di, djm = 1 - dj
        let mp = v.z >= 0 ? upper : lower
        return Double(mp[nii * side + nij]) * dim * djm + Double(mp[niip * side + nij]) * di * djm
            + Double(mp[nii * side + nijp]) * dim * dj + Double(mp[niip * side + nijp]) * di * dj
    }

    /// The master pattern's suitability for a projection (`_is_suitable_for_projection`): Lambert, and both hemispheres unless the
    /// point group holds the inversion.
    package static func checkSuitable(_ master: EBSDMasterPattern) throws {
        guard master.projection == .lambert else { throw Error.notLambert }
        if master.hemisphere != .both, !master.phase.containsInversion {
            throw Error.needsBothHemispheres(pointGroup: master.phase.pointGroup)
        }
    }

    /// `EBSDMasterPattern.get_patterns(rotations, detector, energy, dtype_out)`, float64 on the CPU: one pattern per unit quaternion
    /// (a, b, c, d) in orix's convention, with the detector's single centre or one centre per rotation; `energy` picks the master
    /// pattern of a multi-energy file (the highest when nil). The reference path.
    package static func project(master: EBSDMasterPattern, rotations: [SIMD4<Double>], detector: EBSDDetectorGeometry,
                                energy: Double? = nil, output: OutputType = .float32) throws -> Patterns {
        try checkSuitable(master)
        let centres = detector.projectionCenters.count
        guard centres == 1 || centres == rotations.count else { throw Error.centreCount(centres: centres, rotations: rotations.count) }
        let pixels = detector.rows * detector.columns
        guard pixels > 0 else { throw Error.emptyDetector }
        let (upperSlice, lowerSlice) = try master.hemispheres(energy: energy)
        if rotations.isEmpty { return Patterns(count: 0, rows: detector.rows, columns: detector.columns, outputType: output, values: []) }
        let cosines = directionCosines(detector: detector)
        let rescale = output.formatoType != master.dataType
        let (omin, omax) = output.range
        let side = master.side
        let scale = Double(side - 1) / 2
        var values = [Double](repeating: 0, count: rotations.count * pixels)
        let upper = Array(upperSlice), lower = Array(lowerSlice)
        upper.withUnsafeBufferPointer { up in
            lower.withUnsafeBufferPointer { lo in
                values.withUnsafeMutableBufferPointer { out in
                    let shared = SharedBuffers(upper: up, lower: lo, out: out.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: rotations.count) { n in
                        let upperRows = shared.upper, lowerRows = shared.lower, base = shared.out
                        let dc = cosines[centres == 1 ? 0 : n]
                        let q = rotations[n]
                        let row = base + n * pixels
                        var lowest = Double.infinity, highest = -Double.infinity
                        for p in 0 ..< pixels {
                            let x = sample(q, dc[p], upper: upperRows, lower: lowerRows, side: side, scale: scale)
                            row[p] = x
                            lowest = min(lowest, x); highest = max(highest, x)
                        }
                        if rescale {
                            // `_rescale_with_min_max`: (x − min) / (max − min) · (omax − omin) + omin.
                            let span = highest - lowest
                            for p in 0 ..< pixels { row[p] = output.cast((row[p] - lowest) / span * (omax - omin) + omin) }
                        } else {
                            for p in 0 ..< pixels { row[p] = output.cast(row[p]) }
                        }
                    }
                }
            }
        }
        // A flat pattern divides zero by zero in the rescale, as kikuchipy's does: refused instead of handing NaN on.
        if rescale, let flat = (0 ..< rotations.count).first(where: { values[$0 * pixels].isNaN }) { throw Error.flatPattern(flat) }
        return Patterns(count: rotations.count, rows: detector.rows, columns: detector.columns, outputType: output, values: values)
    }

    /// The buffers `project` shares across its patterns: the hemispheres are only read, each pattern writes its own rows.
    private struct SharedBuffers: @unchecked Sendable {
        let upper: UnsafeBufferPointer<Float>
        let lower: UnsafeBufferPointer<Float>
        let out: UnsafeMutablePointer<Double>
    }

    /// Work (patterns × pixels) from which the GPU pays for its setup and transfer on the automatic backend: about 300 patterns of
    /// 60 x 60 px, i.e. a dictionary, not a single overlay.
    package static let metalWorkThreshold = 1_000_000

    /// The patterns in float32 (`get_patterns`' default `dtype_out`: rescaled to -1 ... 1 unless the master pattern is float32 already,
    /// as EMsoft writes it), from the CPU reference or the float32 GPU path (`MasterPatternProjectionMetal`, checked against the CPU
    /// within `MasterPatternProjectionMetal.tolerance` of the pattern's half range). The automatic backend takes the GPU from
    /// `metalWorkThreshold` on when a device is there.
    package static func patternsFloat32(master: EBSDMasterPattern, rotations: [SIMD4<Double>], detector: EBSDDetectorGeometry,
                                        energy: Double? = nil, backend: Backend = .automatic) throws -> [Float] {
        let work = rotations.count * detector.rows * detector.columns
        let useMetal: Bool
        switch backend {
        case .cpu: useMetal = false
        case .metal: useMetal = true
        case .automatic: useMetal = work >= metalWorkThreshold && MasterPatternProjectionMetal.isAvailable
        }
        if useMetal {
            return try MasterPatternProjectionMetal.project(master: master, rotations: rotations, detector: detector, energy: energy)
        }
        return try project(master: master, rotations: rotations, detector: detector, energy: energy, output: .float32).values.map { Float($0) }
    }

    /// `patternsFloat32` off the caller's actor (a dictionary is seconds of work).
    @concurrent package static func patternsFloat32Async(master: EBSDMasterPattern, rotations: [SIMD4<Double>], detector: EBSDDetectorGeometry,
                                                         energy: Double? = nil, backend: Backend = .automatic) async throws -> [Float] {
        try patternsFloat32(master: master, rotations: rotations, detector: detector, energy: energy, backend: backend)
    }
}
