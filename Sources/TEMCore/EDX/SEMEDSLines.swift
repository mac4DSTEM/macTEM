//
//  SEMEDSLines.swift
//  Role: SEM-EDS line intensities and Cliff-Lorimer quantification of one spectrum, ported function by function from eXSpy 0.3.2
//        (https://github.com/hyperspy/exspy, GPL-3.0-or-later, taken under GPL-3.0): `signals/eds.py` (`_get_lines_from_elements`,
//        `_get_xray_lines_in_spectral_range`, `estimate_integration_windows`, `estimate_background_windows`, `get_lines_intensity`,
//        `get_take_off_angle`), `_misc/eds/utils.py` (`get_FWHM_at_Energy`, `take_off_angle`, `quantification_cliff_lorimer`,
//        `_quantification_cliff_lorimer`), `_misc/material.py` (`_weight_to_atomic`) and the energy-to-channel rule of the axis they
//        slice with, HyperSpy 2.5.0's `UniformDataAxis.value2index` and `_get_array_slices` (GPL-3.0-or-later). SpectroKit is not
//        touched (the SEM program's rule); its model-fit quantification stays the EDS room's own path, this is exspy's window path.
//
//  Numbers: float64 throughout, the operations in exspy's order, so a window edge and an intensity land on exspy's double. The
//  spectrum is a few thousand channels: plain loops on the CPU (D16: small arrays stay on the CPU). Parity: the bundles
//  `m7/eds-lines-tm002` (F16) and `m7/eds-quant-tm002` (F17, its `db_` arrays exact) at rtol 1e-7 (SEMEDSParityTests).
//  Energies are keV: a file on an eV axis is converted on reading, so exspy's eV branch (the same formula times 1000) is not kept.
//

import Foundation

