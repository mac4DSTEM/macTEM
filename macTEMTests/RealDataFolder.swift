//
//  RealDataFolder.swift
//  The owner's data folder for the opt-in real-data tests: $MACEM_DATA (TEST_RUNNER_MACEM_DATA from the shell), else
//  `data/` beside the repo. A test whose file is not there skips.
//

import Foundation

nonisolated enum RealDataFolder {
    static let path: String = {
        if let folder = ProcessInfo.processInfo.environment["MACEM_DATA"], !folder.isEmpty { return folder }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data").path
    }()
}
