//
//  ModifierKeys.swift
//  Role: which modifier keys are down at this moment, for a gesture whose value carries none (a SwiftUI drag). AppKit, named here
//        because SwiftUI cannot do this job: `onModifierKeysChanged` keeps a stored state that can miss a key released while another
//        app is front, which would leave a plain click on an SEM map picking nothing. The UI layer reads this, never AppKit itself.
//

import AppKit

nonisolated enum ModifierKeys {
    /// Whether ⌘ is down now (`NSEvent.modifierFlags`).
    static var commandIsDown: Bool { NSEvent.modifierFlags.contains(.command) }
}
