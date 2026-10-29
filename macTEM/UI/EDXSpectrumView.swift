//
//  EDXSpectrumView.swift
//  Role: the EDX room's spectrum: the region's counts against energy, the picked elements' alpha lines marked, and, once
//        the fit has run, the fitted continuum and the model on the fit's own energy axis. One `Canvas`. Zoom is a pinch
//        about the pointer or the scroll wheel, pan is a drag in the plot, a drag along an axis zooms that axis, a double click returns to the automatic window (`EDXRoomState.window`, `yZoom`).
//        Presentation only: the numbers are `EDXSession.plot`'s; the window rules are `EDXSpectrumWindow` (pure).
//

import ShellControls
import ShellSpectroscopy
import SwiftUI
import TEMCore
import TEMSession

/// The energy window's arithmetic, pure: it always stays inside the spectrum's range and never gets narrower than two channels.
nonisolated enum EDXSpectrumWindow {
    static func clamp(_ w: ClosedRange<Double>, domain: ClosedRange<Double>, minimumSpan: Double) -> ClosedRange<Double> {
        let full = domain.upperBound - domain.lowerBound
        let span = min(max(w.upperBound - w.lowerBound, minimumSpan), full)
        let lo = min(max(w.lowerBound, domain.lowerBound), domain.upperBound - span)
        return lo...(lo + span)
    }

    /// Zoom by `factor` (> 1 shows less) about the fraction `anchor` (0...1) of the window.
    static func zoomed(_ w: ClosedRange<Double>, factor: Double, anchor: Double, domain: ClosedRange<Double>, minimumSpan: Double) -> ClosedRange<Double> {
        guard factor.isFinite, factor > 0 else { return w }
        let span = (w.upperBound - w.lowerBound) / factor
        let pivot = w.lowerBound + anchor * (w.upperBound - w.lowerBound)
        let lo = pivot - anchor * span
        return clamp(lo...(lo + span), domain: domain, minimumSpan: minimumSpan)
    }

    /// Pan by a fraction of the window (positive moves the window to higher energy).
    static func panned(_ w: ClosedRange<Double>, byFraction f: Double, domain: ClosedRange<Double>, minimumSpan: Double) -> ClosedRange<Double> {
        let d = f * (w.upperBound - w.lowerBound)
        return clamp((w.lowerBound + d)...(w.upperBound + d), domain: domain, minimumSpan: minimumSpan)
    }

    /// Tick positions inside `w`: a step of 1, 2 or 5 times a power of ten giving about six ticks.
    static func ticks(in w: ClosedRange<Double>) -> [Double] {
        let span = w.upperBound - w.lowerBound
        guard span > 0 else { return [] }
        let raw = span / 6
        let mag = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? 10 * mag
        var out: [Double] = []
        var t = (w.lowerBound / step).rounded(.up) * step
        while t <= w.upperBound + 1e-9 { out.append(t); t += step }
        return out
    }
}

/// What a drag on the spectrum does, decided by where it starts (pure): under the plot the energy axis, left of it the counts axis, inside it a pan.
nonisolated enum EDXSpectrumDrag {
    enum Zone: Equatable { case energyAxis, countsAxis, plot }

    static func zone(start: CGPoint, size: CGSize) -> Zone {
        if start.y > size.height - EDXSpectrumView.bottom { return .energyAxis }
        if start.x < EDXSpectrumView.left { return .countsAxis }
        return .plot
    }

    /// The counts axis' zoom after a vertical drag of `dy` points from `start` (up, negative dy, zooms in), within 1...1000.
    static func yZoom(start: Double, dy: Double) -> Double { min(max(start * exp(-dy / 150), 1), 1000) }
}

struct EDXSpectrumView: View {
    let plot: EDXPlot
    let markers: [EDXMarker]
    let hasFit: Bool
    /// The regions' spectra drawn over the selected one (and the pointer's pixel).
    var layers: [SpectrumLayer] = []
    @Bindable var state: EDXRoomState

    @State private var pinchStart: ClosedRange<Double>?
    @State private var panStart: ClosedRange<Double>?
    @State private var yStart: Double?

    private var domain: ClosedRange<Double> {
        let end = plot.energyStart + plot.energyStep * Double(plot.data.count)
        return plot.energyStart...max(end, plot.energyStart + plot.energyStep)
    }
    private var minimumSpan: Double { 2 * plot.energyStep }
    private var window: ClosedRange<Double> {
        EDXSpectrumWindow.clamp(state.window ?? EDXRoomFormat.autoWindow(plot: plot, markers: markers), domain: domain, minimumSpan: minimumSpan)
    }

