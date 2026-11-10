//
//  LazyAppState.swift
//  Role: a window's `AppState`, built the first time the window asks for it and never again (mac4DSTEM's `LazyAppState`, the same
//        box). A window scene's content `init` runs every time the scene is evaluated; `@State` keeps only its first value, so a
//        state graph built there each time would be construction for nothing. The box is cheap; the one `AppState` is made on the
//        first `state` read, in `body`.
//

import Foundation

@MainActor
final class LazyAppState {
    private let make: @MainActor () -> AppState
    private var built: AppState?

    init(make: @escaping @MainActor () -> AppState) {
        self.make = make
    }

    /// The window's state: made on first use, the same instance after.
    var state: AppState {
        if let built { return built }
        let made = make()
        built = made
        return made
    }

    /// Whether the state has been made yet (a test).
    var isBuilt: Bool { built != nil }
}
