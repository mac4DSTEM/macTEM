//
//  TextLines.swift
//  Role: the lines of a person's text file as Python reads them in universal-newlines mode, where LF, CRLF and a lone CR each end a
//        line (`open()` in text mode, which the readers' references use: orix's ctf.py and ang.py, kikuchipy's NORDIF Setting.txt).
//        Swift keeps "\r\n" as one Character, so `split(separator: "\n")` finds no line end in a file saved on Windows (AZtec, OIM,
//        Esprit write CRLF) and the whole file reads as one line (#518).
//        Tests: TextLinesTests.
//

import Foundation

package nonisolated enum TextLines {
    /// The lines of `text` without their line ends. A line end at the very end gives a last empty line, as
    /// `split(omittingEmptySubsequences: false)` does; an LF-only text splits exactly as `split(separator: "\n")` splits it.
    package static func split(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: isLineEnd)
    }

    /// LF, CRLF (one Character in Swift) or a lone CR: the three line ends Python's universal newlines read as one.
    package static func isLineEnd(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }
}
