//
//  NelderMead.swift
//  The downhill simplex method of Nelder and Mead (1965, Comput. J. 7, 308), as SciPy 1.18.1's
//  `scipy.optimize._optimize._minimize_neldermead` runs it under `minimize(method="Nelder-Mead")`: the initial simplex
//  (5 % along each axis, 0.00025 for a zero coordinate), reflection, expansion, outside and inside contraction and shrink
//  with the standard coefficients (or Gao and Han 2012's adaptive ones), bounds by clipping every trial point and by
//  reflecting the initial simplex into the box, the stop on xatol and fatol together (both 1e-4 by default), and
//  `maxiter` / `maxfev` (200 per variable by default) with the evaluation counter that stops an iteration part way, as
//  SciPy's `_MaxFuncCallError` does. The simplex is ordered by numpy's `argsort` of the values, which on so few points is
//  an insertion sort: stable, NaN last.
//  SciPy is BSD-3-Clause (NOTICE). kikuchipy 0.13.1 refines orientations and projection centres with this solver
//  (`EBSDRefinement`). Parity: `m4/nelder-mead` (x, fun, nfev, nit, status and the final simplex, step for step).
//

import Foundation

package nonisolated enum NelderMead {
    package struct Options: Sendable, Equatable {
        /// Absolute change in the simplex's points at which it has converged (with `fatol`).
        package var xatol: Double = 1e-4
        /// Absolute change in the function's values at which it has converged (with `xatol`).
        package var fatol: Double = 1e-4
        package var maxiter: Int?
        package var maxfev: Int?
        /// Gao and Han's dimension-dependent coefficients.
        package var adaptive = false

        package init(xatol: Double = 1e-4, fatol: Double = 1e-4, maxiter: Int? = nil, maxfev: Int? = nil, adaptive: Bool = false) {
            self.xatol = xatol; self.fatol = fatol; self.maxiter = maxiter; self.maxfev = maxfev; self.adaptive = adaptive
        }
    }

    package struct Bound: Sendable, Equatable {
        package var lower: Double
        package var upper: Double
        package init(_ lower: Double, _ upper: Double) { self.lower = lower; self.upper = upper }
    }

    package struct Result: Sendable, Equatable {
        package var x: [Double]
        /// The lowest value in the final simplex (`np.min`, NaN if one is NaN).
        package var fun: Double
        package var nfev: Int
        package var nit: Int
        /// 0 converged, 1 the evaluation limit, 2 the iteration limit (SciPy's `status`).
        package var status: Int
        package var finalSimplex: [[Double]]
        package var finalValues: [Double]
    }

    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case empty
        case boundsCount(bounds: Int, variables: Int)
        case lowerAboveUpper(Int)

        package var errorDescription: String? {
            switch self {
            case .empty: return "Nelder-Mead needs at least one variable."
            case .boundsCount(let b, let v): return "There are \(b) bounds for \(v) variables."
            case .lowerAboveUpper(let i): return "Nelder-Mead: the lower bound of variable \(i) is greater than its upper bound."
            }
        }
    }

    /// SciPy's `_MaxFuncCallError`: the next call would pass `maxfev`.
    private struct TooManyCalls: Swift.Error {}

    /// `minimize(f, x0, method="Nelder-Mead", bounds=bounds, options=...)`.
    package static func minimize(_ f: ([Double]) -> Double, x0 start: [Double], bounds: [Bound]? = nil,
                                 options: Options = Options()) throws -> Result {
        let n = start.count
        guard n > 0 else { throw Error.empty }
        if let bounds {
            guard bounds.count == n else { throw Error.boundsCount(bounds: bounds.count, variables: n) }
            if let i = bounds.firstIndex(where: { $0.lower > $0.upper }) { throw Error.lowerAboveUpper(i) }
        }
        let rho: Double, chi: Double, psi: Double, sigma: Double
        if options.adaptive {
            let dim = Double(n)
            rho = 1; chi = 1 + 2 / dim; psi = 0.75 - 1 / (2 * dim); sigma = 1 - 1 / dim
        } else {
            rho = 1; chi = 2; psi = 0.5; sigma = 0.5
        }
        let nonzdelt = 0.05, zdelt = 0.00025

        func clip(_ x: [Double]) -> [Double] {
            guard let bounds else { return x }
            return x.indices.map { Swift.min(Swift.max(x[$0], bounds[$0].lower), bounds[$0].upper) }
        }

        let x0 = clip(start)
        var sim = [x0]
        for k in 0..<n {
            var y = x0
            y[k] = y[k] != 0 ? (1 + nonzdelt) * y[k] : zdelt
            sim.append(y)
        }

        // SciPy's None → inf conversions (an Int.max stands for inf).
        let inf = Int.max
        var maxiter = options.maxiter ?? inf
        var maxfun = options.maxfev ?? inf
        if options.maxiter == nil, options.maxfev == nil {
            maxiter = n * 200; maxfun = n * 200
        } else if options.maxiter == nil {
            maxiter = maxfun == inf ? n * 200 : inf
        } else if options.maxfev == nil {
            maxfun = maxiter == inf ? n * 200 : inf
        }

        if let bounds {
            // A simplex entry past its upper bound is reflected into the box, then everything is clipped.
            for j in sim.indices {
                for i in 0..<n {
                    var v = sim[j][i]
                    if v > bounds[i].upper { v = 2 * bounds[i].upper - v }
                    sim[j][i] = Swift.min(Swift.max(v, bounds[i].lower), bounds[i].upper)
                }
            }
        }

        var calls = 0
        func call(_ x: [Double]) throws -> Double {
            if calls >= maxfun { throw TooManyCalls() }
            calls += 1
            return f(x)
        }

        var fsim = [Double](repeating: .infinity, count: n + 1)
        do {
            for k in 0...n { fsim[k] = try call(sim[k]) }
        } catch {}
        order(&sim, &fsim)

        var iterations = 1
        while calls < maxfun, iterations < maxiter {
            do {
                if maxAbsDifference(sim, from: 0) <= options.xatol, maxAbsDifference(fsim) <= options.fatol { break }
                // np.add.reduce(sim[:-1], 0): the rows added one after another.
                var xbar = sim[0]
                for j in 1..<n { for i in 0..<n { xbar[i] += sim[j][i] } }
                xbar = xbar.map { $0 / Double(n) }
                let worst = sim[n]
                let xr = clip((0..<n).map { (1 + rho) * xbar[$0] - rho * worst[$0] })
                let fxr = try call(xr)
                var doshrink = false
                if fxr < fsim[0] {
                    let xe = clip((0..<n).map { (1 + rho * chi) * xbar[$0] - rho * chi * worst[$0] })
                    let fxe = try call(xe)
                    if fxe < fxr {
                        sim[n] = xe; fsim[n] = fxe
                    } else {
                        sim[n] = xr; fsim[n] = fxr
                    }
                } else if fxr < fsim[n - 1] {
                    sim[n] = xr; fsim[n] = fxr
                } else if fxr < fsim[n] {
                    let xc = clip((0..<n).map { (1 + psi * rho) * xbar[$0] - psi * rho * worst[$0] })
                    let fxc = try call(xc)
                    if fxc <= fxr {
                        sim[n] = xc; fsim[n] = fxc
                    } else {
                        doshrink = true
                    }
                } else {
                    let xcc = clip((0..<n).map { (1 - psi) * xbar[$0] + psi * worst[$0] })
                    let fxcc = try call(xcc)
                    if fxcc < fsim[n] {
                        sim[n] = xcc; fsim[n] = fxcc
                    } else {
                        doshrink = true
                    }
                }
                if doshrink {
                    for j in 1...n {
                        sim[j] = clip((0..<n).map { sim[0][$0] + sigma * (sim[j][$0] - sim[0][$0]) })
                        fsim[j] = try call(sim[j])
                    }
                }
                iterations += 1
            } catch {}
            order(&sim, &fsim)
        }

        let status = calls >= maxfun ? 1 : (iterations >= maxiter ? 2 : 0)
        let fval = fsim.contains(where: \.isNaN) ? .nan : fsim.min()!
        return Result(x: sim[0], fun: fval, nfev: calls, nit: iterations, status: status, finalSimplex: sim, finalValues: fsim)
    }

    /// numpy's `argsort` on a few values (insertion sort: stable, NaN after every number), applied to points and values.
    static func order(_ sim: inout [[Double]], _ fsim: inout [Double]) {
        func less(_ a: Double, _ b: Double) -> Bool { a < b || (b.isNaN && !a.isNaN) }
        var idx = Array(fsim.indices)
        for i in 1..<idx.count {
            let v = idx[i]
            var j = i
            while j > 0, less(fsim[v], fsim[idx[j - 1]]) {
                idx[j] = idx[j - 1]
                j -= 1
            }
            idx[j] = v
        }
        sim = idx.map { sim[$0] }
        fsim = idx.map { fsim[$0] }
    }

    /// `np.max(np.abs(sim[1:] - sim[0]))`, NaN when any difference is NaN (so the convergence test fails, as numpy's does).
    private static func maxAbsDifference(_ sim: [[Double]], from first: Int) -> Double {
        var m = -Double.infinity
        for j in 1..<sim.count {
            for i in sim[j].indices {
                let d = abs(sim[j][i] - sim[first][i])
                if d.isNaN { return .nan }
                m = Swift.max(m, d)
            }
        }
        return m
    }

    /// `np.max(np.abs(fsim[0] - fsim[1:]))`.
    private static func maxAbsDifference(_ fsim: [Double]) -> Double {
        var m = -Double.infinity
        for j in 1..<fsim.count {
            let d = abs(fsim[0] - fsim[j])
            if d.isNaN { return .nan }
            m = Swift.max(m, d)
        }
        return m
    }
}