package nonisolated enum SEMEDSLines {
    /// What the acquisition says about the detector and the stage, as exspy reads `Acquisition_instrument.SEM`; a value the file does not
    /// state takes exspy's preference default (`_set_default_param`, `EDSConfig`).
    package struct Conditions: Equatable, Sendable {
        package var beamEnergyKeV: Double?
        /// `Detector.EDS.energy_resolution_MnKa`, eV (default 130).
        package var energyResolutionMnKaEV: Double
        /// `Detector.EDS.elevation_angle`, degrees (default 35).
        package var elevationAngleDeg: Double
        /// `Detector.EDS.azimuth_angle`, degrees (default 0).
        package var azimuthAngleDeg: Double
        /// `Stage.tilt_alpha`, degrees (default 0).
        package var tiltAlphaDeg: Double
        /// `Stage.tilt_beta`, degrees (default 0, as `get_take_off_angle` reads it).
        package var tiltBetaDeg: Double
        package var liveTimeS: Double?
        package var realTimeS: Double?

        package static let defaultResolutionMnKaEV = 130.0, defaultElevationDeg = 35.0, defaultAzimuthDeg = 0.0, defaultTiltDeg = 0.0

        package init(beamEnergyKeV: Double?, energyResolutionMnKaEV: Double? = nil, elevationAngleDeg: Double? = nil,
                     azimuthAngleDeg: Double? = nil, tiltAlphaDeg: Double? = nil, tiltBetaDeg: Double? = nil,
                     liveTimeS: Double? = nil, realTimeS: Double? = nil) {
            self.beamEnergyKeV = beamEnergyKeV
            self.energyResolutionMnKaEV = energyResolutionMnKaEV ?? Self.defaultResolutionMnKaEV
            self.elevationAngleDeg = elevationAngleDeg ?? Self.defaultElevationDeg
            self.azimuthAngleDeg = azimuthAngleDeg ?? Self.defaultAzimuthDeg
            self.tiltAlphaDeg = tiltAlphaDeg ?? Self.defaultTiltDeg
            self.tiltBetaDeg = tiltBetaDeg ?? 0
            self.liveTimeS = liveTimeS
            self.realTimeS = realTimeS
        }

        /// `get_take_off_angle()`: the take-off angle from the stage tilts and the detector's azimuth and elevation, degrees.
        package var takeOffAngleDeg: Double {
            SEMEDSLines.takeOffAngle(tiltStage: tiltAlphaDeg, azimuth: azimuthAngleDeg, elevation: elevationAngleDeg, betaTilt: tiltBetaDeg)
        }
    }

    /// The spectrum's energy axis in keV: channel i is at `offset + i · scale`.
    package struct Axis: Equatable, Sendable {
        package var offsetKeV: Double
        package var scaleKeV: Double
        package var size: Int

        package init(offsetKeV: Double, scaleKeV: Double, size: Int) {
            self.offsetKeV = offsetKeV
            self.scaleKeV = scaleKeV
            self.size = size
        }

        package var lowValue: Double { offsetKeV }
        /// HyperSpy's `high_value`: the last channel's energy, `axis[-1]` of `offset + scale · arange(size)`.
        package var highValue: Double { offsetKeV + scaleKeV * Double(size - 1) }
    }

    /// Why a computation is refused, in a sentence for the inspector.
    package struct Refusal: Error, LocalizedError, Equatable {
        package var text: String
        package init(_ text: String) { self.text = text }
        package var errorDescription: String? { text }
    }

    // MARK: - Lines

    /// The line families exspy's default `only_lines=("a",)` expands to (`_parse_only_lines`).
    package static let alphaLines: Set<String> = ["a", "Ka", "La", "Ma"]

    /// Python's string order (code points), the order `sort()` gives exspy's line names.
    package static func pythonOrder(_ a: String, _ b: String) -> Bool { a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }

    /// The energy of `Element_Line` in keV (`_get_energy_xray_line`), or nil when exspy's database has no such line.
    package static func energy(_ xrayLine: String) -> Double? { XrayLineDatabase.line(xrayLine)?.energyKeV }

    /// `_get_xray_lines_in_spectral_range`: the lines strictly between the axis' low value and the smaller of its high value and the
    /// beam energy; the second list is the rest (exspy warns about them).
    package static func linesInSpectralRange(_ lines: [String], axis: Axis, beamEnergyKeV: Double?) -> (inRange: [String], outOfRange: [String]) {
        let low = axis.lowValue
        var high = axis.highValue
        if let beam = beamEnergyKeV, beam < high { high = beam }
        var inside: [String] = [], outside: [String] = []
        for line in lines {
            if let e = energy(line), low < e, e < high { inside.append(line) } else { outside.append(line) }
        }
        return (inside, outside)
    }

    /// `_get_lines_from_elements(elements, only_one=True, only_lines=("a",))`, which `add_lines()` runs for `Sample.elements`: for each
    /// element its Kα, Lα and Mα lines in the spectral range, sorted; with `onlyOne` the first of them below half the beam energy
    /// (overvoltage 2), else the last; all lines sorted at the end. Without a beam energy, the axis' high value stands in, as exspy's
    /// fallback. An element exspy lists without lines, or a symbol it does not know, adds none.
    package static func lines(forElements elements: [String], axis: Axis, beamEnergyKeV: Double?, onlyOne: Bool = true,
                              onlyLines: Set<String> = alphaLines) -> [String] {
        let beam = beamEnergyKeV ?? axis.highValue
        var out: [String] = []
        for symbol in elements {
            guard let element = XrayLineDatabase.element(symbol) else { continue }
            var candidates = element.lines.filter { onlyLines.isEmpty || onlyLines.contains($0.name) }.map { "\(symbol)_\($0.name)" }
            candidates = linesInSpectralRange(candidates, axis: axis, beamEnergyKeV: beamEnergyKeV).inRange
            if onlyOne, !candidates.isEmpty {
                candidates.sort(by: pythonOrder)
                let pick = candidates.first { (energy($0) ?? .infinity) < beam / 2 } ?? candidates[candidates.count - 1]
                candidates = [pick]
            }
            out.append(contentsOf: candidates)
        }
        return out.sorted(by: pythonOrder)
    }

    // MARK: - Line width and windows

    /// `get_FWHM_at_Energy` (Fiori and Newbury 1978; Goldstein et al. 2003, p. 315): the detector's FWHM at `energyKeV` from its FWHM at
    /// Mn Kα, `sqrt(2.5 · (E − E_MnKa) · 1000 + FWHM_MnKa²) / 1000`, keV.
    package static func fwhm(atKeV energyKeV: Double, resolutionMnKaEV: Double) -> Double {
        let reference = XrayLineDatabase.line("Mn_Ka")?.energyKeV ?? 5.8987
        let squared = 2.5 * (energyKeV - reference) * 1000.0 + resolutionMnKaEV * resolutionMnKaEV
        return squared.squareRoot() / 1000.0
    }

    /// `estimate_integration_windows(windows_width)`: per line `[E − w · FWHM / 2, E + w · FWHM / 2]`, keV.
    package static func integrationWindows(_ lines: [String], width: Double = 2.0, resolutionMnKaEV: Double) throws -> [[Double]] {
        try lines.map { line in
            guard let e = energy(line) else { throw Refusal("\(line) is not an X-ray line exspy knows.") }
            let det = width * fwhm(atKeV: e, resolutionMnKaEV: resolutionMnKaEV) / 2.0
            return [e - det, e + det]
        }
    }

    /// `estimate_background_windows(line_width, windows_width)`: per line a window left of the line at `lineWidth.left` FWHM and one right
    /// of it at `lineWidth.right` FWHM, each `windowsWidth` FWHM wide, `[l0, l1, r0, r1]` keV; then exspy's merge of overlapping windows,
    /// kept as it is (lines taken by their left edge; where a line's right window passes the next line's left edge, both lines take the
    /// first's left window and the second's right window, in place, so a merge carries on down the chain).
    package static func backgroundWindows(_ lines: [String], lineWidth: (left: Double, right: Double) = (2, 2), windowsWidth: Double = 1,
                                          resolutionMnKaEV: Double) throws -> [[Double]] {
        var windows: [[Double]] = try lines.map { line in
            guard let e = energy(line) else { throw Refusal("\(line) is not an X-ray line exspy knows.") }
            let f = fwhm(atKeV: e, resolutionMnKaEV: resolutionMnKaEV)
            return [e - f * lineWidth.left - f * windowsWidth, e - f * lineWidth.left, e + f * lineWidth.right, e + f * lineWidth.right + f * windowsWidth]
        }
        // numpy's argsort of the left edges (the first column of the original windows); ties keep their order.
        let order = windows.indices.sorted { a, b in windows[a][0] != windows[b][0] ? windows[a][0] < windows[b][0] : a < b }
        if order.count > 1 {
            for i in 0 ..< order.count - 1 {
                let a = order[i], b = order[i + 1]
                if windows[a][2] > windows[b][0] {
                    let merged = [windows[a][0], windows[a][1], windows[b][2], windows[b][3]]
                    windows[a] = merged
                    windows[b] = merged
                }
            }
        }
        return windows
    }

    // MARK: - The axis' energy-to-channel rule (HyperSpy)

    /// `UniformDataAxis.value2index(value)` with its default rounding: `trunc((v − offset) / scale · 1e12)` scaled back by 1e-12, then
    /// half towards zero for a non-negative value and half away from zero for a negative one; nil where HyperSpy raises (out of the axis).
    package static func index(of value: Double, axis: Axis) -> Int? {
        guard value.isFinite else { return nil }
        let multiplier = 1e12
        let raw = 1 / multiplier * ((value - axis.offsetKeV) / axis.scaleKeV * multiplier).rounded(.towardZero)
        let rounded: Double
        if value >= 0 {
            rounded = raw >= 0 ? (raw - 0.5).rounded(.up) : (raw + 0.5).rounded(.down)
        } else {
            rounded = raw >= 0 ? (raw + 0.5).rounded(.down) : (raw - 0.5).rounded(.up)
        }
        guard rounded >= 0, rounded < Double(axis.size) else { return nil }
        return Int(rounded)
    }

    /// The channels `isig[start:stop]` takes for two energies (`_get_array_slices`): a start below the axis starts at channel 0, a stop
    /// above it runs to the end; a start above the axis or a stop below it is refused, as HyperSpy raises.
    package static func channels(from start: Double, to stop: Double, axis: Axis) throws -> Range<Int> {
        let first: Int
        if let i = index(of: start, axis: axis) { first = i } else if start > axis.highValue {
            throw Refusal(String(format: "A window starts at %.4g keV, above the spectrum's end.", start))
        } else { first = 0 }
        let last: Int
        if let i = index(of: stop, axis: axis) { last = i } else if stop < axis.lowValue {
            throw Refusal(String(format: "A window ends at %.4g keV, below the spectrum's start.", stop))
        } else { last = axis.size }
        return first ..< max(first, last)
    }

    // MARK: - Intensities

    /// `get_lines_intensity(integration_windows=…, background_windows=…)` on one spectrum: the counts summed over each integration window
    /// (the EDS axis is binned, so `integrate1D` is a sum) and, with background windows, minus the sum of the two background windows
    /// scaled by the integration window's channel count over theirs (`corr_factor`). A background window narrower than one channel reads
    /// its one channel, as exspy does; a window off the axis is refused where exspy raises.
    package static func intensities(counts: [Double], axis: Axis, integrationWindows: [[Double]], backgroundWindows: [[Double]]? = nil) throws -> [Double] {
        guard counts.count == axis.size else { throw Refusal("The spectrum has \(counts.count) channels and its axis \(axis.size).") }
        if let bw = backgroundWindows, bw.count != integrationWindows.count {
            throw Refusal("\(bw.count) background windows for \(integrationWindows.count) lines.")
        }
        func sum(_ r: Range<Int>) -> Double { r.reduce(0.0) { $0 + counts[$1] } }
        var out: [Double] = []
        for (i, window) in integrationWindows.enumerated() {
            guard window.count == 2 else { throw Refusal("An integration window needs two edges.") }
            let range = try channels(from: window[0], to: window[1], axis: axis)
            guard !range.isEmpty else { throw Refusal(String(format: "The window at %.4g keV is narrower than one channel.", window[0])) }
            var intensity = sum(range)
            if let bw = backgroundWindows?[i] {
                guard bw.count == 4 else { throw Refusal("A background window pair needs four edges.") }
                var idx: [Double] = []
                for value in bw + window {
                    guard let k = index(of: value, axis: axis) else {
                        throw Refusal(String(format: "A background window edge at %.4g keV is outside the spectrum.", value))
                    }
                    idx.append(Double(k))
                }
                let left = try idx[0] == idx[1] ? counts[Int(idx[0])] : sum(channels(from: bw[0], to: bw[1], axis: axis))
                let right = try idx[2] == idx[3] ? counts[Int(idx[2])] : sum(channels(from: bw[2], to: bw[3], axis: axis))
                let width = (idx[1] - idx[0]) + (idx[3] - idx[2])
                guard width != 0 else { throw Refusal("Both background windows of a line are narrower than one channel.") }
                let correction = (idx[5] - idx[4]) / width
                intensity -= (left + right) * correction
            }
            out.append(intensity)
        }
        return out
    }

    // MARK: - Quantification

    /// `quantification_cliff_lorimer(intensities, kfactors)` for one spectrum, as `quantification(method="CL")` calls it (no absorption
    /// correction), as weight fractions: lines at or below exspy's 0.1-count floor do not serve as the reference; with fewer than two
    /// lines above it the composition is zero, or one for the single line above it.
    package static func cliffLorimer(intensities: [Double], kFactors: [Double]) throws -> [Double] {
        guard intensities.count == kFactors.count else {
            throw Refusal("The number of k-factors (\(kFactors.count)) must match the number of lines (\(intensities.count)).")
        }
        let minIntensity = 0.1
        let above = intensities.indices.filter { intensities[$0] > minIntensity }
        guard above.count > 1 else {
            var zero = [Double](repeating: 0, count: intensities.count)
            if let only = above.first { zero[only] = 1.0 }
            return zero
        }
        let ref = above[0], ref2 = above[1]
        var ab = [Double](repeating: 0, count: intensities.count)
        var composition = [Double](repeating: 1, count: intensities.count)
        let others = intensities.indices.filter { $0 != ref }
        for i in others {
            ab[i] = (intensities[ref] * 1.0) / (intensities[i] * 1.0) * (kFactors[ref] / kFactors[i])
        }
        for i in others {
            if i == ref2 { composition[ref] += ab[ref2] } else { composition[ref] += ab[ref2] / ab[i] }
        }
        composition[ref] = ab[ref2] / composition[ref]
        for i in others { composition[i] = composition[ref] / ab[i] }
        return composition
    }

    /// `weight_to_atomic(weight_percent, elements)`: each weight percent over its atomic weight (exspy's database), renormalised to 100;
    /// zero where the weights sum to zero.
    package static func weightToAtomic(weightPercent: [Double], elements: [String]) throws -> [Double] {
        guard weightPercent.count == elements.count else { throw Refusal("The number of elements must match the number of weight percents.") }
        var atomic: [Double] = []
        for (w, symbol) in zip(weightPercent, elements) {
            guard let a = XrayLineDatabase.element(symbol)?.atomicWeight else { throw Refusal("\(symbol) is not an element exspy knows.") }
            atomic.append(w / a)
        }
        let total = atomic.reduce(0, +) / 100.0
        return atomic.map { total == 0 ? 0 : $0 / total }
    }

    // MARK: - The EDS room's table

    /// One line of the table the EDS room shows for an SEM spectrum: the line, its windows and its counts.
    package struct LineRow: Equatable, Sendable, Identifiable {
        package var line: String
        package var element: String
        package var energyKeV: Double
        package var fwhmKeV: Double
        /// `[start, end]` keV.
        package var integrationWindow: [Double]
        /// `[l0, l1, r0, r1]` keV, nil when the background is not subtracted.
        package var backgroundWindows: [Double]?
        /// The counts in the integration window.
        package var rawIntensity: Double
        /// The counts minus the scaled background; nil without background windows.
        package var netIntensity: Double?
        package var id: String { line }
        /// What quantification reads: the net counts when there is a background, else the raw ones (exspy quantifies what
        /// `get_lines_intensity` returned).
        package var intensity: Double { netIntensity ?? rawIntensity }
    }

    /// The line table of one spectrum, exspy's tutorial in one call: the lines `add_lines()` picks for `elements`, their integration
    /// windows (`integrationWidth` FWHM), the background windows when `backgroundLineWidth` is given (exspy's tutorial uses (5, 2)),
    /// and the raw and background-subtracted intensities.
    package static func table(counts: [Double], axis: Axis, elements: [String], conditions: Conditions, integrationWidth: Double = 2.0,
                              backgroundLineWidth: (left: Double, right: Double)? = (5.0, 2.0), windowsWidth: Double = 1.0) throws -> [LineRow] {
        let lines = Self.lines(forElements: elements, axis: axis, beamEnergyKeV: conditions.beamEnergyKeV)
        guard !lines.isEmpty else { return [] }
        let resolution = conditions.energyResolutionMnKaEV
        let integration = try integrationWindows(lines, width: integrationWidth, resolutionMnKaEV: resolution)
        let raw = try intensities(counts: counts, axis: axis, integrationWindows: integration)
        var background: [[Double]]?
        var net: [Double]?
        if let lw = backgroundLineWidth {
            let bw = try backgroundWindows(lines, lineWidth: lw, windowsWidth: windowsWidth, resolutionMnKaEV: resolution)
            background = bw
            net = try intensities(counts: counts, axis: axis, integrationWindows: integration, backgroundWindows: bw)
        }
        return lines.enumerated().map { i, line in
            let e = energy(line) ?? 0
            return LineRow(line: line, element: String(line.split(separator: "_").first ?? ""), energyKeV: e,
                           fwhmKeV: fwhm(atKeV: e, resolutionMnKaEV: resolution), integrationWindow: integration[i],
                           backgroundWindows: background?[i], rawIntensity: raw[i], netIntensity: net?[i])
        }
    }

    /// One element's share of the composition.
    package struct Composition: Equatable, Sendable, Identifiable {
        package var line: String
        package var element: String
        package var weightPercent: Double
        package var atomicPercent: Double
        package var id: String { line }
    }

    /// Cliff-Lorimer on the table's intensities with one k-factor per row (exspy's `quantification(method="CL")` times 100), and the
    /// atomic percent from the weight percent.
    package static func quantify(_ rows: [LineRow], kFactors: [Double]) throws -> [Composition] {
        guard rows.count > 1 else { throw Refusal("Cliff-Lorimer needs at least two lines.") }
        guard kFactors.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw Refusal("Every k-factor must be a positive number.") }
        let fractions = try cliffLorimer(intensities: rows.map(\.intensity), kFactors: kFactors)
        let weight = fractions.map { $0 * 100.0 }
        let atomic = try weightToAtomic(weightPercent: weight, elements: rows.map(\.element))
        return rows.indices.map { Composition(line: rows[$0].line, element: rows[$0].element, weightPercent: weight[$0], atomicPercent: atomic[$0]) }
    }

    // MARK: - Take-off angle

    /// `take_off_angle(tilt_stage, azimuth_angle, elevation_angle, beta_tilt)`, degrees:
    /// `90 − acos(sin α cos β cos φ cos θ − sin β sin φ cos θ − cos α cos β sin θ)` with α the stage tilt, β = −beta tilt, φ the azimuth and
    /// θ = −elevation.
    package static func takeOffAngle(tiltStage: Double, azimuth: Double, elevation: Double, betaTilt: Double = 0) -> Double {
        let radians = Double.pi / 180, degrees = 180 / Double.pi
        let alpha = tiltStage * radians, beta = -(betaTilt * radians), phi = azimuth * radians, theta = -(elevation * radians)
        let c = sin(alpha) * cos(beta) * cos(phi) * cos(theta) - sin(beta) * sin(phi) * cos(theta) - cos(alpha) * cos(beta) * sin(theta)
        return 90 - acos(c) * degrees
    }
}
