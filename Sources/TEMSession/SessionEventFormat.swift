//
//  SessionEventFormat.swift
//  Role: the numbers in the Output lines the SEM sessions write ("Indexed 1200 of 1200 patterns with Hough in 1,0 s"; the status
//        line shows the last): the reader's decimal mark, never grouped, as the app writes every other number on screen (its `Num`,
//        mac4DSTEM's `Num`) and as the Indexing Info's "Time 0,982 s" beside the line already did. The lines are words for a person;
//        the exports keep their POSIX formats. Pure.
//

import Foundation

package nonisolated enum SessionEventFormat {
    /// `v` at `places` decimals in `locale`, digits never grouped.
    package static func fixed(_ v: Double, _ places: Int, locale: Locale = .autoupdatingCurrent) -> String {
        v.formatted(.number.precision(.fractionLength(places)).grouping(.never).locale(locale))
    }
}
