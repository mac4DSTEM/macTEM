// The EELS room's pipeline, as words and states (design 2026-10-22 §2.3 and §2.5): Align, Thickness, then (later) Deconvolve, Edges and Fit.
// Each stage is not run, current, or stale (its input has changed since); a stale result stays on screen, dimmed, and is never blanked.
// Pure values and strings: no kit call, no view.
import Foundation

package enum EELSStage: String, CaseIterable, Sendable {
    case align, thickness, edges, fit

    package var title: String {
        switch self {
        case .align: "Align"
        case .thickness: "Thickness"
        case .edges: "Edges"
        case .fit: "Fit"
        }
    }

    /// Whether Run does it: Edges is a choice (the picked edges), not a computation.
    package var isRun: Bool { self != .edges }
}

package enum EELSStageState: Equatable, Sendable {
    case notRun, current, stale

    /// The glyph on the section's title row and in the header readout: ✓ current, ● stale, — not run.
    package var glyph: String {
        switch self {
        case .current: "✓"
        case .stale: "●"
        case .notRun: "—"
        }
    }

    /// The SF Symbol drawn leading on the section's title row (status on symbols, never colour alone).
    package var symbolName: String {
        switch self {
        case .current: "checkmark.circle"
        case .stale: "arrow.triangle.2.circlepath.circle"
        case .notRun: "minus.circle"
        }
    }

    /// The accessibility word for the glyph.
    package var word: String {
        switch self {
        case .current: "current"
        case .stale: "needs a new run"
        case .notRun: "not run"
        }
    }
}

package nonisolated enum EELSRoomFormat {
    /// The header's status text: "Align ✓ Thickness ● " — one short word and one glyph per stage, secondary text, never a control.
    package static func pipelineText(_ stages: [(stage: EELSStage, state: EELSStageState)]) -> String {
        stages.map { "\($0.stage.title) \($0.state.glyph)" }.joined(separator: " ")
    }

    /// "offset -21.5 → 0 eV, 2041 of 2048 channels kept" (the kit's recalibrated offset, as the app writes an energy, and what the crop left).
    package static func alignmentReadout(offsetBefore: Double, offsetAfter: Double, kept: Int, of total: Int, locale: Locale = .autoupdatingCurrent) -> String {
        "offset \(eV(offsetBefore, locale: locale)) → \(eV(offsetAfter, locale: locale)) eV, \(kept) of \(total) channels kept"
    }
}
