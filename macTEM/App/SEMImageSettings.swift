//
//  SEMImageSettings.swift
//  Role: the one document-independent switch of the SEM image reading: whether the vendor's databar is cut off the bottom of a
//        Thermo or Tescan TIFF when it opens (on by default: the room shows the scan; off shows the whole frame, bar included).
//        Kept in UserDefaults so it holds across launches, read by the reader off the main actor (`AppState.read`), set by the
//        Calibration section's switch, which then reads the selected file again (`OpenItems.reread`).
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
