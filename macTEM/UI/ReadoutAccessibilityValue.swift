//
//  ReadoutAccessibilityValue.swift
//  Role: a pane's accessibility value while the pointer is over it: the room's readout (what the status line shows: the energy and the counts, the
//        pixel and its value), else the pane's own description. The readout is read in the modifier's body, not in the pane's, so a pointer move
//        re-evaluates this modifier alone and the pane that draws is left as it was (as mac4DSTEM's `CursorAccessibilityValue`). The status line is
//        unchanged: this says the same words to VoiceOver.
//

import SwiftUI

/// Which words a pane's accessibility value takes (pure, so a test reads it): the readout while there is one, else the pane's description.
nonisolated enum ReadoutSpeech {
    static func value(readout: String?, fallback: String) -> String {
        guard let readout, !readout.isEmpty else { return fallback }
        return readout
    }
}

/// The pane's accessibility value: the readout under the pointer, else `fallback`. A modifier, so the read of the room's readout happens here and not
/// in the pane's body.
struct ReadoutAccessibilityValue: ViewModifier {
    /// The room's readout now (an observed property, read when this modifier's body runs); nil when the pointer is elsewhere.
    let readout: () -> String?
    /// What the pane says of itself while no pointer is over it.
    let fallback: String

    func body(content: Content) -> some View {
        content.accessibilityValue(ReadoutSpeech.value(readout: readout(), fallback: fallback))
    }
}
