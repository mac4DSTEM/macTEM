//
//  SEMImageSettings.swift
//  Role: the one document-independent switch of the SEM image display: whether the databar the vendor drew under a Thermo or
//        Tescan scan is hidden (on by default) or shown as a strip under the picture (`ImagePane`). The picture itself is always
//        the scan alone (`AppState.read`). Kept in UserDefaults so it holds across launches; set by Display's `Databar` control.
//

import Foundation

nonisolated enum SEMImageSettings {
    static let cropDatabarKey = "sem.cropDatabar"

    /// On unless the person turned it off.
    static func cropDatabar(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: cropDatabarKey) == nil ? true : defaults.bool(forKey: cropDatabarKey)
    }

    static func setCropDatabar(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: cropDatabarKey)
    }
}
