//
//  ProfileCSV.swift
//  Role: the Image room's line-profile CSV on ImagoKit's `ProfileCSV` (ImagoCore 0.5.0: the header, the `%.17g` numbers, the
//        control-character rule and the column row are the kit's, byte for byte the writer the app had). What stays here is
//        what the kit leaves to the caller: the title, the validation sentence, and the hand-over from the app's `ImagePoint`. `export` writes through `ExportFile.write` off the main actor.
//

import Foundation
import ImagoCore

extension ProfileCSV {
    /// What a line profile is checked against (the Results room and its CSV show it verbatim); the `# validation:` line adds
    /// ", unvalidated (reader note)" when the file's notes say so.
    package nonisolated static let validation = "samples compared with scikit-image 0.26.0 profile_line(order=1, mode=\"reflect\", "
        + "reduce_func=mean), V1-5 P2 (1e-5 relative; 1e-5 of the image's largest magnitude near zero); "
        + "calibration: as the file states it"

    /// The whole file, UTF-8 (no BOM), LF line ends; nil when the profile has no samples.
    ///
    /// `shown`: the unit and factor the app shows positions in when it differs from the file's (`MarkFormat.shown`;
    /// e.g. ("nm", 1e9) for a metre axis); nil when the same, or when the image is not calibrated.
    package nonisolated static func text(_ profile: LineProfile, start: ImagePoint, end: ImagePoint, source: ExportSource,
                                         shown: (unit: String, factor: Double)? = nil) -> String? {
        text(profile, title: "macTEM line profile", appName: "macTEM", start: start.pixelPoint, end: end.pixelPoint,
                source: source, validation: validation, shown: shown)
    }

    /// Renders and writes off the main actor (`ExportFile.write`); throws `ExportFile.Failure.noSamples` for an empty
    /// profile, so a caller that checked nothing is still told.
    @concurrent package static func export(_ profile: LineProfile, start: ImagePoint, end: ImagePoint,
                                           source: ExportSource, shown: (unit: String, factor: Double)?,
                                           to url: URL) async throws {
        guard let text = text(profile, start: start, end: end, source: source, shown: shown) else {
            throw ExportFile.Failure.noSamples
        }
        try ExportFile.write(Data(text.utf8), to: url)
    }
}