    var body: some View {
        // Both are read here, in the body, so a change redraws the canvas while the pointer moves; `draw` takes them as values.
        let w = window
        let yZoom = state.yZoom
        GeometryReader { geo in
            let plotWidth = max(geo.size.width - Self.left - Self.right, 1)
            // The canvas is a view of its own with the window and the counts zoom as stored values: a change of either is a change of the view.
            EDXSpectrumCanvas(window: w, yZoom: yZoom, spectrum: self)
                .contentShape(Rectangle())
                .gesture(MagnifyGesture()
                    .onChanged { v in
                        let start = pinchStart ?? w
                        if pinchStart == nil { pinchStart = start }
                        let anchor = min(max((v.startLocation.x - Self.left) / plotWidth, 0), 1)
                        state.window = EDXSpectrumWindow.zoomed(start, factor: v.magnification, anchor: anchor, domain: domain, minimumSpan: minimumSpan)
                    }
                    .onEnded { _ in pinchStart = nil })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        guard p.x >= Self.left, p.x <= geo.size.width - Self.right, plot.energyStep > 0 else { state.readout = nil; return }
                        let e = w.lowerBound + Double((p.x - Self.left) / plotWidth) * (w.upperBound - w.lowerBound)
                        let i = Int(((e - plot.energyStart) / plot.energyStep).rounded(.down))
                        state.readout = plot.data.indices.contains(i) ? "\(Num.sig(e, 4)) keV · \(EDXRoomFormat.counts(plot.data[i])) counts" : nil
                    case .ended: state.readout = nil
                    }
                }
                .onScrollWheel { event in
                    let anchor = min(max((event.location.x - Self.left) / plotWidth, 0), 1)
                    state.window = EDXSpectrumWindow.zoomed(w, factor: ScrollZoom.factor(delta: event.delta, isPrecise: event.isPrecise), anchor: anchor, domain: domain, minimumSpan: minimumSpan)
                }
                // High priority: as a plain `.gesture`, a vertical drag on the counts axis reached `onChanged` only on release (measured on screen,
                // drive 2026-10-23: the energy axis was live, the counts axis jumped at the end).
                .highPriorityGesture(DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        switch EDXSpectrumDrag.zone(start: v.startLocation, size: geo.size) {
                        case .energyAxis:
                            // Along the energy axis: right zooms in about where the drag began.
                            let start = panStart ?? w
                            if panStart == nil { panStart = start }
                            let anchor = min(max((v.startLocation.x - Self.left) / plotWidth, 0), 1)
                            state.window = EDXSpectrumWindow.zoomed(start, factor: exp(Double(v.translation.width) / 150), anchor: anchor, domain: domain, minimumSpan: minimumSpan)
                        case .countsAxis:
                            // Along the counts axis: up zooms in.
                            let start = yStart ?? state.yZoom
                            if yStart == nil { yStart = start }
                            state.yZoom = EDXSpectrumDrag.yZoom(start: start, dy: Double(v.translation.height))
                        case .plot:
                            let start = panStart ?? w
                            if panStart == nil { panStart = start }
                            state.window = EDXSpectrumWindow.panned(start, byFraction: -v.translation.width / plotWidth, domain: domain, minimumSpan: minimumSpan)
                        }
                    }
                    .onEnded { _ in panStart = nil; yStart = nil })
                .onTapGesture(count: 2) { state.window = nil; state.yZoom = 1 }
                .accessibilityElement()
                .accessibilityLabel("Spectrum, \(String(format: "%.2f", w.lowerBound)) to \(String(format: "%.2f", w.upperBound)) keV"
                    + (markers.isEmpty ? "" : ", lines: " + EDXRoomFormat.lines(markers)))
                .accessibilityIdentifier("edx.spectrum")
        }
    }

    static let left: CGFloat = 52, bottom: CGFloat = 36, top: CGFloat = 16, right: CGFloat = 8

    fileprivate func draw(_ context: inout GraphicsContext, size: CGSize, window w: ClosedRange<Double>, yZoom: Double) {
        let area = CGRect(x: Self.left, y: Self.top, width: max(size.width - Self.left - Self.right, 1),
                          height: max(size.height - Self.top - Self.bottom, 1))
        let span = w.upperBound - w.lowerBound
        func x(_ e: Double) -> CGFloat { area.minX + CGFloat((e - w.lowerBound) / span) * area.width }

        // The channels inside the window; one point per pixel column (the column's maximum), so a 4096-channel
        // spectrum draws the same lines at any width.
        func channels(of start: Double, step: Double, count: Int) -> Range<Int> {
            guard step > 0, count > 0 else { return 0..<0 }
            let lo = max(Int(((w.lowerBound - start) / step).rounded(.down)), 0)
            let hi = min(Int(((w.upperBound - start) / step).rounded(.up)) + 1, count)
            return lo < hi ? lo..<hi : 0..<0
        }
        let dataRange = channels(of: plot.energyStart, step: plot.energyStep, count: plot.data.count)
        var top = 1.0
        for i in dataRange { top = max(top, plot.data[i]) }
        if let peak = SpectrumLayerPlot.peak(of: layers, in: w, scale: .linear) { top = max(top, peak) }
        top = top * 1.08 / yZoom
        func y(_ v: Double) -> CGFloat { area.maxY - CGFloat(min(max(v / top, 0), 1)) * area.height }

        // Axes: horizontal grid at the ticks, x labels in keV, y labels in counts.
        for t in EDXSpectrumWindow.ticks(in: w) {
            var p = Path(); p.move(to: CGPoint(x: x(t), y: area.minY)); p.addLine(to: CGPoint(x: x(t), y: area.maxY))
            context.stroke(p, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            context.draw(Text(Num.sig((t * 1000).rounded() / 1000, 6)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x(t), y: area.maxY + 10))
        }
        for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let v = top / 1.08 * f
            var p = Path(); p.move(to: CGPoint(x: area.minX, y: y(v))); p.addLine(to: CGPoint(x: area.maxX, y: y(v)))
            context.stroke(p, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            context.draw(Text(EDXRoomFormat.counts(v)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: area.minX - 4, y: y(v)), anchor: .trailing)
        }
        // The axes are named outside the plot: the energy under the ticks, the unit of the counts over their labels.
        context.draw(Text("energy (keV)").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: area.midX, y: area.maxY + 25))
        context.draw(Text("counts").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: area.minX - 4, y: area.minY - 8), anchor: .trailing)

        // The line of one series, one point per pixel column.
        func path(_ values: [Double], start: Double, step: Double, offset: Int = 0) -> Path {
            var p = Path()
            let range = channels(of: start, step: step, count: values.count)
            guard !range.isEmpty else { return p }
            var column = Int.min
            var colMax = 0.0
            var first = true
            func flush(_ c: Int, _ v: Double) {
                let pt = CGPoint(x: area.minX + CGFloat(c) + 0.5, y: y(v))
                if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
            }
            for i in range {
                let c = Int(x(start + step * Double(i)) - area.minX)
                if c != column { if column != Int.min { flush(column, colMax) }; column = c; colMax = values[i] } else { colMax = max(colMax, values[i]) }
            }
            if column != Int.min { flush(column, colMax) }
            return p
        }
        let line = path(plot.data, start: plot.energyStart, step: plot.energyStep)
        var fill = line
        if !fill.isEmpty {
            fill.addLine(to: CGPoint(x: area.maxX, y: area.maxY)); fill.addLine(to: CGPoint(x: area.minX, y: area.maxY)); fill.closeSubpath()
            context.fill(fill, with: .color(.accentColor.opacity(0.12)))
        }
        context.stroke(line, with: .color(.accentColor), lineWidth: 1)
        if hasFit, !plot.model.isEmpty {
            // The fitted curves cover the fitted channels only.
            func clipped(_ values: [Double]) -> Path {
                let part = plot.fitted(values)
                return path(part.values, start: part.start, step: plot.energyStep)
            }
            if !plot.background.isEmpty { context.stroke(clipped(plot.background), with: .color(.orange), lineWidth: 1) }
            context.stroke(clipped(plot.model), with: .color(.red), lineWidth: 1)
        }

        SpectrumLayerPlot.draw(layers, in: &context, rect: area, xRange: w, top: top, scale: .linear)

        // The picked elements' alpha lines: a dashed rule and the name, quantified ones in the primary colour.
        // Each label goes on the first of four rows where it clears the one before (measured, not estimated), so neighbouring lines at low
        // energy (Mg, Al, Si within 0.3 keV) stack instead of printing over each other; a label that fits no row is left to its rule and
        // to the Elements list.
        var rowEnds = [CGFloat](repeating: -.infinity, count: 4)
        for m in markers.sorted(by: { $0.energy < $1.energy }) where w.contains(m.energy) {
            let text = Text(m.label).font(.caption2).foregroundStyle(m.quantified ? .primary : .secondary)
            let width = context.resolve(text).measure(in: CGSize(width: 200, height: 20)).width
            let left = min(max(x(m.energy) - width / 2, area.minX), area.maxX - width)
            guard let row = rowEnds.firstIndex(where: { left >= $0 + 4 }) else { continue }
            rowEnds[row] = left + width
            var p = Path(); p.move(to: CGPoint(x: x(m.energy), y: area.minY + 10 + CGFloat(row) * 11)); p.addLine(to: CGPoint(x: x(m.energy), y: area.maxY))
            context.stroke(p, with: .color(m.quantified ? .primary.opacity(0.5) : .secondary.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
            context.draw(text, at: CGPoint(x: left + width / 2, y: area.minY + 4 + CGFloat(row) * 11))
        }
        context.stroke(Path(area), with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
    }
}

/// The spectrum's drawing, with the window and the counts zoom as stored values (see the call site).
private struct EDXSpectrumCanvas: View {
    let window: ClosedRange<Double>
    let yZoom: Double
    let spectrum: EDXSpectrumView

    var body: some View {
        Canvas { context, size in spectrum.draw(&context, size: size, window: window, yZoom: yZoom) }
    }
}
